-- Public /rtc/v1/stats (loopback-only). Control plane lives in Lua: rate limit +
-- rendering. The raw media stats are mirrored by the C module into the
-- `rtc_stats` lua_shared_dict every second, so each request reads shared memory
-- directly and never fires an internal subrequest.

local dict = ngx.shared.rtc_stats

local limit_req = require "resty.limit.req"

local lim, err = limit_req.new("rate_limit", 1, 3)
if not lim then
    ngx.log(ngx.ERR, "stats: limit_req init failed: ", err)
    return ngx.exit(500)
end

local delay, err = lim:incoming(ngx.var.binary_remote_addr, true)
if not delay then
    if err == "rejected" then
        return ngx.exit(429)
    end
    ngx.log(ngx.ERR, "stats: limit_req failed: ", err)
    return ngx.exit(500)
end
if delay >= 0.001 then
    return ngx.exit(429)
end

local body = dict:get("stats")
if not body then
    ngx.log(ngx.ERR, "stats: mirror not ready")
    return ngx.exit(503)
end

ngx.header["Content-Type"] = "application/json"
ngx.print(body)
