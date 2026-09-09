// dump.mjs - connect with werift, reassemble the H264 RTP payload into an
// Annex-B .h264 file so ffprobe/ffplay can verify the bitstream is intact.
import { RTCPeerConnection, useH264, useOPUS } from "werift";
import { writeFileSync, openSync, writeSync, closeSync } from "node:fs";

const API = "http://127.0.0.1:18082/rtc/v1/play/";
const STREAM = "webrtc://127.0.0.1:18082/live/livestream";

const fd = openSync("/tmp/dump.h264", "w");
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
pc.onTrack.subscribe((track) => {
  if (track.kind !== "video") return;
  track.onReceiveRtp.subscribe((rtp) => {
    videoPkts++;
    if (rtp.payload && rtp.payload.length) handlePayload(rtp.payload);
  });
});

pc.addTransceiver("audio", { direction: "recvonly" });
pc.addTransceiver("video", { direction: "recvonly" });
const offer = await pc.createOffer();
await pc.setLocalDescription(offer);
const res = await fetch(API, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    sdp: offer.sdp, streamurl: STREAM, api: "http://127.0.0.1:18082",
    clientip: "127.0.0.1", key: "demo-key-123",
  }),
});
const data = await res.json();
await pc.setRemoteDescription({ type: "answer", sdp: data.sdp });

await new Promise((r) => setTimeout(r, 6000));
closeSync(fd);
console.log("video packets:", videoPkts, "-> /tmp/dump.h264");
process.exit(0);
