// connect_probe.mjs - where the connection-setup latency goes.
//
// play.mjs reports first_packet_ms / first_keyframe_ms as two single numbers,
// both counted from just before the RTCPeerConnection is built. That span
// covers four unrelated costs: building the local description (which for werift
// means waiting out ICE gathering), the signaling round trip, the DTLS
// handshake, and the wait for a decodable frame. Optimizing any of them needs
// them separated, which is what this probe does.
//
// Every mark is a delta from a t0 taken immediately before the peer connection
// exists, so the numbers line up with play.mjs's first_packet_ms by
// construction. One machine clock covers both sides, so no clock sync is
// involved.
//
// The client half is not the server's to fix, and two of its costs dominate the
// total on loopback:
//
//   - setLocalDescription() does not resolve until ICE gathering finishes, and
//     gathering waits on STUN. Host candidates land in ~6 ms; the srflx ones
//     dribble in over the next ~110 ms, and a configured-but-unreachable STUN
//     server stalls the whole thing for 5 s. The offer this probe sends is
//     non-trickle, so that wait is on the critical path. A browser does not
//     block on gathering, so it does not pay this.
//   - the DTLS handshake is JS crypto on this side (werift), cold at ~185 ms and
//     ~110 ms once the JIT is warm, against a C server on the other.
//
// This measures *startup* latency. Steady-state freshness of a playing stream
// is latency_probe.mjs's job, and the two are not comparable.
//
// usage: node connect_probe.mjs [--runs 5] [--api http://127.0.0.1:18082]

import { writeSync } from "node:fs";
import { RTCPeerConnection, useH264, useOPUS } from "werift";

import { DEMO_KEY, signToken, streamPathOf } from "./lib/token.mjs";

const API = process.env.RTC_API || "http://127.0.0.1:18082";
const SIGNAL_TIMEOUT_MS = 5000;
const IDR_TIMEOUT_MS = 8000;

/* The phases, in the order they can happen. Each is [label, from, to], where
 * the endpoints are mark names or the literal "t0". A missing endpoint drops
 * the phase from the summary rather than reporting a zero -- an absent mark
 * means "not observed", and folding that into 0 ms would invent a fast phase. */
const PHASES = [
  ["pc built", "t0", "pc_built"],
  ["createOffer", "pc_built", "offer"],
  ["setLocalDescription", "offer", "local_sdp"],
  ["signal RTT", "sig_sent", "sig_recv"],
  ["answer set", "sig_recv", "answer"],
  ["ICE", "answer", "ice_up"],
  ["DTLS", "ice_up", "dtls_up"],
  ["SRTP to 1st RTP", "dtls_up", "rtp:video"],
  ["1st RTP to IDR", "rtp:video", "idr"],
];

function parseArgs(argv) {
  const opts = {
    stream: "webrtc://127.0.0.1:18082/live/livestream",
    key: DEMO_KEY,
    api: API,
    runs: 5,
    json: false,
    raw: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--stream") opts.stream = argv[++i];
    else if (arg === "--key") opts.key = argv[++i];
    else if (arg === "--api") opts.api = argv[++i];
    else if (arg === "--runs") opts.runs = Number.parseInt(argv[++i], 10);
    else if (arg === "--json") opts.json = true;
    else if (arg === "--raw") opts.raw = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!Number.isFinite(opts.runs) || opts.runs < 1) {
    throw new Error("--runs must be a positive integer");
  }
  return opts;
}

function log(msg) {
  writeSync(2, msg + "\n");
}

function percentile(sorted, p) {
  if (0 === sorted.length) return 0;
  const idx = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return sorted[idx];
}

function round1(n) {
  return Math.round(n * 10) / 10;
}

/* First mark among `names`, which lets a phase accept whichever of several
 * equivalent events the implementation happened to emit. */
function firstMark(marks, names) {
  for (const name of names) {
    if (marks.has(name)) {
      return marks.get(name);
    }
  }
  return null;
}

function isIdr(payload) {
  if (!payload || payload.length < 1) {
    return false;
  }
  const b0 = payload[0] & 0x1f;
  const nal = b0 === 28 && payload.length >= 2 ? payload[1] & 0x1f : b0;
  return nal === 5;
}

/* One connection, every phase. Returns the mark table plus the per-track codec
 * names, or throws for a failure the caller records as a bad run. */
