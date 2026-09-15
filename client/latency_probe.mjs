// latency_probe.mjs - end-to-end latency probe for the RTMP -> WebRTC path.
//
// Measures how old a video frame is when it reaches the player:
//
//   latency(frame) = arrival_wall_clock - wall_clock_at_which_the_source_emitted_it
//
// The media clock is recovered from the RTP timestamp: the bridge derives it
// straight from the RTMP timestamp (ngx_rtc_h264_timestamp_from_ms, i.e.
// ms * 90, no rebase -- the module's own avsync log asserts
// video_ts / 90 == last_video_rtmp_ms as a sanity baseline). The source side
// of the mapping comes from `ffmpeg -progress`, whose out_time_us is the same
// muxer clock. Feeding ffmpeg's progress through a timestamping reader turns
// "media time" into "wall clock at the encoder output", so the subtraction
// spans encoder -> RTMP -> RTC module -> SRTP -> this process.
//
// This is a *steady-state* number. It is not first_packet_ms / first_keyframe_ms
// (those include the ICE/DTLS handshake and are startup latency).
//
// Both clocks are the same machine clock, so no NTP sync is involved.
//
// usage: node latency_probe.mjs --anchor /tmp/rtc_anchor.txt [--duration 20000]

import { readFileSync, writeSync } from "node:fs";
import { RTCPeerConnection, useH264, useOPUS } from "werift";

import { DEMO_KEY, signToken, streamPathOf } from "./lib/token.mjs";

const API = process.env.RTC_API || "http://127.0.0.1:18082";
const H264_CLOCK = 90000;
const SIGNAL_TIMEOUT_MS = 5000;
const MEDIA_TIMEOUT_MS = 5000;

function log(msg) {
  writeSync(2, msg + "\n");
}

function parseArgs(argv) {
  const opts = {
    stream: "webrtc://127.0.0.1:18082/live/livestream",
    key: DEMO_KEY,
    duration: 20000,
    warmup: 2000,
    anchor: "",
    json: false,
    raw: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--stream") opts.stream = argv[++i];
    else if (arg === "--key") opts.key = argv[++i];
    else if (arg === "--duration") opts.duration = Number.parseInt(argv[++i], 10);
    else if (arg === "--warmup") opts.warmup = Number.parseInt(argv[++i], 10);
    else if (arg === "--anchor") opts.anchor = argv[++i];
    else if (arg === "--json") opts.json = true;
    else if (arg === "--raw") opts.raw = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!opts.anchor) {
    throw new Error("--anchor <ffmpeg -progress capture> is required");
  }
  return opts;
}

/* ffmpeg -progress emits "out_time_us=<microseconds>" once per stats period;
 * the reader that captured it prefixed each line with the wall clock it saw.
 * out_time_us is the muxer's output clock, i.e. the same timeline the RTP
 * timestamp is derived from. */
function loadAnchor(path) {
  const pairs = [];
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^(\d+)\s+out_time_us=(-?\d+)\s*$/);
    if (!m) continue;
    const mediaMs = Number.parseInt(m[2], 10) / 1000;
    if (!Number.isFinite(mediaMs) || mediaMs < 0) continue;
    pairs.push([mediaMs, Number.parseInt(m[1], 10)]);
  }
  pairs.sort((a, b) => a[0] - b[0]);
  if (pairs.length < 2) {
    throw new Error(`anchor ${path}: need at least 2 out_time_us samples, got ${pairs.length}`);
  }
  return pairs;
}

/* Wall clock at which the source emitted `mediaMs`. Between two samples the
 * rate is ffmpeg's own measured pace, so linear interpolation is exact where
 * the two clocks advance together; outside the sampled range the nearest
 * segment is extended (a probe that starts before the capture does). */
