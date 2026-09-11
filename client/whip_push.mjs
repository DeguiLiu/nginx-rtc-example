import { createRequire } from "node:module";
import { writeSync } from "node:fs";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";
import { signToken } from "./lib/token.mjs";

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

// Ingest secret for <app>/<stream>. No default, unlike lib/token.mjs DEMO_KEY:
// the publish secret is the one credential that must not travel with a client
// (see deploy/nginx/conf/stream_keys.lua), and a copy compiled in here would
// make whoever holds this file a publisher. Playback has a default precisely
// because the player pages already ship that secret.
//
// Callers used to work around the missing credential by splicing "t=..&sign=.."
// into WHIP_STREAM, which the client pasted into its URL verbatim: the stream
// name carried the query. That left `node client/whip_push.mjs` a bare 403 on
// its own, and put a second, hand-rolled HMAC next to every caller.
const KEY = process.env.WHIP_KEY || "";

// Bounded signaling: without an AbortSignal a hung /whip/endpoint request makes
// this script wait forever, which in turn hangs scripts/e2e-whip-release.sh.
// Same idiom as client/play.mjs.
const SIGNAL_TIMEOUT_MS = 5000;

const DURATION = Number.parseInt(process.env.WHIP_DURATION || "10000", 10);
if (!Number.isFinite(DURATION) || DURATION <= 0) {
  // parseInt gives NaN for a typo'd value, and setTimeout(fn, NaN) fires on the
  // next tick -- the publisher would exit immediately and the callers below
  // would read that as "the stream ended", not "the duration was invalid".
  log(`[FAIL] WHIP_DURATION must be a positive number of ms, got ${JSON.stringify(process.env.WHIP_DURATION)}`);
  process.exit(1);
}

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

/* H.264 access-unit boundary rules (ISO/IEC 14496-10 7.4.1.2.4).
 *
 * A chunk from the ffmpeg pipe is not frame-aligned: one picture can arrive in
 * two reads, and one read can carry the tail of one picture plus the head of
 * the next. Doing the RTP work per chunk therefore stamps repeated or skipped
 * timestamps, marks a picture boundary that is not there, and -- because the
 * SPS/PPS pair was only emitted when both landed in the same read -- silently
 * drops the parameter sets whenever a chunk boundary falls between them. The
 * receiver's decoder, A/V sync and jitter accounting are all built on what
 * this function emits, so the NALs have to be grouped into access units here.
 *
 * A picture starts at the first slice NAL (type 1 or 5) whose first_mb_in_slice
 * is 0 -- the rule a decoder itself uses -- or at an access unit delimiter.
 * first_mb_in_slice is the first ue(v) of the slice header, and ue(v) == 0 is
 * coded as a single "1" bit, so the test is just "is the top bit of nal[1]
 * set": no slice header parse is needed.
 */
const NAL_SLICE = 1;
const NAL_IDR = 5;
const NAL_SPS = 7;
const NAL_PPS = 8;
const NAL_AUD = 9;

const nalType = (nal) => nal[0] & 0x1f;
const isVcl = (type) => type === NAL_SLICE || type === NAL_IDR;
const startsPicture = (nal) => nal.length >= 2 && (nal[1] & 0x80) !== 0;

/*
 * Feed Annex-B bytes in, get RTP packets out: one timestamp per access unit,
 * and the marker bit on that unit's last packet. `track` is anything with
 * writeRtp(pkt) -- a werift MediaStreamTrack in the client, a recorder in
 * ausplit.mjs.
 */
