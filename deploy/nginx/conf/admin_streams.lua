-- GET /admin/streams -> list live streams and viewer counts.
-- Read-only; the raw media stats come from the C mirror in rtc_stats.

local cjson = require "cjson"

ngx.header["Content-Type"] = "application/json"

local raw = ngx.shared.rtc_stats:get("stats")
if not raw then
    ngx.say(cjson.encode({ code = 0, streams = {}, totals = { streams = 0, clients = 0 } }))
    return
end

local ok, d = pcall(cjson.decode, raw)
if not ok or "table" ~= type(d) then
    ngx.say(cjson.encode({ code = 1, msg = "invalid stats snapshot" }))
    return
end

ngx.say(cjson.encode({
    code = 0,
    streams = d.streams or {},
    totals = {
        streams = d.total_streams or 0,
        clients = d.total_clients or 0,
        video_octets = d.total_video_octets or 0,
        audio_octets = d.total_audio_octets or 0,
    },
}))
