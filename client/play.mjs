import { RTCPeerConnection, useH264, useOPUS } from "werift";
import { writeSync } from "node:fs";

import { DEMO_KEY, signToken, streamPathOf } from "./lib/token.mjs";

const DEFAULT_STREAM = "webrtc://127.0.0.1:18082/live/livestream";
const DEFAULT_KEY = DEMO_KEY;
const DEFAULT_API = "http://127.0.0.1:18082";
const DEFAULT_DURATION = 8000;

/* Loss is measured only after this much of a track has been received. The
 * server replays its cached GOP the moment SRTP becomes ready, so the first
 * packets after connect are a deliberately discontinuous burst; on a 4 s
 * window the largest sequence gap sits at the 3rd received packet and measured
 * 8..5952 packets, which read as 1.4%..83% "loss" on a link that lost nothing.
 * --warmup 0 restores the old whole-window number. */
const DEFAULT_WARMUP = 1000;

const DTLS_TIMEOUT_MS = 5000;
const MEDIA_TIMEOUT_MS = 3000;
const SIGNAL_TIMEOUT_MS = 5000;

function printHelp() {
  // Interpolated rather than written out: the previous hand-written text
  // promised `--key ... default demo-key-123` while the code defaulted to the
  // demo secret, so following the help verbatim produced a 403.
  const lines = [
    "usage: node play.mjs [options]",
    `  --stream <url>    stream URL; repeatable, played in order`,
    `                    (default ${DEFAULT_STREAM})`,
    `  --key <key>       stream key; repeatable, paired with --stream by position.`,
    `                    Fewer keys than streams repeats the last one, which is what`,
    `                    makes a single key cover a whole transcode ladder.`,
    `                    (default ${DEFAULT_KEY})`,
    `  --api <url>       signaling API base URL (default ${DEFAULT_API})`,
    `  --duration <ms>   receive duration per stream (default ${DEFAULT_DURATION})`,
    `  --warmup <ms>     exclude this much of each track from loss accounting`,
    `                    (default ${DEFAULT_WARMUP}; 0 = count from the first packet)`,
    "  --json            one JSON object per stream, one per line, on stdout",
    "  --dump            enable per-packet debug dump (written to stderr)",
  ];
  writeSync(1, lines.join("\n") + "\n");
  process.exit(0);
}

function parseArgs(argv) {
  const opts = {
    streams: [],
    keys: [],
    api: DEFAULT_API,
    duration: DEFAULT_DURATION,
    warmup: DEFAULT_WARMUP,
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
        opts.streams.push(take());
        break;
      case "--key":
        opts.keys.push(take());
        break;
      case "--api":
        opts.api = take();
        break;
      case "--duration":
        opts.duration = Number.parseInt(take(), 10);
        break;
      case "--warmup":
        opts.warmup = Number.parseInt(take(), 10);
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
  if (0 === opts.streams.length) {
    opts.streams.push(DEFAULT_STREAM);
  }
  if (opts.keys.length > opts.streams.length) {
    throw new Error(
      `${opts.keys.length} --key for ${opts.streams.length} --stream: too many keys`
    );
  }
  if (!Number.isFinite(opts.duration) || opts.duration <= 0) {
    throw new Error("invalid --duration (must be a positive integer in ms)");
  }
  if (!Number.isFinite(opts.warmup) || opts.warmup < 0) {
    throw new Error("invalid --warmup (must be a non-negative integer in ms)");
  }
  if (opts.warmup >= opts.duration) {
    writeSync(
      2,
      `[warn] --warmup ${opts.warmup}ms >= --duration ${opts.duration}ms: every packet is ` +
        `inside the warm-up, so loss_rate_percent is 0 by construction\n`
    );
  }
  return opts;
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
    /* lost is the whole-window count and exists only so the two windowed
     * counters below can be audited against it in a single run: by
     * construction lost === lostPost + warmupLost. */
    lost: 0,
    lostPost: 0,
    lastSeq: -1,
    /* Warm-up state. warmupUntil is an absolute Date.now() and is 0 once the
     * track is past its warm-up (or once --warmup 0 disabled it). */
    warmupUntil: 0,
    warmupLost: 0,
    postPkts: 0,
    jitter: 0,
    jitterInit: false,
    lastTransit: 0,
    lastSec: -1,
    curBucketBytes: 0,
    lastBucketBytes: 0,
  };
}

