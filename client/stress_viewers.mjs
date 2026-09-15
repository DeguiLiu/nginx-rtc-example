// stress_viewers.mjs - sustained viewer churn against one stream.
//
// The failure this exists to catch is the one probe_connection_reuse.mjs
// reproduces deterministically in miniature: nginx keys its stream UDP
// connection on the peer address while the module keys RTC sessions on the
// ICE ufrag, so several sessions can share one connection, and tearing one
// down used to take the connection out from under the others. That probe
// proves the case is handled; this one puts it under load, where the same
// defect shows up as a rare crash rather than a deterministic one.
//
// Each *slot* owns a pinned two-port range (werift rejects min == max), so
// every viewer that runs in slot i arrives from the same peer address as the
// one before it and lands on the same nginx connection. Slots are looped until
// the deadline, which is what makes this churn rather than a one-shot burst:
// each slot walks a connection through many sessions, and the module closes
// the previous owner on every one of those attaches.
//
// A werift viewer never sends RTCP BYE -- the library has no such packet --
// so every close here is an abrupt one and the server keeps streaming into the
// session until rtc_ready_timeout. That is deliberate: it is the abandoned-viewer
// path, the expensive one, and the one a real closed tab produces.
//
// usage: node stress_viewers.mjs --stream <webrtc://host/app/name> [--key K]
//                                [--concurrent 8] [--duration 60] [--hold 5]
//                                [--port-base 43000] [--api URL] [--json]
//
// Everything it reports is client-side. Whether the server survived is read
// from its error.log by scripts/stress-stability.sh.

import { writeSync } from "node:fs";
import { RTCPeerConnection, useH264, useOPUS } from "werift";

import { DEMO_KEY, signToken, streamPathOf } from "./lib/token.mjs";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const nowMs = () => Date.now();

function parseArgs(argv) {
  const opts = {
    stream: "webrtc://127.0.0.1:18082/live/livestream",
    key: DEMO_KEY,
    api: "http://127.0.0.1:18082",
    concurrent: 8,
    duration: 60,
    hold: 5,
    portBase: 43000,
    json: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--stream") opts.stream = argv[++i];
    else if (arg === "--key") opts.key = argv[++i];
    else if (arg === "--api") opts.api = argv[++i];
    else if (arg === "--concurrent") opts.concurrent = Number.parseInt(argv[++i], 10);
    else if (arg === "--duration") opts.duration = Number.parseInt(argv[++i], 10);
    else if (arg === "--hold") opts.hold = Number.parseInt(argv[++i], 10);
    else if (arg === "--port-base") opts.portBase = Number.parseInt(argv[++i], 10);
    else if (arg === "--json") opts.json = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  return opts;
}

function log(msg) {
  writeSync(2, msg + "\n");
}

/* Percentiles over a small sample: nearest-rank, no interpolation. The numbers
 * here are used to compare runs, not to be quoted as a distribution. */
function pct(values, p) {
  if (0 === values.length) {
    return null;
  }
  const sorted = [...values].sort((a, b) => a - b);
  const rank = Math.ceil((p / 100) * sorted.length);
  return sorted[Math.min(sorted.length - 1, Math.max(0, rank - 1))];
}

/* One viewer: connect, receive for `holdMs`, then leave without a goodbye.
 * `firstPacketMs` is measured from the offer, so it covers signaling, ICE and
 * DTLS -- the number a viewer actually experiences as time-to-picture. */
async function viewer(target, opts, slot, holdMs) {
  const port = opts.portBase + slot * 2;
  const pc = new RTCPeerConnection({
    codecs: { audio: [useOPUS()], video: [useH264()] },
    icePortRange: [port, port + 1],
  });

  let pkts = 0;
  let firstPacket = 0;
  pc.onTrack.subscribe((track) =>
    track.onReceiveRtp.subscribe(() => {
      pkts++;
      if (0 === firstPacket) {
        firstPacket = nowMs() - started;
      }
    })
  );

  const started = nowMs();
  let answerMs = 0;

  pc.addTransceiver("audio", { direction: "recvonly" });
  pc.addTransceiver("video", { direction: "recvonly" });
  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);

  const { t, sign } = signToken(target.key, target.label);
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
    signal: AbortSignal.timeout(5000),
  });
  const data = await res.json();
  if (0 !== data.code || !data.sdp) {
    throw new Error(`signaling rejected code=${data.code}`);
  }
  await pc.setRemoteDescription({ type: "answer", sdp: data.sdp });
  answerMs = nowMs() - started;

  await sleep(holdMs);
  await pc.close();
  return { pkts, firstPacket, answerMs };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const target = {
    stream: opts.stream,
    key: opts.key,
    label: streamPathOf(opts.stream),
  };
  const deadline = nowMs() + opts.duration * 1000;

  log(
    `churn: ${opts.concurrent} slots, hold ${opts.hold}s, ${opts.duration}s, ` +
      `ports ${opts.portBase}..${opts.portBase + opts.concurrent * 2 - 1}`
  );

  const state = {
    connects: 0,
    failed: 0,
    silent: 0,
    pkts: 0,
    active: 0,
    firstPacket: [],
    answer: [],
    errors: new Map(),
  };

  const beat = setInterval(() => {
    log(
      `  t+${Math.round((nowMs() - (deadline - opts.duration * 1000)) / 1000)}s ` +
        `active=${state.active} connects=${state.connects} failed=${state.failed} ` +
        `silent=${state.silent}`
    );
  }, 5000);

  async function slot(i) {
    // Stagger the first round so all slots do not hit signaling in one tick;
    // after that each slot self-paces off its own hold time.
    await sleep((i * opts.hold * 1000) / opts.concurrent);
    while (nowMs() < deadline) {
      state.active++;
      try {
        const r = await viewer(target, opts, i, opts.hold * 1000);
        state.connects++;
        state.pkts += r.pkts;
        state.answer.push(r.answerMs);
        if (0 === r.pkts) {
          state.silent++;
        } else {
          state.firstPacket.push(r.firstPacket);
        }
      } catch (err) {
        state.failed++;
        state.errors.set(err.message, (state.errors.get(err.message) || 0) + 1);
      } finally {
        state.active--;
      }
    }
  }

  await Promise.all(Array.from({ length: opts.concurrent }, (_, i) => slot(i)));
  clearInterval(beat);

  const summary = {
    shard: opts.portBase,
    concurrent: opts.concurrent,
    duration_s: opts.duration,
    connects: state.connects,
    failed: state.failed,
    silent_viewers: state.silent,
    connect_rate_per_s: Number((state.connects / opts.duration).toFixed(2)),
    packets: state.pkts,
    first_packet_ms: {
      n: state.firstPacket.length,
      p50: pct(state.firstPacket, 50),
      p90: pct(state.firstPacket, 90),
    },
    answer_ms: { n: state.answer.length, p50: pct(state.answer, 50) },
    errors: Object.fromEntries(state.errors),
  };

  if (opts.json) {
    writeSync(1, JSON.stringify(summary) + "\n");
  } else {
    log(`\n${JSON.stringify(summary, null, 2)}`);
  }

  /* werift pools its UDP sockets, so a closed peer connection does not release
   * them and the event loop never drains. Without this the process hangs after
   * the last viewer, which reads as a stress run that never finished. */
  process.exit(0 === state.failed && 0 === state.silent ? 0 : 1);
}

main().catch((err) => {
  writeSync(2, `[FAIL] ${err.message}\n`);
  process.exit(1);
});
