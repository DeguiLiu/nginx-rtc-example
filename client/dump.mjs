// dump.mjs - connect with werift, reassemble the H264 RTP payload into an
// Annex-B .h264 file so ffprobe/ffplay can verify the bitstream is intact.
import { RTCPeerConnection, useH264, useOPUS } from "werift";
import { openSync, writeSync, closeSync } from "node:fs";

import { DEMO_KEY, signToken, streamPathOf } from "./lib/token.mjs";

const API = "http://127.0.0.1:18082/rtc/v1/play/";
const STREAM = process.argv[2] || "webrtc://127.0.0.1:18082/live/livestream";
const OUT = process.argv[3] || "/tmp/dump.h264";

// stdout via writeSync: console.log is asynchronous when stdout is a pipe, so
// a following process.exit() would truncate the summary. play.mjs does the same.
function out(s) {
  writeSync(1, s);
}

async function main() {
  // Everything lives inside main() so one .catch() below converts every failure
  // (offer creation, signaling, SDP apply) into a readable line instead of an
  // UnhandledPromiseRejection stack.
  const fd = openSync(OUT, "w");

  let fragBuf = null; // pending FU-A fragments
  let started = false; // skip until the first STAP-A (SPS/PPS) so the dump is decodable

  function emitNal(buf) {
    const sc = Buffer.from([0, 0, 0, 1]);
    writeSync(fd, sc);
    writeSync(fd, buf);
  }

  function handlePayload(p) {
    const type = p[0] & 0x1f;
    if (!started) {
      if (type !== 24) return; // wait for STAP-A (SPS+PPS) before the IDR
      started = true;
    }
    if (type === 24) {
      // STAP-A
      let i = 1;
      while (i + 2 <= p.length) {
        const sz = (p[i] << 8) | p[i + 1];
        i += 2;
        if (i + sz > p.length) break;
        emitNal(p.subarray(i, i + sz));
        i += sz;
      }
    } else if (type === 28) {
      // FU-A
      const start = (p[1] & 0x80) !== 0;
      const end = (p[1] & 0x40) !== 0;
      if (start) {
        // Reconstruct the NALU header once (NRI from FU indicator, type from FU header).
        fragBuf = Buffer.from([(p[0] & 0xe0) | (p[1] & 0x1f)]);
      } else if (fragBuf === null) {
        // Continuation with no start fragment: the first fragment was lost, or
        // we attached mid-NALU. Drop the fragment -- Buffer.concat([null, ...])
        // would throw out of the RTP callback, and packet loss is precisely the
        // condition this tool exists to observe.
        return;
      }
      fragBuf = Buffer.concat([fragBuf, p.subarray(2)]);
      if (end) {
        emitNal(fragBuf);
        fragBuf = null;
      }
    } else {
      // single NAL unit
      emitNal(p);
    }
  }

  const pc = new RTCPeerConnection({
    codecs: { audio: [useOPUS()], video: [useH264()] },
  });

  let videoPkts = 0;
  let lastSeq = null;
  let seqGaps = 0;
  let seqDups = 0;
  let gapPkts = 0;
  pc.onTrack.subscribe((track) => {
    if (track.kind !== "video") return;
    track.onReceiveRtp.subscribe((rtp) => {
      videoPkts++;
      if (lastSeq !== null) {
        const d = (rtp.header.sequenceNumber - lastSeq + 0x10000) & 0xffff;
        if (d === 0) seqDups++;
        else if (d > 1 && d < 0x8000) { seqGaps++; gapPkts += d - 1; }
      }
      lastSeq = rtp.header.sequenceNumber;
      if (rtp.payload && rtp.payload.length) handlePayload(rtp.payload);
    });
  });

  try {
    pc.addTransceiver("audio", { direction: "recvonly" });
    pc.addTransceiver("video", { direction: "recvonly" });
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    // HMAC token over the stream path; see client/lib/token.mjs.
    const { t, sign } = signToken(DEMO_KEY, streamPathOf(STREAM));

    const res = await fetch(API, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        sdp: offer.sdp, streamurl: STREAM, api: "http://127.0.0.1:18082",
        clientip: "127.0.0.1", t: String(t), sign,
      }),
    });
    if (!res.ok) {
      throw new Error(`play API failed: ${res.status} ${(await res.text()).slice(0, 200)}`);
    }

    // Check code/sdp before use: a signaling error body has no .sdp, and feeding
    // undefined to setRemoteDescription fails with a werift-internal message
    // that says nothing about the actual cause.
    const data = await res.json();
    if (data.code !== 0 || typeof data.sdp !== "string") {
      throw new Error(`play API returned code=${data.code}: ${JSON.stringify(data).slice(0, 200)}`);
    }
    await pc.setRemoteDescription({ type: "answer", sdp: data.sdp });

    await new Promise((r) => setTimeout(r, 6000));
  } finally {
    // Runs on the error path too, so a failed run still leaves a readable dump
    // and does not leak the descriptor.
    closeSync(fd);
  }

  out(`video packets: ${videoPkts} seqGaps: ${seqGaps} missing: ${gapPkts} dups: ${seqDups} -> ${OUT}\n`);
}

main().catch((e) => {
  out(`dump: ${e && e.stack ? e.stack : e}\n`);
  process.exitCode = 1;
});
