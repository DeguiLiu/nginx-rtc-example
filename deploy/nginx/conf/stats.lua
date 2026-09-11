-- Public /rtc/v1/stats (loopback-only). Control plane lives in Lua: rate limit +
-- rendering. The raw media stats are mirrored by the C module into the
-- `rtc_stats` lua_shared_dict every second, so each request reads shared memory
-- directly and never fires an internal subrequest.

local ngx = ngx

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
ngx.print(body)
