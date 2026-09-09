-- RTMP publish authorization, invoked by the RTMP on_publish notify callback.
-- The notify module POSTs urlencoded fields; the stream query string (e.g.
-- "key=demo-key-123") is appended verbatim as top-level form fields, so the
-- key arrives as the "key" field. A 2xx response accepts the publish.
local config = require "config"

ngx.req.read_body()
local args, err = ngx.req.get_post_args()
if not args then
    ngx.log(ngx.ERR, "rtmp_auth: bad post args: ", err)
    return ngx.exit(400)
end

local app = args.app
local name = args.name
local t = args.t
local sign = args.sign
if "table" == type(app) then app = app[1] end
if "table" == type(name) then name = name[1] end
if "table" == type(t) then t = t[1] end
if "table" == type(sign) then sign = sign[1] end

if ("string" ~= type(app)) or ("string" ~= type(name)) then
    ngx.log(ngx.WARN, "rtmp_auth: missing app/name")
    return ngx.exit(400)
end

if not config.verify(app .. "/" .. name, t, sign) then
    ngx.log(ngx.WARN, "rtmp_auth: deny publish ", app, "/", name,
            " t=", tostring(t), " sign=", tostring(sign))
    return ngx.exit(403)
end

ngx.exit(200)
