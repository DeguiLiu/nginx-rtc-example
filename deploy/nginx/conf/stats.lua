-- Public /rtc/v1/stats (loopback-only). Control plane lives in Lua: rate limit +
-- rendering. The raw media stats are mirrored by the C module into the
-- `rtc_stats` lua_shared_dict every second, so each request reads shared memory
-- directly and never fires an internal subrequest.

local ngx = ngx
local cjson = require "cjson"
local client_latency = require "client_latency"

local dict = ngx.shared.rtc_stats

local limit_req = require "resty.limit.req"

-- Distinct key from the /rtc/v1/play/ limiter (auth.lua): the two share the
-- `rate_limit` dict, so an unprefixed IP key made both limiters drive one
-- leaky-bucket counter and corrupt each other's accounting. 5 req/s + burst 10
-- covers a few player pages polling /rtc/v1/stats every 2 s.
local lim, err = limit_req.new("rate_limit", 5, 10)
if not lim then
    ngx.log(ngx.ERR, "stats: limit_req init failed: ", err)
    return ngx.exit(500)
end

local delay, err = lim:incoming("stats:" .. ngx.var.binary_remote_addr, true)
if not delay then
    if err == "rejected" then
        ngx.status = 429
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"code":429,"message":"rate limited: stats polled too fast"}')
        return ngx.exit(429)
    end
    ngx.log(ngx.ERR, "stats: limit_req failed: ", err)
    return ngx.exit(500)
end
-- delay > 0 = draining the burst: serve anyway (same policy as auth.lua).

local body = dict:get("stats")
if not body then
    ngx.log(ngx.ERR, "stats: mirror not ready")
    return ngx.exit(503)
end

ngx.header["Content-Type"] = "application/json"

-- Join the viewer-reported end-to-end latency onto each session. The C mirror
-- cannot carry it: the number is produced inside the viewer's browser, and the
-- C side never sees it. Both sides key on the ICE ufrag, which is what makes
-- this a join rather than a second, unrelated list.
--
-- The mirror is passed through untouched if it cannot be re-encoded. This
-- endpoint is what every player page polls for its anchor, so a decode failure
-- here must degrade to "no client latency" and never to "no stats".
local ok, d = pcall(cjson.decode, body)
if not ok or "table" ~= type(d) then
    ngx.print(body)
    return
end

for _, s in ipairs(d.streams or {}) do
    for _, x in ipairs(s.sessions or {}) do
        local rep = client_latency.get(x.ufrag)
        if rep then
            x.client = {
                e2e_ms = rep.e2e_ms,
                e2e_min = rep.e2e_min,
                frames = rep.frames,
                jb_ms = rep.jb_ms,
                decode_ms = rep.decode_ms,
                rtt_ms = rep.rtt_ms,
                age_s = (rep.ts and (ngx.time() - rep.ts)) or nil,
            }
        end
    end
end

local encoded = cjson.encode(d)
-- encode() returns nil on failure (and on a value it cannot represent), which
-- would otherwise be printed as an empty body.
if "string" ~= type(encoded) then
    ngx.print(body)
    return
end
ngx.print(encoded)
