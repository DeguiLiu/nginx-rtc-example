-- conf/hmac.lua - HMAC-SHA256 token sign/verify (统一三端鉴权).
-- token 消息统一: "<app>/<stream>|t=<t>"; sign = base64url(HMAC-SHA256) 无 padding.
-- 复用 lua-resty-openssl; base64url 用 ngx.encode_base64(no padding) + 字符替换, 不依赖 ngx.base64.

local hmac = require "resty.openssl.hmac"
local bit = require "bit"

local _M = {}

local function b64url(mac)
    -- ngx.encode_base64(s, true) 输出无 padding 标准 base64; 换成 URL-safe 字母表
    return (ngx.encode_base64(mac, true)):gsub("+", "-"):gsub("/", "_")
end

-- 常量时间比较. Lua 的 `==` 在首个不同字节处短路, 使调用方能通过响应延迟逐字节
-- 试探出合法签名. 两侧都是定长 base64url(SHA-256 MAC), 长度不是秘密, 因此长度不等
-- 时直接返回 false 不泄漏信息; 等长时循环次数与差异位置无关.
local function ct_eq(a, b)
    if #a ~= #b then
        return false
    end
    local diff = 0
    for i = 1, #a do
        diff = bit.bor(diff, bit.bxor(string.byte(a, i), string.byte(b, i)))
    end
    return 0 == diff
end

function _M.sign(secret, msg)
    local h, err = hmac.new(secret, "sha256")
    if not h then
        return nil, err
    end
    return b64url(h:final(msg))
end

function _M.verify(secret, msg, sign)
    if "string" ~= type(secret) or "" == secret
            or "string" ~= type(sign) or "" == sign then
        return false
    end
    local ok, mac = pcall(_M.sign, secret, msg)
    if not ok or not mac then
        return false
    end
    return ct_eq(mac, sign)
end

return _M