function makeMediaToWall(pairs) {
  return (mediaMs) => {
    const n = pairs.length;
    if (mediaMs <= pairs[0][0]) {
      const [m0, w0] = pairs[0];
      const [m1, w1] = pairs[1];
      return w0 + ((mediaMs - m0) * (w1 - w0)) / (m1 - m0);
    }
    if (mediaMs >= pairs[n - 1][0]) {
      const [m0, w0] = pairs[n - 2];
      const [m1, w1] = pairs[n - 1];
      return w1 + ((mediaMs - m1) * (w1 - w0)) / (m1 - m0);
    }
    let lo = 0;
    let hi = n - 1;
    while (hi - lo > 1) {
      const mid = (lo + hi) >> 1;
      if (pairs[mid][0] <= mediaMs) lo = mid;
      else hi = mid;
    }
    const [m0, w0] = pairs[lo];
    const [m1, w1] = pairs[hi];
    return w0 + ((mediaMs - m0) * (w1 - w0)) / (m1 - m0);
  };
}

function percentile(sorted, p) {
  if (0 === sorted.length) return 0;
  const idx = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return sorted[idx];
}

function stats(values) {
  const s = [...values].sort((a, b) => a - b);
  const sum = s.reduce((acc, v) => acc + v, 0);
  return {
    n: s.length,
    min: s[0],
    p50: percentile(s, 50),
    p90: percentile(s, 90),
    p99: percentile(s, 99),
    max: s[s.length - 1],
    mean: sum / s.length,
  };
}

const r1 = (n) => Math.round(n * 10) / 10;

/* NTP epoch (1900) to unix epoch, in seconds. The server fills the SR's NTP
 * field from its own wall clock at send time, which is what makes an SR a
 * usable anchor: it pairs "the server's clock read X" with "the RTP clock read
 * Y", so it can place any RTP timestamp on the server's wall clock without
 * involving ffmpeg or this process. */
const NTP_UNIX_OFFSET = 2208988800;
function ntpToUnixMs(ntp) {
  const sec = Number(ntp >> 32n) - NTP_UNIX_OFFSET;
  const frac = Number(ntp & 0xffffffffn) / 4294967296;
  return (sec + frac) * 1000;
}

/* Group packets into frames by RTP timestamp. A frame is only decodable once
 * its last packet has arrived, so the last arrival is the one that maps onto
 * "the viewer could see this frame". The first arrival is kept as well: the
 * gap between them is the packetization/transit spread of a single frame. */
