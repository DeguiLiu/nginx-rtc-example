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

    -- Publish the new keys first, then drop the ones that disappeared.
    -- flush_all() before the set() loop would open a window in which a worker
    -- serving a request sees an empty dict and denies a stream whose key is
    -- about to be written back -- a reload that flaps live playback for no
    -- reason. This order has no such window: every key is valid at all times,
    -- and a key removed from stream_keys.lua stops being valid once the loop
    -- finishes.
    local stale = shared:get_keys(0)
    local fresh = {}

    for k, v in pairs(cfg) do
        shared:set(k, tostring(v))
        fresh[k] = true
    end

    for _, k in ipairs(stale) do
        if not fresh[k] then
            shared:delete(k)
        end
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
