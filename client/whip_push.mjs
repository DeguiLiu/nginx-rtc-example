import { createRequire } from "node:module";
import { writeSync } from "node:fs";
import { spawn } from "node:child_process";

const require = createRequire(import.meta.url);

const {
  RTCPeerConnection,
  useH264,
  useOPUS,
  MediaStreamTrack,
  RtpPacket,
  RtpHeader,
} = require("werift");

const H264_PT = 102;
const OPUS_PT = 111;
const H264_CLOCK = 90000;
const OPUS_CLOCK = 48000;
const VIDEO_FPS = 30;
const MAX_RTP_PAYLOAD = 1200;

const API = process.env.WHIP_API || "http://127.0.0.1:18082";
const APP = process.env.WHIP_APP || "live";
const STREAM = process.env.WHIP_STREAM || "whiptest";
const DURATION = Number.parseInt(process.env.WHIP_DURATION || "10000", 10);

function log(msg) {
  writeSync(1, msg + "\n");
}

/* Minimal Opus RTP source: one 20ms packet every interval, payload type 111. */
function createOpusTrack() {
  const track = new MediaStreamTrack({ kind: "audio" });
  let sequenceNumber = 0x4000;
  let timestamp = 0;
  const ssrc = 0x1a2b3c00;
  const payload = Buffer.from([0xf8, 0xff, 0xfe]);

  const timer = setInterval(() => {
    if (track.stopped) {
      clearInterval(timer);
      return;
    }
    const pkt = new RtpPacket(
      new RtpHeader({
        version: 2,
        payloadType: OPUS_PT,
        sequenceNumber,
        timestamp,
        ssrc,
        marker: true,
      }),
      payload
    );
    track.writeRtp(pkt);
    sequenceNumber = (sequenceNumber + 1) & 0xffff;
    timestamp = (timestamp + 960) >>> 0;
  }, 20);

  return { track, timer };
}

