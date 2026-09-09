import { RTCPeerConnection, useH264, useOPUS } from "werift";
import { createHmac } from "node:crypto";
import { writeSync } from "node:fs";

const DEFAULT_STREAM = "webrtc://127.0.0.1:18082/live/livestream";
const DEFAULT_KEY = "demo-secret-0123456789abcdef0123456789abcdef";
const DEFAULT_API = "http://127.0.0.1:18082";
const DEFAULT_DURATION = 8000;

const DTLS_TIMEOUT_MS = 5000;
const MEDIA_TIMEOUT_MS = 3000;
const SIGNAL_TIMEOUT_MS = 5000;

function printHelp() {
  const lines = [
    "usage: node play.mjs [options]",
    "  --stream <url>    stream URL (default webrtc://127.0.0.1:18082/live/livestream)",
    "  --key <key>       stream key (default demo-key-123)",
    "  --api <url>       signaling API base URL (default http://127.0.0.1:18082)",
    "  --duration <ms>   receive duration in milliseconds (default 8000)",
    "  --json            print the result as a single JSON object to stdout",
    "  --dump            enable per-packet debug dump (written to stderr)",
  ];
  writeSync(1, lines.join("\n") + "\n");
  process.exit(0);
}

function parseArgs(argv) {
  const opts = {
    stream: DEFAULT_STREAM,
    key: DEFAULT_KEY,
    api: DEFAULT_API,
    duration: DEFAULT_DURATION,
    json: false,
    dump: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    let name = arg;
    let inlineValue = null;
    const eq = arg.indexOf("=");
    if (arg.startsWith("--") && eq > 0) {
      name = arg.slice(0, eq);
      inlineValue = arg.slice(eq + 1);
    }
    const take = () => {
      if (inlineValue !== null) {
        return inlineValue;
      }
      if (i + 1 >= argv.length) {
        throw new Error(`missing value for ${name}`);
      }
      return argv[++i];
    };
    switch (name) {
      case "--stream":
        opts.stream = take();
        break;
      case "--key":
        opts.key = take();
        break;
      case "--api":
        opts.api = take();
        break;
      case "--duration":
        opts.duration = Number.parseInt(take(), 10);
        break;
      case "--json":
        opts.json = true;
        break;
      case "--dump":
        opts.dump = true;
        break;
      case "-h":
      case "--help":
        printHelp();
        break;
      default:
        throw new Error(`unknown option: ${arg}`);
    }
  }
  if (!Number.isFinite(opts.duration) || opts.duration <= 0) {
    throw new Error("invalid --duration (must be a positive integer in ms)");
  }
  return opts;
}

let opts;
try {
  opts = parseArgs(process.argv.slice(2));
} catch (err) {
  writeSync(2, `[FAIL] ${err.message}\n`);
  process.exit(1);
}

const json = opts.json;
const dumpEnabled = opts.dump;
const apiBase = opts.api.replace(/\/+$/, "");
const playUrl = `${apiBase}/rtc/v1/play/`;
const startMs = Date.now();

let finished = false;

function log(msg) {
  // In --json mode keep stdout clean: human logs go to stderr.
  writeSync(json ? 2 : 1, msg + "\n");
}

function fail(reason, phase) {
  if (finished) {
    return;
  }
  finished = true;
  if (json) {
    writeSync(1, JSON.stringify({ ok: false, error: reason, phase }) + "\n");
  } else {
    writeSync(1, `[FAIL] ${reason}\n`);
  }
  process.exit(1);
}

function round2(n) {
  return Math.round(n * 100) / 100;
}

function makeTrackStats(kind, isVideo) {
  return {
    kind,
    isVideo,
    codec: "",
    clockRate: isVideo ? 90000 : 48000,
    pkts: 0,
    bytes: 0,
    first: 0,
    keyframe: 0,
    keyframes: 0,
    frames: 0,
    lost: 0,
    lastSeq: -1,
    jitter: 0,
    jitterInit: false,
    lastTransit: 0,
    lastSec: -1,
    curBucketBytes: 0,
    lastBucketBytes: 0,
  };
}

const stats = {
  audio: makeTrackStats("audio", false),
  video: makeTrackStats("video", true),
};

