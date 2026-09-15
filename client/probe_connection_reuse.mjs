// probe_connection_reuse.mjs - several viewers from one client port.
//
// nginx keys its stream UDP connection on the peer address, not on the RTC
// session. A client that reconnects from the same local port therefore lands on
// the connection object the module bound to the previous session, and the module
// keeps one RTC session per *ufrag* rather than per connection. Three connects
// from one port produce three sessions sharing a single connection -- which the
// module's teardown does not expect:
//
//   ngx_rtc_stream_session_close() clears the stream session's ctx and posts the
//   nginx-side finalize unconditionally, so when the *first* of those sessions
//   hits its idle timeout it destroys the connection the other two are still
//   streaming into. Their sends fail with
//
//     sendto() failed (9: Bad file descriptor), udp client: ...
//
//   and each of them is left holding a freed connection, so the next reap
//   dereferences it:
//
//     #0 ngx_rtc_stream_session_close  ngx_rtc_stream_module.c:1322
//        ngx_stream_set_ctx(s, NULL, ngx_rtc_stream_module);   s <dangling>
//     #1 ngx_rtc_stream_reap_timer
//     #2 ngx_event_expire_timers
//
// The probe drives the scenario and reads the verdict out of the server log: a
// clean run opens exactly one connection for all three connects and logs neither
// a bad-fd send nor a crash.
//
// usage: node probe_connection_reuse.mjs --log <nginx error.log> [--port 41234]
//                                       [--connects 3] [--wait 50000]

import { readFileSync, statSync, writeSync } from "node:fs";
import { RTCPeerConnection, useH264, useOPUS } from "werift";

import { DEMO_KEY, signToken, streamPathOf } from "./lib/token.mjs";

const API = process.env.RTC_API || "http://127.0.0.1:18082";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function parseArgs(argv) {
  const opts = {
    stream: "webrtc://127.0.0.1:18082/live/livestream",
    key: DEMO_KEY,
    api: API,
    port: 41234,
    connects: 3,
    wait: 50000,
    hold: 2000,
    log: "",
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--stream") opts.stream = argv[++i];
    else if (arg === "--key") opts.key = argv[++i];
    else if (arg === "--api") opts.api = argv[++i];
    else if (arg === "--port") opts.port = Number.parseInt(argv[++i], 10);
    else if (arg === "--connects") opts.connects = Number.parseInt(argv[++i], 10);
    else if (arg === "--wait") opts.wait = Number.parseInt(argv[++i], 10);
    else if (arg === "--hold") opts.hold = Number.parseInt(argv[++i], 10);
    else if (arg === "--log") opts.log = argv[++i];
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!opts.log) {
    throw new Error("--log <nginx error.log> is required: the symptoms are server-side");
  }
  return opts;
}

function log(msg) {
  writeSync(2, msg + "\n");
}

function logSize(path) {
  try {
    return statSync(path).size;
  } catch {
    return 0;
  }
}

function logSince(path, from) {
  try {
    return readFileSync(path).subarray(from).toString("utf8");
  } catch {
    return "";
  }
}

/* One viewer: connect, receive for `holdMs`, close. The pinned two-port range
 * (werift rejects min == max) is what makes the next viewer land on the same
 * peer address, and thus on the same nginx connection. */
async function viewer(target, opts, label, holdMs) {
  const pc = new RTCPeerConnection({
    codecs: { audio: [useOPUS()], video: [useH264()] },
    icePortRange: [opts.port, opts.port + 1],
  });

  let pkts = 0;
  pc.onTrack.subscribe((track) =>
    track.onReceiveRtp.subscribe(() => {
      pkts++;
    })
  );

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
    throw new Error(`${label}: signaling rejected code=${data.code}`);
  }
  await pc.setRemoteDescription({ type: "answer", sdp: data.sdp });

  await sleep(holdMs);
  log(`[${label}] received ${pkts} packets, closing (no goodbye: a closed tab)`);
  await pc.close();
  return pkts;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const target = {
    stream: opts.stream,
    key: opts.key,
    label: streamPathOf(opts.stream),
  };
  const mark = logSize(opts.log);

  log(`pinned local port range ${opts.port}-${opts.port + 1}, ${opts.connects} viewers`);

  for (let i = 0; i < opts.connects; i++) {
    const pkts = await viewer(target, opts, `#${i}`, opts.hold);
    if (0 === pkts) {
      log(`[#${i}] received no media: is anything publishing?`);
      process.exit(2);
    }
  }

  /* Every session's idle timeout is rtc_ready_timeout (30 s) measured from its
   * last inbound datagram, so the reaps land a few seconds apart once the
   * viewers have gone quiet. */
  log(`waiting ${Math.round(opts.wait / 1000)} s for the idle reaps`);
  await sleep(opts.wait);

  const text = logSince(opts.log, mark);
  const lines = text.split("\n");
  const connections = lines.filter((l) => l.includes("connected to 0.0.0.0:18000"));
  const bad = lines.filter((l) => l.includes("Bad file descriptor"));
  const crashes = lines.filter((l) => l.includes("got signal 11") || l.includes("exited with code 139"));
  const reaps = lines.filter((l) => l.includes("idle timeout, closing session"));

  log(`\n=== server log over the window ===`);
  log(`connections opened:        ${connections.length}`);
  log(`idle reaps:                ${reaps.length}`);
  log(`bad-fd sends:              ${bad.length}`);
  log(`crashes:                   ${crashes.length}`);
  if (bad.length > 0) {
    log(`first bad-fd: ${bad[0].slice(0, 150)}`);
  }
  if (crashes.length > 0) {
    log(`first crash: ${crashes[0].slice(0, 150)}`);
  }

  if (connections.length > 1) {
    log(
      `\n[SKIP] the viewers did not share a connection (${connections.length} opened), ` +
        `so the case under test was not exercised`
    );
    process.exit(3);
  }

  const failed = bad.length > 0 || crashes.length > 0;
  log(
    failed
      ? "\n[FAIL] a session's teardown took the connection out from under the others"
      : "\n[PASS] one connection served every viewer, and each teardown was its own"
  );
  process.exit(failed ? 1 : 0);
}

main().catch((err) => {
  writeSync(2, `[FAIL] ${err.message}\n`);
  process.exit(1);
});
