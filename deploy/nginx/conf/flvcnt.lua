-- conf/flvcnt.lua - GET /rtc/v1/flvcnt
-- Concurrent HTTP-FLV viewers per stream (cross-worker aggregate). The access
-- hook in conf/flv_auth.lua increments "flvcnt:<app>/<stream>" when a viewer
-- authorizes and conf/flv_close.lua decrements it at request end, both in the
-- shared rtc_stats dict, so every worker contributes to the same counter.
--
-- The stock ngx_rtmp_stat /stat is worker-local (an HTTP request only sees the
-- worker that happened to serve it), which is unreliable with worker_processes
-- > 1; this dict-based counter is not.
--
-- Response: {"code":0,"streams":[{"name":"live/livestream","viewers":2}]}
local cjson = require "cjson"
cjson.encode_empty_table_as_object(false)   -- empty streams -> [] not {}

local dict = ngx.shared.rtc_stats
local out = {}
local keys = dict:get_keys(0)   -- whole dict; rtc_stats keeps few keys

if keys then
    for _, k in ipairs(keys) do
        if type(k) == "string" and k:sub(1, 7) == "flvcnt:" then
            local v = dict:get(k)
            if v and v > 0 then
                out[#out + 1] = { name = k:sub(8), viewers = v }
            end
        end
    end
end

ngx.header["Content-Type"] = "application/json; charset=utf-8"
ngx.print(cjson.encode({ code = 0, streams = out }))
