-- conf/hmac.lua - HMAC-SHA256 token sign/verify (统一三端鉴权).
-- token 消息统一: "<app>/<stream>|t=<t>"; sign = base64url(HMAC-SHA256) 无 padding.
-- 复用 lua-resty-openssl; base64url 用 ngx.encode_base64(no padding) + 字符替换, 不依赖 ngx.base64.

local hmac = require "resty.openssl.hmac"

local _M = {}

local function b64url(mac)
    -- ngx.encode_base64(s, true) 输出无 padding 标准 base64; 换成 URL-safe 字母表
    return (ngx.encode_base64(mac, true)):gsub("+", "-"):gsub("/", "_")
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
    return mac == sign
end

return _M
