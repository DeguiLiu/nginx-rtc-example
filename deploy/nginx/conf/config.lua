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

-- Purpose scoping. play and publish are different secrets (see stream_keys.lua),
-- so a token minted for one role fails verification for the other. A table
-- lookup rather than string concatenation on purpose: an unknown purpose is
-- rejected instead of being interpolated into a key nobody defined.
local SUFFIX = { play = "|play", publish = "|publish" }

-- How far past its stamp a token is still accepted. Absorbs clock error between
-- the signer and this server.
local CLOCK_SKEW = 60

-- Longest lifetime a token may CLAIM. `t` comes from the client and the only
-- other check is that it has not passed, so without an upper bound a holder of a
-- secret can mint a token stamped 2099 and that credential never expires -- a
-- leak becomes permanent. This bounds the window instead of trusting the signer.
--
-- It must stay above the largest ttl any client mints, plus that client's clock
-- error: the clients sign now+3600 (client/lib/token.mjs, rtcplayer.html,
-- run.sh; the e2e scripts use 300-600), and a client whose clock runs fast
-- claims a proportionally longer life. 7200 is 2x the largest client ttl, which
-- absorbs both. Setting this at or below 3600 rejects EVERY client at once --
-- the ladder, the player page and every script -- so a client that raises its
-- ttl must raise this first.
--
-- Note what this does not do: it is checked when a connection is authorized,
-- never during one, so a session already running keeps running past expiry.
-- It also does not stop replay -- there is no nonce, so a captured token can be
-- used repeatedly until it expires.
local MAX_TOKEN_TTL = 7200

-- HMAC token 校验: secret 存 shared dict, t=过期 unix 秒, sign=base64url(HMAC-SHA256).
-- purpose 缺省为 "play" —— 观看是最常见的调用方, 而推流必须显式声明, 免得新
-- 加的 ingest 路径忘记传参就静默拿到观看侧权限。
function _M.verify(appstream, t, sign, purpose)
    local suffix = SUFFIX[purpose or "play"]
    if not suffix then
        return false
    end
    local secret = shared:get(appstream .. suffix)
    if not secret or "string" ~= type(secret) then
        return false
    end
    local exp = tonumber(t)
    if not exp then
        return false
    end
    local now = ngx.time()
    -- 过期统一拒绝(不区分过期/伪造)
    if now > exp + CLOCK_SKEW then
        return false
    end
    if exp - now > MAX_TOKEN_TTL then
        return false
    end
    return hmac.verify(secret, appstream .. "|t=" .. t, sign)
end

function _M.list()
    return shared:get_keys(0)
end

function _M.set(appstream, purpose, key)
    local suffix = SUFFIX[purpose]
    if not suffix then
        return nil, "purpose must be play or publish"
    end
    return shared:set(appstream .. suffix, key)
end

function _M.del(appstream, purpose)
    local suffix = SUFFIX[purpose]
    if not suffix then
        return nil, "purpose must be play or publish"
    end
    return shared:delete(appstream .. suffix)
end

return _M