/* H264 Annex-B parser + RFC 6184 packer, fed from a live ffmpeg pipe. */
function createH264Track() {
  const track = new MediaStreamTrack({ kind: "video" });
  let sequenceNumber = 0x1000;
  let timestamp = 0;
  const ssrc = 0x2a2b3c00;
  let annexB = Buffer.alloc(0);
  let frameSeq = 0;

  const findStartCode = (buf, from) => {
    for (let i = from; i < buf.length - 3; i++) {
      if (buf[i] === 0 && buf[i + 1] === 0) {
        if (buf[i + 2] === 1) return i;
        if (buf[i + 2] === 0 && buf[i + 3] === 1) return i;
      }
    }
    return -1;
  };

  const startCodeLen = (buf, idx) =>
    buf[idx + 2] === 1 ? 3 : 4;

  const sendRtp = (nalu, marker) => {
    if (nalu.length <= MAX_RTP_PAYLOAD) {
      track.writeRtp(
        new RtpPacket(
          new RtpHeader({
            version: 2,
            payloadType: H264_PT,
            sequenceNumber,
            timestamp,
            ssrc,
            marker,
          }),
          nalu
        )
      );
      sequenceNumber = (sequenceNumber + 1) & 0xffff;
      return;
    }

    /* FU-A fragmentation (RFC 6184). */
    const fuIndicator = (nalu[0] & 0xe0) | 28;
    const fuHeaderBase = nalu[0] & 0x1f;
    const payload = nalu.subarray(1);
    let offset = 0;
    while (offset < payload.length) {
      const chunk = payload.subarray(
        offset,
        Math.min(offset + MAX_RTP_PAYLOAD - 2, payload.length)
      );
      const end = offset + chunk.length >= payload.length;
      const fuHeader = (end ? 0x40 : 0) | fuHeaderBase;
      track.writeRtp(
        new RtpPacket(
          new RtpHeader({
            version: 2,
            payloadType: H264_PT,
            sequenceNumber,
            timestamp,
            ssrc,
            marker: end && marker,
          }),
          Buffer.concat([Buffer.from([fuIndicator, fuHeader]), chunk])
        )
      );
      sequenceNumber = (sequenceNumber + 1) & 0xffff;
      offset += chunk.length;
    }
  };

  const emitStapA = (nals) => {
    const chunks = [Buffer.from([0x78])];
    for (const n of nals) {
      chunks.push(Buffer.from([(n.length >> 8) & 0xff, n.length & 0xff]));
      chunks.push(n);
    }
    sendRtp(Buffer.concat(chunks), false);
  };

  const onData = (chunk) => {
    annexB = Buffer.concat([annexB, chunk]);

    let idx = 0;
    const pending = [];
    for (;;) {
      const start = findStartCode(annexB, idx);
      if (start < 0) break;
      if (start > idx) {
        pending.push(annexB.subarray(idx, start));
      }
      idx = start + startCodeLen(annexB, start);
    }
    annexB = annexB.subarray(idx);

    const sps = [];
    const pps = [];
    const frames = [];
    for (const nal of pending) {
      const type = nal[0] & 0x1f;
      if (type === 7) sps.push(nal);
      else if (type === 8) pps.push(nal);
      else frames.push(nal);
    }

    if (sps.length > 0 && pps.length > 0) {
      emitStapA([...sps, ...pps]);
    }
    for (let i = 0; i < frames.length; i++) {
      sendRtp(frames[i], i === frames.length - 1);
    }

    frameSeq++;
    timestamp = (timestamp + (H264_CLOCK / VIDEO_FPS)) >>> 0;
  };

  const ffmpeg = spawn("ffmpeg", [
    "-re",
    "-f", "lavfi",
    "-i", "testsrc2=size=640x360:rate=30",
    "-c:v", "libx264",
    "-preset", "ultrafast",
    "-tune", "zerolatency",
    "-g", "60",
    "-bf", "0",
    "-pix_fmt", "yuv420p",
    "-f", "h264",
    "-",
  ]);

  ffmpeg.stdout.on("data", onData);
  ffmpeg.stderr.on("data", () => {});
  ffmpeg.on("error", (err) => log(`[ffmpeg] ${err.message}`));
  ffmpeg.on("exit", () => log("[ffmpeg] exited"));

  return { track, stop: () => ffmpeg.kill("SIGTERM") };
}

async function main() {
  const pc = new RTCPeerConnection({
    codecs: {
      audio: [useOPUS({ payloadType: OPUS_PT })],
      video: [useH264({ payloadType: H264_PT })],
    },
  });

  let dtlsConnected = false;
  pc.connectionStateChange.subscribe((state) => {
    log(`[dtls] connectionState=${state}`);
    if (state === "connected") {
      dtlsConnected = true;
    }
  });

  const audio = createOpusTrack();
  const video = createH264Track();
  pc.addTrack(video.track);
  pc.addTrack(audio.track);

  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  log("[whip] offer created");

  const res = await fetch(
    `${API}/whip/endpoint?app=${APP}&stream=${STREAM}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/sdp" },
      body: offer.sdp,
    }
  );

  const answerSdp = await res.text();
  if (res.status !== 201) {
    log(`[FAIL] whip http=${res.status} body=${answerSdp.slice(0, 160)}`);
    process.exit(1);
  }

  await pc.setRemoteDescription({ type: "answer", sdp: answerSdp });
  log("[whip] answer set, waiting for DTLS/SRTP");

  await new Promise((r) => setTimeout(r, 3000));
  if (!dtlsConnected) {
    log(`[FAIL] DTLS not connected, state=${pc.connectionState}`);
    process.exit(1);
  }

  log(`[whip] DTLS connected, pushing Opus audio for ${DURATION}ms`);
  await new Promise((r) => setTimeout(r, DURATION));

  log("[whip] done");
  clearInterval(audio.timer);
  video.stop();
  pc.close();
  process.exit(0);
}

main().catch((err) => {
  log(`[FAIL] ${err.message}`);
  process.exit(1);
});