function framesOf(packets) {
  const byTs = new Map();
  for (const p of packets) {
    const f = byTs.get(p.ts);
    if (undefined === f) {
      byTs.set(p.ts, { ts: p.ts, first: p.wall, last: p.wall, count: 1 });
    } else {
      f.last = p.wall;
      f.count++;
    }
  }
  return [...byTs.values()].sort((a, b) => a.ts - b.ts);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));

  const pc = new RTCPeerConnection({
    codecs: { audio: [useOPUS()], video: [useH264()] },
  });

  const packets = [];
  const senderReports = [];
  let connected = false;
  let mediaSeen = false;
  let resolveDone;
  const done = new Promise((resolve) => {
    resolveDone = resolve;
  });

  pc.onTrack.subscribe((track) => {
    if ("video" !== track.kind) return;
    log(`[track] ${track.kind} ${track.codec?.mimeType || ""}`);
    track.onReceiveRtp.subscribe((rtp) => {
      mediaSeen = true;
      packets.push({ wall: Date.now(), ts: rtp.header.timestamp >>> 0 });
    });
  });

  pc.connectionStateChange.subscribe((state) => {
    if (state === "connected") connected = true;
    if (state === "failed" || state === "closed") {
      log(`[fail] connection ${state}`);
      resolveDone();
    }
  });

  pc.addTransceiver("audio", { direction: "recvonly" });
  pc.addTransceiver("video", { direction: "recvonly" });

  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);

  const label = streamPathOf(opts.stream);
  const { t, sign } = signToken(opts.key, label);

  const startedAt = Date.now();
  const res = await fetch(`${API.replace(/\/+$/, "")}/rtc/v1/play/`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ sdp: offer.sdp, streamurl: opts.stream, api: API, t: String(t), sign }),
    signal: AbortSignal.timeout(SIGNAL_TIMEOUT_MS),
  });
  const body = await res.json();
  log(`[play] code: ${body.code}`);
  if (0 !== body.code) {
    log(`[fail] signaling: ${JSON.stringify(body).slice(0, 200)}`);
    process.exit(1);
  }
  await pc.setRemoteDescription({ type: "answer", sdp: body.sdp });

  for (const receiver of pc.getReceivers()) {
    receiver.onRtcp.subscribe((pkt) => {
      if (200 !== pkt.type || !pkt.senderInfo) return;
      senderReports.push({
        arrival: Date.now(),
        ssrc: pkt.ssrc >>> 0,
        packetCount: pkt.senderInfo.packetCount,
        rtpTs: pkt.senderInfo.rtpTimestamp >>> 0,
        serverWall: ntpToUnixMs(pkt.senderInfo.ntpTimestamp),
      });
    });
  }

  const mediaTimer = setTimeout(() => {
    if (!mediaSeen) {
      log("[fail] media timeout: no RTP packets received");
      resolveDone();
    }
  }, MEDIA_TIMEOUT_MS);

  setTimeout(() => {
    clearTimeout(mediaTimer);
    resolveDone();
  }, opts.duration);
  await done;
  pc.close();

  if (!connected || 0 === packets.length) {
    log(`[fail] connected=${connected} packets=${packets.length}`);
    process.exit(1);
  }

  const frames = framesOf(packets);
  const t0 = frames[0].first;
  const warmupUntil = t0 + opts.warmup;

  const live = frames.filter((f) => f.first >= warmupUntil);
  const replay = frames.length - live.length;
  if (0 === live.length) {
    log(`[fail] every frame fell inside --warmup ${opts.warmup}ms`);
    process.exit(1);
  }

  /* Loaded only now, after the capture has finished writing: reading it up
   * front anchors on whatever ffmpeg had emitted by connect time, and every
   * live frame then falls past the last sample and is extrapolated from the
   * startup burst's slope -- which reports a plausible-looking latency that
   * is wrong by seconds. */
  const anchor = loadAnchor(opts.anchor);
  const mediaToWall = makeMediaToWall(anchor);
  const lo = anchor[0][0];
  const hi = anchor[anchor.length - 1][0];
  const outside = live.filter((f) => f.ts / 90 < lo || f.ts / 90 > hi).length;
  if (0 !== outside) {
    log(`[warn] ${outside}/${live.length} frames fall outside the anchor's ` +
        `${r1(lo)}..${r1(hi)} ms range and are extrapolated`);
  }

  const lastLat = live.map((f) => f.last - mediaToWall(f.ts / 90));
  const firstLat = live.map((f) => f.first - mediaToWall(f.ts / 90));
  const onWire = live.map((f) => f.last - f.first);

  /* Split the total into "source -> server" and "server -> receiver" using the
   * SR as an independent anchor on the server's own clock. The total rests on
   * the ffmpeg -progress anchor; this split rests on the server's, so the two
   * disagreeing is itself the signal that one anchor is wrong. */
  const nearestSr = (ts) => {
    let best = null;
    for (const sr of senderReports) {
      if (null === best || Math.abs(sr.rtpTs - ts) < Math.abs(best.rtpTs - ts)) {
        best = sr;
      }
    }
    return best;
  };
  const serverWallOf = (ts) => {
    const sr = nearestSr(ts);
    if (null === sr) return null;
    return sr.serverWall - (sr.rtpTs - ts) / 90;
  };
  const split = live
    .map((f) => {
      const sw = serverWallOf(f.ts);
      if (null === sw) return null;
      return { toClient: f.last - sw, toServer: sw - mediaToWall(f.ts / 90) };
    })
    .filter(Boolean);

  if (opts.raw) {
    /* arrival, media time, the anchor's claim for that media time, and the
     * difference. A constant difference is a clock-origin question; a slope
     * other than 1.0 is a rate mismatch between the two media clocks. */
    log(`[sr] count=${senderReports.length}`);
    for (const sr of senderReports) {
      log(`[sr] arrival=${sr.arrival} serverWall=${r1(sr.serverWall)} ` +
          `ssrc=0x${sr.ssrc.toString(16)} pkts=${sr.packetCount} ` +
          `rtpTs=${sr.rtpTs} media=${r1(sr.rtpTs / 90)} ` +
          `oneway=${r1(sr.arrival - sr.serverWall)}`);
    }
    log("arrival_ms media_ms anchor_wall_ms lat_ms");
    for (const f of live) {
      const m = f.ts / 90;
      const aw = mediaToWall(m);
      log(`${f.last} ${r1(m)} ${r1(aw)} ${r1(f.last - aw)}`);
    }
  }

  const span = live[live.length - 1].first - live[0].first;
  const out = {
    stream: label,
    frames_total: frames.length,
    frames_replay_excluded: replay,
    frames_live: live.length,
    span_ms: span,
    frame_ms: live.length > 1 ? span / (live.length - 1) : 0,
    latency_ms: stats(lastLat),
    latency_first_packet_ms: stats(firstLat),
    frame_spread_ms: stats(onWire),
    sender_reports: senderReports.length,
    sr_srtt_ms: senderReports.length
      ? stats(senderReports.map((sr) => sr.arrival - sr.serverWall))
      : null,
    leg_to_server_ms: split.length ? stats(split.map((s) => s.toServer)) : null,
    leg_to_client_ms: split.length ? stats(split.map((s) => s.toClient)) : null,
    handshake_ms: t0 - startedAt,
    frames_outside_anchor: outside,
    rates: {
      source_media_per_wall: sourceRate(anchor),
    },
  };

  if (opts.json) {
    writeSync(1, JSON.stringify(out) + "\n");
    return;
  }
  log(`=== 1080p RTMP -> WebRTC end-to-end latency (steady state) ===`);
  log(`frames: ${out.frames_live} live (${replay} replay excluded), ${r1(out.frame_ms)} ms/frame`);
  log(`window: ${r1(out.span_ms / 1000)} s, handshake ${out.handshake_ms} ms`);
  log(`latency (frame complete):  p50=${r1(out.latency_ms.p50)}  p90=${r1(out.latency_ms.p90)}  ` +
      `p99=${r1(out.latency_ms.p99)}  min=${r1(out.latency_ms.min)}  max=${r1(out.latency_ms.max)}`);
  log(`latency (first packet):    p50=${r1(out.latency_first_packet_ms.p50)}  ` +
      `p90=${r1(out.latency_first_packet_ms.p90)}`);
  log(`per-frame packet spread:   p50=${r1(out.frame_spread_ms.p50)}  max=${r1(out.frame_spread_ms.max)}`);
  if (out.leg_to_server_ms) {
    log(`split (${out.sender_reports} SRs, SR one-way p50=${r1(out.sr_srtt_ms.p50)} ms):`);
    log(`  source -> server:  p50=${r1(out.leg_to_server_ms.p50)}  ` +
        `p90=${r1(out.leg_to_server_ms.p90)} ms`);
    log(`  server -> client:  p50=${r1(out.leg_to_client_ms.p50)}  ` +
        `p90=${r1(out.leg_to_client_ms.p90)} ms`);
  }
  writeSync(1, JSON.stringify(out) + "\n");
}

/* Media-clock rate of the capture, as a sanity check on the anchor: a value
 * far from 1.0 means ffmpeg was not pacing in real time and the run is not a
 * live stream, whatever the latency numbers say. */
function sourceRate(pairs) {
  const a = pairs[0];
  const b = pairs[pairs.length - 1];
  return (b[0] - a[0]) / (b[1] - a[1]);
}

main().catch((err) => {
  log(`[fail] ${err.message}`);
  process.exit(1);
});