// Hot path: no object allocation, no string building, no optional chaining.
// `run` carries the per-stream state, so nothing here reads a module global --
// that is what lets one process play several streams in sequence.
function handleRtp(s, rtp, run) {
  const now = Date.now();
  const payload = rtp.payload;
  const hdr = rtp.header;

  if (s.first === 0) {
    s.first = now - run.startMs;
    /* Anchored to this track's first packet, not to process start: the
     * ICE/DTLS handshake costs 500-700 ms and jitters run to run, so anchoring
     * on startMs moves the measured window by whatever the handshake cost --
     * which is how the same healthy stream came to report 1.4%..15.8%. */
    s.warmupUntil = now + run.warmupMs;
  }
  s.pkts++;
  const size = (payload ? payload.length : 0) + 12;
  s.bytes += size;

  const seq = hdr.sequenceNumber;
  const inWarmup = 0 !== s.warmupUntil && now < s.warmupUntil;

  if (0 !== s.warmupUntil && !inWarmup) {
    /* First packet past the boundary. Realign instead of charging the gap
     * between the replay burst and the live stream as loss, and skip this
     * packet's own delta too: a gap straddling the boundary is then dropped
     * rather than attributed to either side. */
    s.warmupUntil = 0;
    s.lastSeq = -1;
  }

  if (s.lastSeq >= 0) {
    const delta = (seq - s.lastSeq) & 0xffff;
    if (delta > 1 && delta < 0x8000) {
      s.lost += delta - 1;
      if (inWarmup) {
        s.warmupLost += delta - 1;
      } else {
        s.lostPost += delta - 1;
      }
    }
  }
  s.lastSeq = seq;
  if (!inWarmup) {
    s.postPkts++;
  }

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
  const sec = Math.floor((now - run.startMs) / 1000);
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
          s.keyframe = now - run.startMs;
          run.log(`[keyframe] first H264 IDR at ${s.keyframe} ms`);
        }
        s.keyframes++;
      }
    }
  }

  if (run.dumpEnabled && payload && payload.length >= 1) {
    const b0 = payload[0] & 0x1f;
    const nalName =
      b0 === 28 ? "FU-A" : b0 === 24 ? "STAP-A" : b0 === 5 ? "IDR" : `NAL${b0}`;
    // The stream label is part of the line: with several streams in one run
    // the packets are otherwise impossible to attribute.
    writeSync(
      2,
      `[dump] ${run.label} ${s.kind} seq=${hdr.sequenceNumber} ts=${hdr.timestamp} ` +
        `len=${payload.length} nal=${nalName}\n`
    );
  }
}

