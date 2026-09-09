-- Dynamic stream-key config module (pure Lua, runs on LuaJIT).
-- Loads stream_keys.lua into lua_shared_dict, hot-reloaded by timer.
local _M = {}
local CONFIG_MODULE = "stream_keys"

local shared = ngx.shared.stream_keys
local hmac = require "hmac"

function _M.reload()
    package.loaded[CONFIG_MODULE] = nil
    local ok, cfg = pcall(require, CONFIG_MODULE)
    if not ok or "table" ~= type(cfg) then
        return false
    end

    shared:flush_all()
    for k, v in pairs(cfg) do
        shared:set(k, tostring(v))
    end
    return true
end

-- HMAC token 校验: secret 存 shared dict, t=过期 unix 秒, sign=base64url(HMAC-SHA256).
function _M.verify(appstream, t, sign)
    local secret = shared:get(appstream)
    if not secret or "string" ~= type(secret) then
        return false
    end
    local exp = tonumber(t)
    if not exp then
        return false
    end
    -- 60s 时钟倾斜余量; 过期统一拒绝(不区分过期/伪造)
    if ngx.time() > exp + 60 then
        return false
    end
    return hmac.verify(secret, appstream .. "|t=" .. t, sign)
end

function _M.list()
    return shared:get_keys(0)
end

function _M.set(appstream, key)
    return shared:set(appstream, key)
end

function _M.del(appstream)
    return shared:delete(appstream)
end

return _M
