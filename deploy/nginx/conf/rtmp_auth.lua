-- RTMP notify authorization, shared by on_publish and on_play.
--
-- The notify module POSTs urlencoded fields; the stream query string (e.g.
-- "?t=..&sign=..") is appended verbatim as top-level form fields, so the token
-- arrives as the "t" and "sign" fields. A 2xx response accepts the operation.
--
-- One file for both hooks because they differ only in which secret the token
-- must verify against: publishing uses the server-only publish secret, playing
-- uses the play secret that the player pages also carry. The purpose is read
-- from the URI rather than passed as a query arg, because nginx-rtmp builds the
-- notify request itself and the only part of it this config controls is the
-- path.
local ngx = ngx
local config = require "config"

-- string.find with plain=true, not :match: the needle is a literal with no
-- pattern metacharacters, so plain search skips pattern compilation on a hook
-- that runs once per publish and once per play.
local purpose = string.find(ngx.var.uri, "on_publish", 1, true) and "publish"
                or "play"

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

if not config.verify(app .. "/" .. name, t, sign, purpose) then
    ngx.log(ngx.WARN, "rtmp_auth: deny ", purpose, " ", app, "/", name,
            " t=", tostring(t), " sign=", tostring(sign))
    return ngx.exit(403)
end

ngx.exit(200)
