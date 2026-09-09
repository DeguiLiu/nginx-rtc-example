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

if not config.verify(app .. "/" .. stream, t, sign) then
    return ngx.exit(403)
end

-- Authorized viewer: bump this stream's concurrent HTTP-FLV count in the shared
-- dict. The matching decrement happens in conf/flv_close.lua (log phase) when
-- the FLV body request ends, so /rtc/v1/flvcnt sees a cross-worker-accurate
-- "viewers right now" per stream. init_ttl 300s self-heals any viewer whose log
-- phase never ran (abrupt worker death), capping phantom counts.
ngx.shared.rtc_stats:incr("flvcnt:" .. app .. "/" .. stream, 1, 0, 300)
