-- POST /admin/streams/disconnect?name=<app/stream>
-- Forwards to the internal C disconnect handler, which marks every viewer of
-- the named source for close; owner workers reap them on the next timer tick.

local cjson = require "cjson"

ngx.header["Content-Type"] = "application/json"

if ngx.req.get_method() ~= "POST" then
    ngx.status = 405
    ngx.say(cjson.encode({ code = 1, msg = "method not allowed" }))
    return
end

local args = ngx.req.get_uri_args()
local name = args.name
if not name or name == "" then
    ngx.status = 400
    ngx.say(cjson.encode({ code = 1, msg = "missing or invalid name" }))
    return
end

-- The name goes through `args` rather than into the URI string: it is raw client
-- input and carries a "/", and interpolating it by hand would let an "&" or "="
-- split the subrequest's arguments. ngx.location.capture encodes a table with
-- ngx.encode_args, the same form admin_kick.lua uses for its id.
local res = ngx.location.capture("/internal/rtc/disconnect", {
    method = ngx.HTTP_POST,
    args = { name = name },
})

if not res then
    ngx.status = 500
    ngx.say(cjson.encode({ code = 1, msg = "disconnect subrequest failed" }))
    return
end

if res.status == 200 then
    ngx.say(cjson.encode({ code = 0, msg = "disconnect requested", name = name }))
elseif res.status == 404 then
    ngx.status = 404
    ngx.say(cjson.encode({ code = 1, msg = "stream not found", name = name }))
else
    ngx.status = res.status
    ngx.say(cjson.encode({ code = 1, msg = "disconnect failed", status = res.status }))
end
