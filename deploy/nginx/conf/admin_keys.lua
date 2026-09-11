-- Runtime admin API for stream keys (pure Lua).
-- GET  /admin/keys -> list "<app>/<stream>|<purpose>" entries
-- POST /admin/keys -> {"action":"add","appstream":"live/x","purpose":"publish","key":"k"}
--                     {"action":"del","appstream":"live/x","purpose":"publish"}
--
-- purpose is required from here on: keys are stored per (stream, purpose) so a
-- play secret cannot authorize ingest (see stream_keys.lua). Defaulting it
-- would silently write a publish credential over the play one, or the reverse,
-- which is exactly the confusion the split exists to remove.
--
-- Note this API is not durable: config.reload() rewrites the dict from
-- stream_keys.lua every 10s and deletes anything the file does not list.
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

if "string" ~= type(req.purpose) then
    ngx.say(cjson.encode({ code = 1, msg = "purpose must be play or publish" }))
    return
end

if "add" == req.action and "string" == type(req.appstream) and "string" == type(req.key) then
    local _, err = config.set(req.appstream, req.purpose, req.key)
    if err then
        ngx.say(cjson.encode({ code = 1, msg = err }))
        return
    end
    ngx.say(cjson.encode({ code = 0 }))
    return
end

if "del" == req.action and "string" == type(req.appstream) then
    local _, err = config.del(req.appstream, req.purpose)
    if err then
        ngx.say(cjson.encode({ code = 1, msg = err }))
        return
    end
    ngx.say(cjson.encode({ code = 0 }))
    return
end

ngx.say(cjson.encode({ code = 1, msg = "unknown action" }))
