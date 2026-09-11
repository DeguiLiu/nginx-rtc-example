#!/usr/bin/env node
/*
 * probe_stuck_session.mjs - drive one session to DTLS_HANDSHAKE and stop there.
 *
 * A lifecycle state in /rtc/v1/stats is only worth having if a viewer wedged
 * before SRTP_READY can be told apart from one that never arrived at all, and
 * the only way to see that state is to make a session actually get stuck in it.
 * This is the producer for that case: it does the HTTP signaling, then speaks
 * to UDP 8000 by hand -- one valid STUN binding (NEW -> ICE_BOUND) followed by
 * one well-formed-looking DTLS record (ICE_BOUND -> DTLS_HANDSHAKE) -- and then
 * goes quiet. The server's DTLS handshake never completes, so the session sits
 * in DTLS_HANDSHAKE until the handshake timeout reaps it.
 *
 * werift is used only to build an offer the SDP parser accepts.
 * setRemoteDescription() is deliberately never called, so the peer connection
 * never runs ICE or DTLS and the datagrams below are the only ones the server
 * ever sees from this address.
 *
 * Two details are load-bearing:
 *
 *   - STUN and the DTLS record must leave from the SAME socket. The module keys
 *     the session off the nginx stream (UDP) session context, which is per
 *     4-tuple; a second socket would arrive at ngx_rtc_stream_on_dtls() with no
 *     session and be dropped.
 *
 *   - MESSAGE-INTEGRITY is mandatory -- ngx_rtc_stun_verify_request() rejects a
 *     request without it -- and it is keyed by the SERVER's ice-pwd, taken from
 *     the SDP answer. FINGERPRINT is not enforced (the C side says so
 *     explicitly), so it is not computed here.
 *
 * Exit status is 0 only when /rtc/v1/stats reports the probe's own ufrag in
 * DTLS_HANDSHAKE, so this doubles as the regression check for that state.
 */

import { RTCPeerConnection, useH264, useOPUS } from "werift";
/* createHmac stays imported for the STUN MESSAGE-INTEGRITY below, which is
 * HMAC-SHA1 over the datagram and has nothing to do with the playback token. */
import { createHmac, randomBytes } from "node:crypto";
import dgram from "node:dgram";
import process from "node:process";

import { DEMO_KEY, signToken, streamPathOf } from "./lib/token.mjs";

const DEFAULT_STREAM = "webrtc://127.0.0.1:18082/live/livestream";
const DEFAULT_KEY = DEMO_KEY;
const DEFAULT_API = "http://127.0.0.1:18082";
const DEFAULT_UDP = "127.0.0.1:8000";

/* How long to let the server digest the two datagrams and publish the state
 * through its 1 s stats mirror before asking. */
const SETTLE_MS = 2500;

function usage() {
  console.log(`probe_stuck_session.mjs - leave a session in DTLS_HANDSHAKE

  --stream <url>    stream URL (default ${DEFAULT_STREAM})
  --key <key>       stream key
  --api <url>       signaling API base URL (default ${DEFAULT_API})
  --udp <host:port> the module's UDP listener (default ${DEFAULT_UDP})
  --quiet           only print the final verdict`);
}

function parseArgs(argv) {
  const opts = {
    stream: DEFAULT_STREAM,
    key: DEFAULT_KEY,
    api: DEFAULT_API,
    udp: DEFAULT_UDP,
    quiet: false,
  };

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    /* Guarded: `argv[++i]` alone yields undefined when the flag is last, which
     * then reaches HMAC as the string "undefined" and fails as a 403 with no
     * hint that the argument was simply missing. */
    const take = () => {
      if (i + 1 >= argv.length) {
        throw new Error(`missing value for ${a}`);
      }
      return argv[++i];
    };
    switch (a) {
      case "--stream": opts.stream = take(); break;
      case "--key": opts.key = take(); break;
      case "--api": opts.api = take(); break;
      case "--udp": opts.udp = take(); break;
      case "--quiet": opts.quiet = true; break;
      case "-h":
      case "--help": usage(); process.exit(0); break;
      default:
        console.error(`unknown argument: ${a}`);
        usage();
        process.exit(2);
    }
  }

  return opts;
}

/*
 * A STUN Binding Request carrying USERNAME and MESSAGE-INTEGRITY.
 *
 * The length field, the HMAC input and the final wire length all end up being
 * the same number here: the offset at which the 20-byte HMAC value starts, which
 * is also the total attribute length (RFC 5389 15.4 sets the header length to
 * cover up to the end of MESSAGE-INTEGRITY, and the attribute is the last one).
 */
