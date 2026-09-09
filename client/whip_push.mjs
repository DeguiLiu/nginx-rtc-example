import { createRequire } from "node:module";
import { writeSync } from "node:fs";

const require = createRequire(import.meta.url);

const {
  RTCPeerConnection,
  useH264,
  useOPUS,
  MediaStreamTrack,
  RtpPacket,
  RtpHeader,
} = require("werift");

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
        payloadType: 111,
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

async function main() {
  const pc = new RTCPeerConnection({
    codecs: { audio: [useOPUS()], video: [useH264()] },
  });

  let dtlsConnected = false;
  pc.connectionStateChange.subscribe((state) => {
    log(`[dtls] connectionState=${state}`);
    if (state === "connected") {
      dtlsConnected = true;
    }
  });

  const { track, timer } = createOpusTrack();
  pc.addTrack(track);

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
  clearInterval(timer);
  pc.close();
  process.exit(0);
}

main().catch((err) => {
  log(`[FAIL] ${err.message}`);
  process.exit(1);
});
