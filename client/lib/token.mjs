// token.mjs - the HMAC token, in one place.
//
// Four sides of this stack must produce a byte-identical signature over
// "<app>/<stream>|t=<expiry>": the RTMP publish URL (run.sh sign_for), the
// HTTP-FLV query string (deploy/nginx/conf/flv_auth.lua), the signaling body
// (deploy/nginx/conf/config.lua) and these clients. Getting the message wrong
// on any one of them is a hard 403 with nothing in the log explaining why, so
// the algorithm lives here instead of being copied into every tool that needs
// it -- it was previously written out three times under client/.
//
// The default secret stays (DEMO_KEY), it is not removed: ./run.sh push and
// client/play.mjs must work with no external injection. See the open decision
// recorded in docs/deploy-coding-standards.md.

import { createHmac } from "node:crypto";

/* The demo secret from deploy/nginx/conf/stream_keys.lua. Every live/* stream
 * in the demo uses it, which is why one --key can cover a whole ladder. */
export const DEMO_KEY = "demo-secret-0123456789abcdef0123456789abcdef";

/* signToken(key, "live/livestream") -> { t: 1789107930, sign: "<base64url>" }.
 * t is a number: callers that put it in a query string or a JSON body do their
 * own String(t), because the two transports are not interchangeable (the RTMP
 * URL takes "t=..&sign=..", the signaling body takes them as separate fields). */
export function signToken(key, streamPath, ttlSec = 3600) {
  const t = Math.floor(Date.now() / 1000) + ttlSec;
  const sign = createHmac("sha256", key)
    .update(`${streamPath}|t=${t}`)
    .digest("base64url");
  return { t, sign };
}

/* "webrtc://host:port/live/name" and "rtc://host/live/name" -> "live/name".
 * The signaling body carries the full URL but the token is signed over the
 * path only, so the host has to be dropped -- and the drop has to match what
 * each tool did before this module existed, or old tokens stop verifying. */
export function streamPathOf(url, fallback = "live/livestream") {
  const m = String(url).match(/^(?:webrtc|rtc):\/\/[^/]+\/([^/]+)\/([^/]+)$/);
  return m ? `${m[1]}/${m[2]}` : fallback;
}