function buildStunBinding(serverUfrag, clientUfrag, pwd) {
  const MAGIC_COOKIE = 0x2112a442;
  const ATTR_USERNAME = 0x0006;
  const ATTR_MI = 0x0008;

  const username = Buffer.from(`${serverUfrag}:${clientUfrag}`, "utf8");
  const padded = Math.ceil(username.length / 4) * 4;
  const attr = Buffer.alloc(4 + padded);
  attr.writeUInt16BE(ATTR_USERNAME, 0);
  attr.writeUInt16BE(username.length, 2);
  username.copy(attr, 4);

  const miValueOffset = 20 + attr.length + 4;
  const msg = Buffer.alloc(miValueOffset + 20);

  msg.writeUInt16BE(0x0001, 0);           /* Binding Request */
  msg.writeUInt16BE(miValueOffset, 2);    /* length: attributes up to MI value */
  msg.writeUInt32BE(MAGIC_COOKIE, 4);
  randomBytes(12).copy(msg, 8);           /* transaction id */
  attr.copy(msg, 20);

  msg.writeUInt16BE(ATTR_MI, 20 + attr.length);
  msg.writeUInt16BE(20, 20 + attr.length + 2);

  /* HMAC-SHA1 over everything preceding the MI value, keyed by the server's
   * password -- ngx_rtc_stun_verify_request() recomputes exactly this. */
  createHmac("sha1", pwd)
    .update(msg.subarray(0, miValueOffset - 4))
    .digest()
    .copy(msg, miValueOffset);

  return msg;
}

/* First 0x16 of a DTLS 1.2 handshake record is all the UDP dispatch looks at
 * (content type 20..63) and all the FSM guard checks (>= 13 bytes, type range).
 * The body is never parsed: ngx_rtc_dtls_create() builds the context and only
 * then starts feeding it. */
function fakeDtlsRecord(len = 32) {
  const rec = Buffer.alloc(len);
  rec[0] = 0x16;   /* handshake  */
  rec[1] = 0xfe;   /* DTLS 1.2   */
  rec[2] = 0xfd;
  return rec;
}

function sdpAttr(sdp, name) {
  const m = sdp.match(new RegExp(`^a=${name}:(.+)$`, "m"));
  return m ? m[1].trim() : null;
}

function send(sock, buf, host, port) {
  return new Promise((resolve, reject) => {
    sock.send(buf, port, host, (err) => (err ? reject(err) : resolve()));
  });
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const log = (...a) => { if (!opts.quiet) console.log(...a); };

  const streamPath = streamPathOf(opts.stream);

  /* --- 1. signaling: get a session created and learn the server's ICE creds --- */

  const pc = new RTCPeerConnection({
    codecs: { audio: [useOPUS()], video: [useH264()] },
  });
  pc.addTransceiver("video", { direction: "recvonly" });
  pc.addTransceiver("audio", { direction: "recvonly" });

  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);

  const { t, sign } = signToken(opts.key, streamPath);

  const res = await fetch(`${opts.api}/rtc/v1/play/`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      sdp: offer.sdp,
      streamurl: opts.stream,
      api: opts.api,
      clientip: "127.0.0.1",
      t: String(t),
      sign,
    }),
    signal: AbortSignal.timeout(8000),
  });
  const answer = await res.json();
  if (answer.code !== 0 || !answer.sdp) {
    console.error(`signaling rejected: code=${answer.code}`);
    process.exit(1);
  }
  await pc.close();

  const serverUfrag = sdpAttr(answer.sdp, "ice-ufrag");
  const serverPwd = sdpAttr(answer.sdp, "ice-pwd");
  if (!serverUfrag || !serverPwd) {
    console.error("answer carried no ice-ufrag/ice-pwd; cannot key the STUN binding");
    process.exit(1);
  }
  log(`[signal] session created, server ufrag=${serverUfrag}`);

  /* --- 2. UDP by hand: STUN then one DTLS record, then silence ------------- */

  const [udpHost, udpPortStr] = opts.udp.split(":");
  const udpPort = Number(udpPortStr);
  const sock = dgram.createSocket("udp4");

  await new Promise((resolve, reject) => {
    sock.once("error", reject);
    sock.bind(0, "0.0.0.0", resolve);
  });
  log(`[udp] probe socket ${sock.address().address}:${sock.address().port}`);

  await send(sock, buildStunBinding(serverUfrag, "probe0000", serverPwd),
             udpHost, udpPort);
  log("[udp] STUN binding sent  -> expect ICE_BOUND");

  await send(sock, fakeDtlsRecord(), udpHost, udpPort);
  log("[udp] DTLS record sent   -> expect DTLS_HANDSHAKE, then never finishing");

  /* --- 3. ask the server what it thinks ----------------------------------- */

  await new Promise((r) => setTimeout(r, SETTLE_MS));

  const statsRes = await fetch(`${opts.api}/rtc/v1/stats`, {
    signal: AbortSignal.timeout(5000),
  });
  const stats = await statsRes.json();

  let found = null;
  for (const s of stats.streams || []) {
    for (const x of s.sessions || []) {
      if (x.ufrag === serverUfrag) {
        found = { stream: s.name, ...x };
      }
    }
  }
  sock.close();

  if (!found) {
    console.error(`FAIL: ufrag ${serverUfrag} is not listed in /rtc/v1/stats`);
    console.error(`      session_states: ${JSON.stringify(stats.session_states)}`);
    process.exit(1);
  }

  const ok = found.state === "DTLS_HANDSHAKE";
  console.log(
    `${ok ? "PASS" : "FAIL"}: session #${found.id} on ${found.stream} reports ` +
    `state=${found.state} (wanted DTLS_HANDSHAKE)`
  );
  console.log(`      session_states: ${JSON.stringify(stats.session_states)}`);

  process.exit(ok ? 0 : 1);
}

main().catch((err) => {
  console.error(`probe failed: ${err.message}`);
  process.exit(1);
});