export function createH264Packer(track, { payloadType = H264_PT, ssrc = 0x2a2b3c00 } = {}) {
  let sequenceNumber = 0x1000;
  let timestamp = 0;
  let annexB = Buffer.alloc(0);

  /* Access unit under assembly. `prefix` holds the parameter sets and SEIs
   * seen since the previous picture ended: they apply to the picture that
   * follows them, not to the one that just ended. */
  let auNals = [];
  let auTs = 0;
  let auHasPicture = false;
  let prefix = [];

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

  /* Split the buffered bytes into NALs. A NAL is only known to be complete
   * once the next start code shows up, so mid-stream the tail is kept for the
   * next chunk; at end of stream it is the last NAL and has to come out. */
  const scanNals = (atEof) => {
    const pending = [];
    let idx = 0;
    for (;;) {
      const start = findStartCode(annexB, idx);
      if (start < 0) break;
      if (start > idx) {
        pending.push(annexB.subarray(idx, start));
      }
      idx = start + startCodeLen(annexB, start);
    }
    if (atEof && idx < annexB.length) {
      pending.push(annexB.subarray(idx));
      idx = annexB.length;
    }
    annexB = annexB.subarray(idx);
    return pending;
  };

  const sendRtp = (nalu, ts, marker) => {
    if (nalu.length <= MAX_RTP_PAYLOAD) {
      track.writeRtp(
        new RtpPacket(
          new RtpHeader({
            version: 2,
            payloadType,
            sequenceNumber,
            timestamp: ts,
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
            payloadType,
            sequenceNumber,
            timestamp: ts,
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

  /* The marker bit never lands on a STAP-A: a picture always has at least one
   * slice NAL after its parameter sets. */
  const emitStapA = (nals, ts) => {
    const chunks = [Buffer.from([0x78])];
    for (const n of nals) {
      chunks.push(Buffer.from([(n.length >> 8) & 0xff, n.length & 0xff]));
      chunks.push(n);
    }
    sendRtp(Buffer.concat(chunks), ts, false);
  };

  /* Open an access unit, seeding it with the parameter sets held over from the
   * previous picture, and give it the next timestamp. */
  const startAu = () => {
    auNals = prefix;
    prefix = [];
    auHasPicture = false;
    auTs = timestamp;
    timestamp = (timestamp + H264_CLOCK / VIDEO_FPS) >>> 0;
  };

  const flushAu = () => {
    if (auNals.length === 0) {
      return;
    }

    let i = 0;

    /* An access unit delimiter, when the encoder emits one, is its own NAL. */
    if (nalType(auNals[0]) === NAL_AUD) {
      sendRtp(auNals[0], auTs, false);
      i = 1;
    }

    /* Leading SPS/PPS travel together as one STAP-A (RFC 6184 5.8). */
    const params = [];
    while (i < auNals.length) {
      const type = nalType(auNals[i]);
      if (type !== NAL_SPS && type !== NAL_PPS) {
        break;
      }
      params.push(auNals[i]);
      i++;
    }
    if (params.length > 0) {
      emitStapA(params, auTs);
    }

    for (; i < auNals.length; i++) {
      sendRtp(auNals[i], auTs, i === auNals.length - 1);
    }

    auNals = [];
    auHasPicture = false;
  };

  const pushNal = (nal) => {
    const type = nalType(nal);

    if (isVcl(type)) {
      if (startsPicture(nal)) {
        flushAu();
        if (!auHasPicture) {
          startAu();
        }
      }
      auNals.push(nal);
      auHasPicture = true;
      return;
    }

    /* SPS / PPS / SEI / AUD: belongs to the picture that follows it. */
    prefix.push(nal);
  };

  return {
    push(chunk) {
      annexB = Buffer.concat([annexB, chunk]);
      for (const nal of scanNals(false)) {
        pushNal(nal);
      }
    },

    /* Send the access unit still in flight. Nothing in the stream says the
     * last NAL read is the last NAL of its picture, so it is held until the
     * next picture starts -- one frame of latency, as in any RTP packetizer.
     * Call this at end of stream, or that picture is never sent. */
    flush() {
      for (const nal of scanNals(true)) {
        pushNal(nal);
      }
      flushAu();
    },
  };
}

/* H264 Annex-B parser + RFC 6184 packer, fed from a live ffmpeg pipe. */
function createH264Track() {
  const track = new MediaStreamTrack({ kind: "video" });
  const packer = createH264Packer(track);

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

  ffmpeg.stdout.on("data", (chunk) => packer.push(chunk));
  ffmpeg.stdout.on("end", () => packer.flush());
  ffmpeg.stderr.on("data", () => {});
  ffmpeg.on("error", (err) => log(`[ffmpeg] ${err.message}`));
  ffmpeg.on("exit", () => log("[ffmpeg] exited"));

  return { track, stop: () => ffmpeg.kill("SIGTERM") };
}

async function main() {
  if (!KEY) {
    log("[FAIL] WHIP_KEY is required: the publish secret for " + APP + "/" + STREAM);
    log("       take it from deploy/nginx/conf/stream_keys.lua (the |publish entry), e.g.");
    log("       WHIP_KEY=<secret> node client/whip_push.mjs");
    process.exit(1);
  }

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

  const { t, sign } = signToken(KEY, `${APP}/${STREAM}`);
  const res = await fetch(
    `${API}/whip/endpoint?app=${APP}&stream=${STREAM}&t=${t}&sign=${sign}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/sdp" },
      body: offer.sdp,
      signal: AbortSignal.timeout(SIGNAL_TIMEOUT_MS),
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

/* Importing this module -- ausplit.mjs, or any future unit test -- must not
 * start a push. */
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    log(`[FAIL] ${err.message}`);
    process.exit(1);
  });
}
