-- Runtime admin API for stream keys (pure Lua).
-- GET  /admin/keys -> list app/stream entries
-- POST /admin/keys -> {"action":"add","appstream":"live/x","key":"k"} / {"action":"del","appstream":"live/x"}
local cjson = require "cjson"
local config = require "config"

ngx.header["Content-Type"] = "application/json"

if "GET" == ngx.req.get_method() then
    ngx.say(cjson.encode({ code = 0, keys = config.list() or {} }))
    return
end

ngx.req.read_body()
local ok, req = pcall(cjson.decode, ngx.req.get_body_data() or "{}")
if not ok or "table" ~= type(req) then
    ngx.say(cjson.encode({ code = 1, msg = "invalid body" }))
    return
end

if "add" == req.action and "string" == type(req.appstream) and "string" == type(req.key) then
    config.set(req.appstream, req.key)
    ngx.say(cjson.encode({ code = 0 }))
    return
end

if "del" == req.action and "string" == type(req.appstream) then
    config.del(req.appstream)
    ngx.say(cjson.encode({ code = 0 }))
    return
end

ngx.say(cjson.encode({ code = 1, msg = "unknown action" }))
