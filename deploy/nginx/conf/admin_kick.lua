-- POST /admin/streams/kick?id=<session_id>
-- Forwards to the internal C kick handler, which flips the shm skeleton's
-- close_requested flag; the owning worker reaps it on the next timer tick.

local cjson = require "cjson"

ngx.header["Content-Type"] = "application/json"

if ngx.req.get_method() ~= "POST" then
    ngx.status = 405
    ngx.say(cjson.encode({ code = 1, msg = "method not allowed" }))
    return
end

local args = ngx.req.get_uri_args()
local id = tonumber(args.id)
if not id or id <= 0 or id % 1 ~= 0 then
    ngx.status = 400
    ngx.say(cjson.encode({ code = 1, msg = "missing or invalid id" }))
    return
end

local res = ngx.location.capture("/internal/rtc/kick", {
    method = ngx.HTTP_POST,
    args = { id = tostring(id) },
})

if not res then
    ngx.status = 500
    ngx.say(cjson.encode({ code = 1, msg = "kick subrequest failed" }))
    return
end

if res.status == 200 then
    ngx.say(cjson.encode({ code = 0, msg = "kick requested", id = id }))
elseif res.status == 404 then
    ngx.status = 404
    ngx.say(cjson.encode({ code = 1, msg = "session not found", id = id }))
else
    ngx.status = res.status
    ngx.say(cjson.encode({ code = 1, msg = "kick failed", status = res.status }))
end