function buildTrackResult(s, elapsedMs) {
  /* The denominator is the post-warm-up received count, not s.pkts: pairing a
   * warm-up-excluded numerator with a whole-window denominator would understate
   * the rate. Everything else here (bytes, bitrate, fps) deliberately still
   * covers the whole window and is documented as such. */
  const expected = s.postPkts + s.lostPost;
  const lossRate = expected > 0 ? (s.lostPost / expected) * 100 : 0;
  const avgBitrateKbps = elapsedMs > 0 ? (s.bytes * 8) / elapsedMs : 0;
  const lastBitrateKbps =
    s.lastBucketBytes > 0 ? (s.lastBucketBytes * 8) / 1000 : avgBitrateKbps;
  const r = {
    packets: s.pkts,
    bytes: s.bytes,
    codec: s.codec,
    first_packet_ms: s.first,
    loss_rate_percent: round2(lossRate),
    lost_packets: s.lostPost,
    warmup_lost_packets: s.warmupLost,
    /* Invariant: lost_packets + warmup_lost_packets === lost_packets_all. A
     * gap straddling the warm-up boundary is dropped from all three, so the
     * warm-up never hides a loss that --warmup 0 would have shown. */
    lost_packets_all: s.lost,
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

function finalizeResult(run) {
  const elapsedMs = Date.now() - run.startMs;
  const ok = run.stats.audio.pkts > 0 && run.stats.video.pkts > 0;
  return {
    ok,
    stream: run.stream,
    duration_ms: elapsedMs,
    warmup_ms: run.warmupMs,
    audio: buildTrackResult(run.stats.audio, elapsedMs),
    video: buildTrackResult(run.stats.video, elapsedMs),
  };
}

function printHuman(run, result) {
  const log = run.log;
  log(`\n=== ${run.label} ===`);
  log(
    `loss is measured after the first ${run.warmupMs} ms of each track; ` +
      `packets/bytes/bitrate/fps cover the whole ${result.duration_ms} ms`
  );
  for (const kind of ["audio", "video"]) {
    const s = run.stats[kind];
    const r = result[kind];
    let line =
      `${kind}: packets=${s.pkts} bytes=${s.bytes} codec=${s.codec}` +
      ` first_packet_ms=${s.first} loss_rate=${r.loss_rate_percent}%` +
      ` lost=${r.lost_packets}` +
      ` jitter_ms=${r.jitter_ms} bitrate_kbps=${r.bitrate_kbps}`;
    if (r.warmup_lost_packets > 0) {
      line += ` warmup_lost=${r.warmup_lost_packets}`;
    }
    if (s.isVideo) {
      line += ` fps=${r.fps} keyframes=${s.keyframes}`;
    }
    log(line);
  }
  log(
    `video: first_keyframe_ms=${run.stats.video.keyframe} (首个 H264 IDR 到达, 真正出图延迟口径)`
  );
  log(result.ok ? "[PASS] 音视频均经 WebRTC 收到 RTP 包" : "[FAIL] 未收到媒体包");
}

/*
 * Play one stream to completion and return its result object, or throw for a
 * failure the caller should turn into a per-stream error record. Nothing here
 * touches process state: several streams run in sequence in one process, so
 * every counter and timer is local to this call.
 */
async function runOne(target, opts) {
  const apiBase = opts.api.replace(/\/+$/, "");
  const playUrl = `${apiBase}/rtc/v1/play/`;
  const label = streamPathOf(target.stream);

  const run = {
    stream: target.stream,
    label,
    startMs: Date.now(),
    warmupMs: opts.warmup,
    dumpEnabled: opts.dump,
    stats: {
      audio: makeTrackStats("audio", false),
      video: makeTrackStats("video", true),
    },
  };
  run.log = (msg) => writeSync(opts.json ? 2 : 1, msg + "\n");

  let finished = false;
  let failure = null;
  let abort;
  const aborted = new Promise((resolve) => {
    abort = resolve;
  });

  /* Records the failure for the caller and ends this stream's wait at once.
   * It must not call process.exit: a later --stream is still owed a run. The
   * timers below fire outside the awaited flow, which is why ending the wait
   * takes an explicit signal rather than just falling out of scope. */
  const fail = (reason, phase) => {
    if (finished) {
      return;
    }
    finished = true;
    failure = { ok: false, stream: run.stream, error: reason, phase };
    abort();
  };

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
      if (run.stats.audio.pkts === 0 && run.stats.video.pkts === 0) {
        fail("media timeout: no RTP packets received", "media");
      }
    }, MEDIA_TIMEOUT_MS);
  };

  try {
    pc.connectionStateChange.subscribe((state) => {
      if (run.dumpEnabled) {
        run.log(`[dtls] connectionState=${state}`);
      }
      if (state === "connected") {
        dtlsConnected = true;
        if (answerSet) {
          armMediaTimeout();
        }
      } else if (state === "failed" || state === "closed") {
        if (run.stats.audio.pkts === 0 && run.stats.video.pkts === 0) {
          fail(`DTLS failed (state=${state})`, "dtls");
        }
      }
    });

    pc.onTrack.subscribe((track) => {
      const isVideo = track.kind === "video";
      const s = run.stats[track.kind] || makeTrackStats(track.kind, isVideo);
      run.stats[track.kind] = s;
      s.codec = track.codec?.mimeType || "";
      if (track.codec?.clockRate) {
        s.clockRate = track.codec.clockRate;
      }
      run.log(`[track] ${track.kind} ${s.codec}`);
      track.onReceiveRtp.subscribe((rtp) => handleRtp(s, rtp, run));
    });

    pc.addTransceiver("audio", { direction: "recvonly" });
    pc.addTransceiver("video", { direction: "recvonly" });

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    // HMAC token over the stream path; see client/lib/token.mjs.
    const { t, sign } = signToken(target.key, label);

    let data;
    try {
      const res = await fetch(playUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          sdp: offer.sdp,
          streamurl: target.stream,
          api: apiBase,
          t: String(t),
          sign,
        }),
        signal: AbortSignal.timeout(SIGNAL_TIMEOUT_MS),
      });
      const text = await res.text();
      try {
        data = JSON.parse(text);
      } catch {
        throw new StreamError(
          `signaling returned non-JSON (HTTP ${res.status}): ${text.slice(0, 160)}`,
          "signaling"
        );
      }
    } catch (err) {
      if (err instanceof StreamError) {
        throw err;
      }
      const cause = err.cause
        ? ` (${err.cause.code || "cause"} ${err.cause.message || ""})`
        : "";
      throw new StreamError(`signaling request failed: ${err.message}${cause}`, "signaling");
    }

    run.log(`[play] code: ${data.code}`);
    if (data.code !== 0 || !data.sdp) {
      throw new StreamError(`signaling rejected: code=${data.code}`, "signaling");
    }

    try {
      await pc.setRemoteDescription({ type: "answer", sdp: data.sdp });
    } catch (err) {
      throw new StreamError(`setRemoteDescription failed: ${err.message}`, "signaling");
    }
    run.log("[sdp] answer set, waiting for DTLS/SRTP media...");

    answerSet = true;
    if (dtlsConnected) {
      armMediaTimeout();
    }
    dtlsTimer = setTimeout(() => {
      if (finished) {
        return;
      }
      if (!dtlsConnected && run.stats.audio.pkts === 0 && run.stats.video.pkts === 0) {
        fail(`DTLS timeout: connectionState=${pc.connectionState}`, "dtls");
      }
    }, DTLS_TIMEOUT_MS);

    await Promise.race([
      new Promise((r) => setTimeout(r, opts.duration)),
      aborted,
    ]);

    if (failure) {
      throw new StreamError(failure.error, failure.phase);
    }
    run.result = finalizeResult(run);
    return run;
  } finally {
    /* Both timers and the peer connection are per-stream and must not outlive
     * this call: an unclosed PC keeps its sockets and its onReceiveRtp
     * subscription pointing at this run's stats, and a leaked dtlsTimer would
     * fire during a later stream and fail that one instead. */
    if (dtlsTimer) {
      clearTimeout(dtlsTimer);
    }
    if (mediaTimer) {
      clearTimeout(mediaTimer);
    }
    await pc.close();
  }
}

