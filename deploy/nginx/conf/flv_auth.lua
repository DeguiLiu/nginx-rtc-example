-- HTTP-FLV playback authorization, aligned with /rtc/v1/play/.
-- URL: /live?app=live&stream=livestream&t=<exp>&sign=<base64url(HMAC-SHA256)>
local config = require "config"

local app = ngx.var.arg_app
local stream = ngx.var.arg_stream
local t = ngx.var.arg_t
local sign = ngx.var.arg_sign

if not app or not stream then
    return ngx.exit(400)
end

if not config.verify(app .. "/" .. stream, t, sign, "play") then
    return ngx.exit(403)
end

-- How long a viewer's counter slot survives without being touched. For a live
-- stream the only Lua that runs is this access phase and the log phase at the
-- other end, so nothing can refresh the slot while the viewer keeps watching:
-- the TTL is not a session timeout, it exists solely to heal a count left
-- behind when a worker dies mid-stream. It therefore has to outlast a realistic
-- viewing session. At 300 s it was shorter than the streams it was counting --
-- a viewer past five minutes had their slot expire from under them, the stream
-- was reported with fewer viewers than it had, and their close could then
-- subtract a slot a newer viewer had just taken. The residual limit is stated
-- rather than hidden: a session longer than this still undercounts, and a
-- worker that dies still leaves a phantom for up to this long.
local COUNTER_TTL = 3600

-- ngx.ctx is the access -> log handoff ("this request is the one that counted
-- itself"), so the log-phase hook can tell an authorized viewer apart from a
-- request rejected above. Do not drop it: flv_close.lua has no other way to
-- know whether it is allowed to decrement.
local key = "flvcnt:" .. app .. "/" .. stream
local n, err = ngx.shared.rtc_stats:incr(key, 1, 0, COUNTER_TTL)
if not n then
    -- Counting is best-effort; pairing an increment that did not happen with a
    -- decrement that does is not. Without the ctx handoff the log phase stays
    -- out of it, instead of subtracting a slot this request never added.
    ngx.log(ngx.ERR, "flv_auth: flvcnt incr failed: ", err)
else
    ngx.ctx.flvcnt_key = key
end