async function runOnce(target, opts) {
  const t0Wall = Date.now();
  const t0 = performance.now();
  const marks = new Map();
  let finish = null;
  const finished = new Promise((r) => (finish = r));

  const mark = (name) => {
    if (marks.has(name)) {
      return;
    }
    marks.set(name, performance.now() - t0);
  };
  const markAndFinish = (name) => {
    mark(name);
    finish();
  };

  const pc = new RTCPeerConnection({
    codecs: { audio: [useOPUS()], video: [useH264()] },
  });
  mark("pc_built");

  /* Transports can be created by either description, so both call sites attach
   * and the WeakSet keeps a transport from being subscribed twice. */
  const attached = new WeakSet();
  const attachTransports = () => {
    for (const t of pc.iceTransports) {
      if (attached.has(t)) continue;
      attached.add(t);
      t.onStateChange.subscribe((s) => mark(`icetransport:${s}`));
    }
    for (const t of pc.dtlsTransports) {
      if (attached.has(t)) continue;
      attached.add(t);
      t.onStateChange.subscribe((s) => {
        mark(`dtls:${s}`);
        if (answerSeen && "connected" === s) mark("dtls_up");
      });
    }
  };

  /* ice_up / dtls_up are gated on the answer having been set. werift drives its
   * own ICE state machine as soon as the local description exists, and on
   * loopback that reaches "completed" with no remote candidate at all -- so an
   * ungated mark would date the handshake before the signaling that causes it.
   * The raw states stay in the mark table either way. */
  let answerSeen = false;

  pc.connectionStateChange.subscribe((s) => mark(`conn:${s}`));
  pc.iceConnectionStateChange.subscribe((s) => {
    mark(`iceconn:${s}`);
    /* 'completed' is the steady state after 'connected' on some stacks; both
     * mean the path is up, and whichever lands first is the useful mark. */
    if (answerSeen && ("connected" === s || "completed" === s)) mark("ice_up");
  });
  pc.iceGatheringStateChange.subscribe((s) => mark(`gather:${s}`));

  pc.onTrack.subscribe((track) => {
    track.onReceiveRtp.subscribe((rtp) => {
      const name = `rtp:${track.kind}`;
      mark(name);
      if ("video" === track.kind && isIdr(rtp.payload) && !marks.has("idr")) {
        markAndFinish("idr");
      }
    });
  });

  try {
    pc.addTransceiver("audio", { direction: "recvonly" });
    pc.addTransceiver("video", { direction: "recvonly" });

    const offer = await pc.createOffer();
    mark("offer");
    await pc.setLocalDescription(offer);
    mark("local_sdp");
    attachTransports();

    const { t, sign } = signToken(target.key, target.label);

    mark("sig_sent");
    let data;
    const res = await fetch(`${opts.api.replace(/\/+$/, "")}/rtc/v1/play/`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        sdp: offer.sdp,
        streamurl: target.stream,
        api: opts.api,
        t: String(t),
        sign,
      }),
      signal: AbortSignal.timeout(SIGNAL_TIMEOUT_MS),
    });
    const text = await res.text();
    mark("sig_recv");
    try {
      data = JSON.parse(text);
    } catch {
      throw new Error(`signaling returned non-JSON (HTTP ${res.status}): ${text.slice(0, 120)}`);
    }
    if (0 !== data.code || !data.sdp) {
      throw new Error(`signaling rejected: code=${data.code}`);
    }

    await pc.setRemoteDescription({ type: "answer", sdp: data.sdp });
    mark("answer");
    answerSeen = true;
    attachTransports();
    /* Both states can have advanced while the answer was in flight, in which
     * case no further transition event is coming and the gate above would
     * swallow the mark. */
    if ("connected" === pc.iceConnectionState || "completed" === pc.iceConnectionState) {
      mark("ice_up");
    }
    if (pc.dtlsTransports.some((t) => "connected" === t.state)) {
      mark("dtls_up");
    }

    const timedOut = await Promise.race([
      finished.then(() => false),
      new Promise((r) => setTimeout(() => r(true), IDR_TIMEOUT_MS)),
    ]);
    mark("settled");

    return { t0Wall, marks, timedOut };
  } finally {
    await pc.close();
  }
}

/* Phase table for one run. A phase whose endpoints were not both observed is
 * reported as null, never as 0 -- see PHASES. */
function phasesOf(marks) {
  const at = (name) => ("t0" === name ? 0 : marks.has(name) ? marks.get(name) : null);
  const out = {};
  for (const [label, from, to] of PHASES) {
    const a = at(from);
    const b = at(to);
    out[label] = null === a || null === b ? null : round1(b - a);
  }
  return out;
}

