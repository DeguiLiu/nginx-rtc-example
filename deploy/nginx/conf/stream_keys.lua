-- Stream-key config (pure Lua table, hot-reloaded by config.lua).
-- 每流独立 HMAC secret (>=32B, 仅服务端持有); 客户端持 secret 本地签 token(t/sign),
-- 线上不再传明文 key。
return {
    ["live/livestream"] = "demo-secret-0123456789abcdef0123456789abcdef",
    ["live/whiptest"] = "demo-secret-0123456789abcdef0123456789abcdef",
    ["live/test"] = "test-secret-4567890abcdef0123456789abcdef",
    ["live/hotreload"] = "hot-secret-67890abcdef0123456789abcdef0",
    ["live/luahotload"] = "lua-secret-abcdef0123456789abcdef012345",
}
