# 部署侧编程规范(deploy/**/*.lua、scripts/*.sh、client/*.mjs)

> 本仓没有 C 源码 —— `vendor/` 与 `build/src/` 里的都是独立仓 `nginx-rtc-module` 的副本。
> **C 部分规范只在该仓 `docs/nginx-coding-standards.md`**,本文件不再同步一份。
>
> 曾经同步过,结果是两份复制体各自漂移:本文件把 `ngx_event_recvmsg()` 的循环边界抄成了
> `while (ev->available)`,而 nginx 源码写的是 `do { ... } while (ev->available)`
> (`event/ngx_event_udp.c:67` 与 `:347`)。结论没受影响,但引用对不上源码,照着核会核不对。
> 维护一份副本的成本,高于为此多读一个文件。

## 结论

1. **C 层规则在这里一条都不适用。** 这三层没有 `ngx_*` API,只有 Lua 的 `ngx.*`、POSIX
   shell 与 Node 标准库;类型替换表、格式串、内存那几节只约束 C 代码。
2. **下面每条都对应一个已复现的缺陷**,不是风格偏好 —— 括号里给的是当时的现场。
3. **未修项单独列在文末**,不混进规则里。

## 1 Lua(`deploy/**/*.lua`)

- **日志级别按「谁的错」分。** 服务端故障与**鉴权拒绝**用 `ngx.ERR`(nginx 的 `auth_basic`
  也用 ERR 记 "password mismatch");**客户端输入非法**(body 不是 JSON、streamurl 格式错)
  是 bad request,用 `ngx.INFO`,对应 nginx core 的 "client sent invalid ...";**成功请求不记**,
  access log 已经有了。热路径上每请求一行 `ngx.ERR` 会把 `error_log` 变成流量日志。
- **跨阶段(access → log)的每请求状态用 `ngx.ctx`。** 它挂在 `r->pool` 上,由
  `ngx_http_lua_ngx_ctx_add_cleanup()`(`ngx_http_lua_ctx.c:50`)注册的 pool cleanup 释放,
  **晚于 log 阶段**;`ngx_http_lua_logby.c:77` 也确实取用 module ctx。反例:`flv_close.lua`
  曾只凭 `app`/`stream` 参数就减在线数,于是**任何外部请求(包括被 403 拒的)都能把某流的
  在观数清零** —— 由 `flv_auth.lua` 把 key 存进 `ngx.ctx`、log 阶段只在标记存在时递减来修。
  注意 `error_page` / `try_files` / `index` 这类内部重定向会重建 `ngx.ctx`。
- **共享字典的读-改-写不是原子的。** `get(k)` 后再 `incr(k, -1)`,两个并发请求都读到
  `cur == 1` 就会各减一次。用单次 `incr`(自带 `init` / `init_ttl`,键缺失时一并建键),
  或用 `add` / `replace` 做 CAS。
- **reload 不要先清空再重填。** `flush_all()` 与写回循环之间的窗口会让读方看到空字典,
  热更新瞬间拒掉本来有效的流。**先写新值,再删消失的键**(`conf/config.lua:_M.reload`)。

## 2 Shell(`scripts/*.sh`)

- 开头一律 `set -euo pipefail`:`-u` 让变量名拼错立刻失败而不是展开成空串,`-o pipefail`
  让管道前段的失败不再被最后一段的成功掩盖(否则 `sign_for` 会拿空签名去推流)。
- **打开 `-e` 之后「预期内的失败」必须自己接住。** `cmd` 后紧跟 `RC=$?` 的写法在 `-e` 下
  永远走不到 `RC=$?`,恰恰破坏了那些专门用来报告失败的检查 —— 写 `RC=0; cmd || RC=$?`。
  同理「找不到也可以」的查询要 `|| true` / `|| var=""`,否则 `var="$(pipeline)"` 的赋值失败
  会把脚本直接带走:`run.sh:detect_candidate_ip` 补上 `pipefail` 后就会在 `127.0.0.1`
  回退之前先退出,每条兜底都必须显式接住。
- `mktemp` + `trap 'rm -f "$f"' EXIT`,不用固定路径的 `/tmp/xxx`。
- 任何发起网络请求的外部客户端(mjs / ffmpeg / curl)都套 `timeout`,并单独识别 `124` ——
  否则信令挂起会让脚本和 CI 永久阻塞。
- 不要把 shell 变量插进 `python3 -c` 的源码,走 `sys.argv`。

## 3 Node(`client/*.mjs`)

- 顶层 `await` 一律收进 `async function main()` + `main().catch(...)`,否则失败的 `fetch`
  只给 UnhandledPromiseRejection 堆栈、不给原因。
- 每个 `fetch` 都带 `AbortSignal.timeout(...)`(`client/play.mjs` 的既有写法)。
- 信令响应先校验 `code` / 字段再使用:把错误响应当正常 SDP 传给 `setRemoteDescription`,
  抛出的是 werift 内部错误,与真实原因无关。
- `process.exit()` 前先把 stdout 写净。管道下 `console.log` 是异步的,紧接 `exit` 会截断
  输出;用 `writeSync(1, ...)`(本仓三个客户端都这么做)或设 `process.exitCode` 后自然退出。
- 长持有的 fd 用 `try/finally` 关闭。
- 解析 RTP 分片时,续片没有前置起始片(丢包 / 中途接入)要丢弃,不要 `concat(nil, ...)` ——
  崩溃点恰好落在该工具要观测的丢包场景上(`client/dump.mjs` 的 FU-A 分支)。

**未修,需单独决策**:HMAC secret 硬编码在可执行文件(`run.sh:34`、`client/lib/token.mjs` 的 `DEMO_KEY`),
且与 `deploy/nginx/conf/stream_keys.lua` 同值。**签名算法本身已收敛到 `client/lib/token.mjs` 一处**
(此前 play/dump/probe 各写一份,消息格式抄错一处就是 403);收敛的是算法与默认值,不是 secret 的存在。
去掉默认值会让 `./run.sh push` 与 `client/play.mjs` 在没有外部注入时不可用,属于使用方式的改变。