function summarize(runs) {
  const rows = [];
  for (const [label] of PHASES) {
    const values = runs.map((r) => r.phases[label]).filter((v) => null !== v);
    if (0 === values.length) {
      continue;
    }
    values.sort((a, b) => a - b);
    rows.push({
      phase: label,
      n: values.length,
      p50: round1(percentile(values, 50)),
      min: round1(values[0]),
      max: round1(values[values.length - 1]),
    });
  }
  const totals = runs.map((r) => r.total).filter((v) => null !== v).sort((a, b) => a - b);
  return {
    rows,
    total: {
      n: totals.length,
      p50: round1(percentile(totals, 50)),
      min: totals.length ? round1(totals[0]) : 0,
      max: totals.length ? round1(totals[totals.length - 1]) : 0,
    },
  };
}

/* Per-run dump of every mark, so a run that fails to reach a phase can be read
 * for how far it got rather than just coming back null. */
function printMarks(label, run) {
  const parts = [...run.marks.entries()]
    .sort((a, b) => a[1] - b[1])
    .map(([name, at]) => `${name}=${round1(at)}`);
  log(`[marks] run ${label}: ${parts.join(" ")}`);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const label = streamPathOf(opts.stream);
  const target = { stream: opts.stream, key: opts.key, label };

  const runs = [];
  for (let i = 1; i <= opts.runs; i++) {
    let run;
    try {
      run = await runOnce(target, opts);
    } catch (err) {
      log(`[fail] run ${i}: ${err.message}`);
      continue;
    }
    const phases = phasesOf(run.marks);
    const firstRtp = firstMark(run.marks, ["rtp:video", "rtp:audio"]);
    runs.push({
      index: i,
      t0Wall: run.t0Wall,
      marks: run.marks,
      phases,
      /* Total to the first decodable frame, the same quantity play.mjs calls
       * first_keyframe_ms. Falls back to the first packet when no IDR arrived,
       * flagged so the two are not confused. */
      total: run.marks.has("idr") ? round1(run.marks.get("idr")) : null,
      firstPacket: null === firstRtp ? null : round1(firstRtp),
      timedOut: run.timedOut,
    });
    if (opts.raw) {
      printMarks(i, run);
    }
    const p = phases;
    /* Built from PHASES so the per-run line cannot drift from the table. */
    const parts = PHASES.map(
      ([label]) => `${label}=${null === p[label] ? "?" : p[label]}`
    ).join(" ");
    log(
      `run ${i}: ${parts} => first_packet ` +
        `${null === runs[runs.length - 1].firstPacket ? "none" : runs[runs.length - 1].firstPacket} ms, ` +
        `total ${null === runs[runs.length - 1].total ? "none" : runs[runs.length - 1].total} ms`
    );
  }

  if (0 === runs.length) {
    log("[fail] every run failed before recording a phase");
    process.exit(1);
  }

  const summary = summarize(runs);
  if (opts.json) {
    writeSync(1, JSON.stringify({ stream: opts.stream, runs, summary }) + "\n");
    process.exit(0);
  }

  const width = Math.max(...summary.rows.map((r) => r.phase.length), 5);
  log(`\n=== connection setup, ${runs.length} run(s), ms ===`);
  log(`${"phase".padEnd(width)}  ${"p50".padStart(7)} ${"min".padStart(7)} ${"max".padStart(7)}   n`);
  for (const r of summary.rows) {
    log(
      `${r.phase.padEnd(width)}  ${String(r.p50).padStart(7)} ${String(r.min).padStart(7)} ` +
        `${String(r.max).padStart(7)}   ${r.n}`
    );
  }
  log(
    `${"TOTAL to IDR".padEnd(width)}  ${String(summary.total.p50).padStart(7)} ` +
      `${String(summary.total.min).padStart(7)} ${String(summary.total.max).padStart(7)}   ${summary.total.n}`
  );
  log("\nPass --raw for every mark of every run (candidate gathering, ICE/DTLS states, per-track first packet).");

  /* Explicit exit, as play.mjs does. A closed peer connection does not give
   * back the UDP socket werift pooled for it, so the event loop has a live
   * handle per run and the process outlives its work -- 40 runs sat for three
   * minutes after printing every result. */
  process.exit(0);
}

main().catch((err) => {
  writeSync(2, `[FAIL] ${err.message}\n`);
  process.exit(1);
});