class StreamError extends Error {
  constructor(message, phase) {
    super(message);
    this.phase = phase;
  }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));

  const targets = opts.streams.map((stream, i) => ({
    stream,
    // Fewer keys than streams repeats the last one: the whole ladder shares the
    // demo secret, so `--stream a --stream b --key k` has to mean both.
    key: 0 === opts.keys.length
      ? DEFAULT_KEY
      : opts.keys[Math.min(i, opts.keys.length - 1)],
  }));

  let failed = 0;
  for (const target of targets) {
    const label = streamPathOf(target.stream);
    let run;
    try {
      run = await runOne(target, opts);
    } catch (err) {
      const record = {
        ok: false,
        stream: target.stream,
        error: err.message,
        phase: err.phase || "runtime",
      };
      if (opts.json) {
        writeSync(1, JSON.stringify(record) + "\n");
      } else {
        writeSync(1, `[FAIL] ${label}: ${err.message}\n`);
      }
      failed++;
      continue;
    }
    if (opts.json) {
      writeSync(1, JSON.stringify(run.result) + "\n");
    } else {
      printHuman(run, run.result);
    }
    if (!run.result.ok) {
      failed++;
    }
  }

  if (targets.length > 1) {
    const line = `${targets.length - failed}/${targets.length} 路通过\n`;
    writeSync(opts.json ? 2 : 1, line);
  }
  process.exit(failed > 0 ? 1 : 0);
}

main().catch((err) => {
  writeSync(2, `[FAIL] unexpected error: ${err.message}\n`);
  process.exit(1);
});