// Hot path: no object allocation, no string building, no optional chaining.
function handleRtp(s, rtp) {
  const now = Date.now();
  const payload = rtp.payload;
  const hdr = rtp.header;

  if (s.first === 0) {
    s.first = now - startMs;
  }
  s.pkts++;
  const size = (payload ? payload.length : 0) + 12;
  s.bytes += size;

  const seq = hdr.sequenceNumber;
  if (s.lastSeq >= 0) {
    const delta = (seq - s.lastSeq) & 0xffff;
    if (delta > 1 && delta < 0x8000) {
      s.lost += delta - 1;
    }
  }
  s.lastSeq = seq;

  // RFC 3550 interarrival jitter, in milliseconds.
  const tsMs = (hdr.timestamp / s.clockRate) * 1000;
  if (s.jitterInit) {
    const transit = now - tsMs;
    let d = transit - s.lastTransit;
    if (d < 0) {
      d = -d;
    }
    s.jitter += (d - s.jitter) / 16;
    s.lastTransit = transit;
  } else {
    s.jitterInit = true;
    s.lastTransit = now - tsMs;
  }

  // Real-time bitrate: track bytes per whole second.
  const sec = Math.floor((now - startMs) / 1000);
  if (sec !== s.lastSec) {
    if (s.lastSec >= 0) {
      s.lastBucketBytes = s.curBucketBytes;
    }
    s.curBucketBytes = 0;
    s.lastSec = sec;
  }
  s.curBucketBytes += size;

  if (s.isVideo) {
    if (hdr.marker) {
      s.frames++;
    }
    if (payload && payload.length >= 1) {
      const b0 = payload[0] & 0x1f;
      const nal = b0 === 28 && payload.length >= 2 ? payload[1] & 0x1f : b0;
      if (nal === 5) {
        if (s.keyframe === 0) {
          s.keyframe = now - startMs;
          log(`[keyframe] first H264 IDR at ${s.keyframe} ms`);
        }
        s.keyframes++;
      }
    }
  }

  if (dumpEnabled && payload && payload.length >= 1) {
    const b0 = payload[0] & 0x1f;
    const nalName =
      b0 === 28 ? "FU-A" : b0 === 24 ? "STAP-A" : b0 === 5 ? "IDR" : `NAL${b0}`;
    writeSync(
      2,
      `[dump] ${s.kind} seq=${hdr.sequenceNumber} ts=${hdr.timestamp} len=${payload.length} nal=${nalName}\n`
    );
  }
}

function finalizeResult() {
  const elapsedMs = Date.now() - startMs;
  const ok = stats.audio.pkts > 0 && stats.video.pkts > 0;
  const result = {
    ok,
    duration_ms: elapsedMs,
    audio: buildTrackResult(stats.audio, elapsedMs),
    video: buildTrackResult(stats.video, elapsedMs),
  };
  return result;
}

function buildTrackResult(s, elapsedMs) {
  const received = s.pkts;
  const lossRate = received > 0 ? (s.lost / (received + s.lost)) * 100 : 0;
  const avgBitrateKbps = elapsedMs > 0 ? (s.bytes * 8) / elapsedMs : 0;
  const lastBitrateKbps =
    s.lastBucketBytes > 0 ? (s.lastBucketBytes * 8) / 1000 : avgBitrateKbps;
  const r = {
    packets: s.pkts,
    bytes: s.bytes,
    codec: s.codec,
    first_packet_ms: s.first,
    loss_rate_percent: round2(lossRate),
    jitter_ms: round2(s.jitter),
    avg_bitrate_kbps: round2(avgBitrateKbps),
    bitrate_kbps: round2(lastBitrateKbps),
  };
  if (s.isVideo) {
    r.first_keyframe_ms = s.keyframe;
    r.fps = round2(elapsedMs > 0 ? (s.frames * 1000) / elapsedMs : 0);
    r.keyframes = s.keyframes;
  }
  return r;
}

function printHuman(result) {
  log("\n=== RTMP -> WebRTC media receive result ===");
  for (const kind of ["audio", "video"]) {
    const s = stats[kind];
    const r = result[kind];
    let line =
      `${kind}: packets=${s.pkts} bytes=${s.bytes} codec=${s.codec}` +
      ` first_packet_ms=${s.first} loss_rate=${r.loss_rate_percent}%` +
      ` jitter_ms=${r.jitter_ms} bitrate_kbps=${r.bitrate_kbps}`;
    if (s.isVideo) {
      line += ` fps=${r.fps} keyframes=${s.keyframes}`;
    }
    log(line);
  }
  log(
    `video: first_keyframe_ms=${stats.video.keyframe} (首个 H264 IDR 到达, 真正出图延迟口径)`
  );
  log(result.ok ? "\n[PASS] 音视频均经 WebRTC 收到 RTP 包" : "\n[FAIL] 未收到媒体包");
}

