-- conf/flv_close.lua - log-phase hook for /live: decrement the concurrent
-- HTTP-FLV viewer count that conf/flv_auth.lua bumped in the access phase.
-- Runs exactly once per request when the FLV body ends (viewer disconnect or
-- error), so the shared-dict counter tracks live viewers across all workers.
local app = ngx.var.arg_app
local stream = ngx.var.arg_stream

if app and stream then
    local dict = ngx.shared.rtc_stats
    local key = "flvcnt:" .. app .. "/" .. stream
    local cur = dict:get(key)
    if cur and cur > 0 then
        dict:incr(key, -1)   -- shared-dict API: no decr(), incr() accepts negatives
    end
end
