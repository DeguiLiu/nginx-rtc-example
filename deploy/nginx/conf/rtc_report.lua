-- conf/rtc_report.lua - the /rtc/v1/report endpoint (content_by_lua_file).
--
-- Thin request layer over conf/client_latency.lua. It exists as its own file so
-- that the storage module stays safe to require() from other content-phase
-- handlers -- see the header comment there for the failure that forces this.
--
--   POST /rtc/v1/report   the player page's sample
--   GET  /rtc/v1/report   what is currently held (private networks only):
--                         every live entry, including one whose session has
--                         already gone, because that mismatch is worth seeing.
--
-- Nothing expires here; entries carry a 20s TTL set at write time, so a tab
-- that closed stops being counted without anything having to reap it.

local cjson = require "cjson"
local limit_req = require "resty.limit.req"
local client_latency = require "client_latency"

local function send(code, tbl)
    ngx.status = code
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode(tbl))
end

local function is_private(addr)
    if not addr then
        return false
    end
    return nil ~= addr:match("^127%.")
        or nil ~= addr:match("^10%.")
        or nil ~= addr:match("^192%.168%.")
        or nil ~= addr:match("^172%.1[6-9]%.")
        or nil ~= addr:match("^172%.2%d%.")
        or nil ~= addr:match("^172%.3[01]%.")
        or "::1" == addr
end

local function do_post()
    if not client_latency.ready() then
        -- Reached on an instance whose nginx.conf predates the dict
        -- declaration. Nothing to store into; say so rather than fail on a nil
        -- index, which would look like a defect in the page.
        return send(503, { code = 503,
                          message = client_latency.DICT_NAME .. " not declared in nginx.conf" })
    end

    ngx.req.read_body()
    -- client_body_buffer_size is 128k in nginx.conf, so a report never spills
    -- to a temp file and this never returns nil for a well-behaved client. A
    -- larger body is refused by nginx itself before we run.
    local data = ngx.req.get_body_data()
    if not data then
        return send(400, { code = 400, message = "empty body" })
    end
    if #data > 4096 then
        return send(400, { code = 400, message = "body too large" })
    end

    local ok, raw = pcall(cjson.decode, data)
    if not ok then
        return send(400, { code = 400, message = "body is not valid JSON" })
    end

    local rep, err = client_latency.validate(raw)
    if not rep then
        return send(400, { code = 400, message = err })
    end

    local stored
    stored, err = client_latency.store(rep)
    if not stored then
        ngx.log(ngx.ERR, "rtc_report: store failed: ", err)
        return send(500, { code = 500, message = "store failed" })
    end
    send(200, { code = 0 })
end

local function do_get()
    if not is_private(ngx.var.remote_addr) then
        return send(403, { code = 403, message = "report readout is private" })
    end
    local reports = client_latency.dump()
    send(200, { code = 0, count = #reports, reports = reports })
end

local function serve()
    local method = ngx.req.get_method()
    if "POST" == method then
        -- One report per 5s per tab; 2 r/s with a burst of 5 leaves room for a
        -- reload or two without ever letting a script hammer the dict. The key
        -- is prefixed because rate_limit is shared with the play and stats
        -- limiters -- an unprefixed IP key would make them all drive one
        -- counter and corrupt each other's accounting (the bug stats.lua has a
        -- comment about).
        local lim, lerr = limit_req.new("rate_limit", 2, 5)
        if not lim then
            ngx.log(ngx.ERR, "rtc_report: limit_req init failed: ", lerr)
            return send(500, { code = 500, message = "limiter unavailable" })
        end
        -- incoming() returns (delay_seconds, excess_seconds) when it admits the
        -- request and (nil, "rejected") when it does not. The second value on
        -- the admitting path is a number, and 0 is truthy in Lua -- testing it
        -- for truth would reject every request that is not over the limit. The
        -- first value is the one to branch on, exactly as stats.lua does.
        local delay, rerr = lim:incoming("report:" .. ngx.var.binary_remote_addr, true)
        if not delay then
            if "rejected" == rerr then
                return send(429, { code = 429, message = "rate limited: latency reported too often" })
            end
            ngx.log(ngx.ERR, "rtc_report: limit_req failed: ", rerr)
            return send(500, { code = 500, message = "limiter failed" })
        end
        return do_post()
    end
    if "GET" == method then
        return do_get()
    end
    send(405, { code = 405, message = "use GET or POST" })
end

serve()