async function main() {
  const pc = new RTCPeerConnection({
    codecs: {
      audio: [useOPUS()],
      video: [useH264()],
    },
  });

  let dtlsConnected = false;
  let answerSet = false;
  let dtlsTimer = null;
  let mediaTimer = null;

  const armMediaTimeout = () => {
    if (mediaTimer) {
      return;
    }
    mediaTimer = setTimeout(() => {
      if (finished) {
        return;
      }
      if (stats.audio.pkts === 0 && stats.video.pkts === 0) {
        fail("media timeout: no RTP packets received", "media");
      }
    }, MEDIA_TIMEOUT_MS);
  };

  pc.connectionStateChange.subscribe((state) => {
    if (dumpEnabled) {
      log(`[dtls] connectionState=${state}`);
    }
    if (state === "connected") {
      dtlsConnected = true;
      if (answerSet) {
        armMediaTimeout();
      }
    } else if (state === "failed" || state === "closed") {
      if (stats.audio.pkts === 0 && stats.video.pkts === 0) {
        fail(`DTLS failed (state=${state})`, "dtls");
      }
    }
  });

  pc.onTrack.subscribe((track) => {
    const isVideo = track.kind === "video";
    const s = (stats[track.kind] = stats[track.kind] || makeTrackStats(track.kind, isVideo));
    s.codec = track.codec?.mimeType || "";
    if (track.codec?.clockRate) {
      s.clockRate = track.codec.clockRate;
    }
    log(`[track] ${track.kind} ${s.codec}`);
    track.onReceiveRtp.subscribe((rtp) => handleRtp(s, rtp));
  });

  pc.addTransceiver("audio", { direction: "recvonly" });
  pc.addTransceiver("video", { direction: "recvonly" });

  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);

  // HMAC token: t = expiry (unix s), sign = base64url(HMAC-SHA256(app/stream|t=t)).
  const m = opts.stream.match(/^webrtc:\/\/[^/]+\/([^/]+)\/([^/]+)$/);
  const app = m ? m[1] : "live";
  const stream = m ? m[2] : "livestream";
  const t = Math.floor(Date.now() / 1000) + 3600;
  const msg = `${app}/${stream}|t=${t}`;
  const sign = createHmac("sha256", opts.key).update(msg).digest("base64url");

  let data;
  try {
    const res = await fetch(playUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        sdp: offer.sdp,
        streamurl: opts.stream,
        api: apiBase,
        clientip: "127.0.0.1",
        t: String(t),
        sign,
      }),
      signal: AbortSignal.timeout(SIGNAL_TIMEOUT_MS),
    });
    const text = await res.text();
    try {
      data = JSON.parse(text);
    } catch {
      fail(
        `signaling returned non-JSON (HTTP ${res.status}): ${text.slice(0, 160)}`,
        "signaling"
      );
      return;
    }
  } catch (err) {
    const cause = err.cause ? ` (${err.cause.code || "cause"} ${err.cause.message || ""})` : "";
    fail(`signaling request failed: ${err.message}${cause}`, "signaling");
    return;
  }

  log(`[play] code: ${data.code}`);
  if (data.code !== 0 || !data.sdp) {
    fail(`signaling rejected: code=${data.code}`, "signaling");
    return;
  }

  try {
    await pc.setRemoteDescription({ type: "answer", sdp: data.sdp });
  } catch (err) {
    fail(`setRemoteDescription failed: ${err.message}`, "signaling");
    return;
  }
  log("[sdp] answer set, waiting for DTLS/SRTP media...");

  answerSet = true;
  if (dtlsConnected) {
    armMediaTimeout();
  }
  dtlsTimer = setTimeout(() => {
    if (finished) {
      return;
    }
    if (!dtlsConnected && stats.audio.pkts === 0 && stats.video.pkts === 0) {
      fail(`DTLS timeout: connectionState=${pc.connectionState}`, "dtls");
    }
  }, DTLS_TIMEOUT_MS);

  await new Promise((r) => setTimeout(r, opts.duration));

  if (dtlsTimer) {
    clearTimeout(dtlsTimer);
  }
  if (mediaTimer) {
    clearTimeout(mediaTimer);
  }

  const result = finalizeResult();
  if (json) {
    writeSync(1, JSON.stringify(result) + "\n");
  } else {
    printHuman(result);
  }
  process.exit(result.ok ? 0 : 1);
}

main().catch((err) => {
  fail(`unexpected error: ${err.message}`, "runtime");
});
