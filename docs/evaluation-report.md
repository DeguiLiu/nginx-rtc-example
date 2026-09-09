# RTMP 转 WebRTC 低延迟直播方案：独立技术评审报告

> 评审对象：`/home/dgliu/workspace/webrtc/ngx-rtc-module/`（纯 C 核心 + nginx 胶水）+ `openresty-rtmp-new/nginx/conf/nginx.conf`、`run.sh`、`docs/` 设计文档。
> 评审方式：只读，以源码为准，不采信文档既有结论；集成正在进行，代码与文档存在"已实现但文档标注未接入"的错位，已逐条核对。
> 评审时间：2026-09-09。

## 1 结论与总体评价

### 1.1 一句话结论

方案主线（RTMP 接入 → H264/Opus RTP 封装 → STUN/DTLS/SRTP → UDP 出网 → 单观众 werift 播放）已真实跑通，核心分层与 SRS 移植思路合理，但当前质量不适合直接作为多观众低延迟直播服务上线：存在 1 个可被网络客户端触发的栈内存破坏（P0），7 项 P1（音频 RTP 时间戳错误、NACK/GOP 缓存设计矛盾、RTCP 反馈未协商、UDP 连接槽位泄漏、源级 PT/SSRC 单例化、无任何协议单测、状态机双份维护），以及约 10 项 P2。

### 1.2 现状核验（源码与文档错位）

| 文档声明 | 代码实际 | 结论 |
| --- | --- | --- |
| `架构设计.md §4.2`："会话无超时回收定时器，属已知待补项" | `ngx_rtc_stream_module.c:483-509` 已有 2s 周期 reap 定时器，会话超时关闭 | 文档过期，代码已实现 |
| `架构设计.md §1.2`：RTCP/GOP 缓存/HSM"集成中/设计中" | `ngx_rtc_rtcp.c` 已编译且 `ngx_rtc_stream_module.c:311-384` 已接入 SRTCP 解码、NACK/PLI；GOP ring 已在 `ngx_rtc_core.c` 落地并被 bridge emit 调用 | 文档过期，代码已集成 |
| `详细设计.md §2.4`："每 session 栈上 cipher[1600]" | cipher 已常驻 `ngx_rtc_session_s`（`ngx_rtc_core.h:79`） | 文档过期，代码更优 |
| `详细设计.md §5.5`：HSM/SRTP_READY entry action 承载订阅 | HSM 各 entry/action 仍为 TODO 空壳（`ngx_rtc_session_fsm.c`），真实逻辑内联在 stream 模块 | 半集成，双份状态源 |

结论：**评估以代码为准**。文档的"能力状态表"比代码落后一两个迭代，阅读文档判断项目进度会低估已完成的集成度，但也会掩盖上述代码缺陷。

### 1.3 端到端验证口径（实测支持）

`run.sh` + `webrtc-client/play.mjs` 已验证：H264 761 包/362 KB、Opus 389 包/67 KB、首包约 560 ms、信令 `code=0`、candidate `172.16.48.122:8000`。单观众、局域网、无丢包、同构 werift 客户端条件下链路可用。以下缺陷多数在"多观众异构浏览器、公网丢包、长期运行"场景下暴露。

## 2 架构与集成现状评估

### 2.1 分层：合理，符合预期

三层划分成立且依赖方向单向：纯 C 核心（`ngx_rtc_rtp/sdp/stun/dtls/srtp/rtcp/audio/core/hsm/session_fsm`）不依赖 nginx 头文件、无全局可变状态，通过回调（`emit`、`rtcp_decode_cb`）与调用者 buffer 解耦；三个 nginx 胶水模块只做事件 → 核心调用 → socket 收发的翻译。媒体面（RTMP events → bridge → 明文 RTP 广播 → 每 session SRTP）与信令面（HTTP offer/answer → STUN 绑定 → DTLS 导出密钥 → 订阅）职责边界清楚。addon `config` 的 CORE/HTTP/STREAM 三类型注册可编译通过，`CORE_LIBS` 静态链入 FFmpeg/opus/libsrtp2 方式可行（`ffmpeg-4-fit` 的旧 API `channel_layout` 与所用 FFmpeg 4 匹配，无兼容问题）。

### 2.2 单 worker 模型：成立但生命周期有硬伤

- 单 worker 下 source/session 为进程内链表、广播与订阅同一事件循环，无锁正确。`worker_processes 1` 与实现匹配。
- **硬伤一（P1）**：session 关闭只释放自研结构，不结束底层 nginx stream UDP 会话。`ngx_rtc_stream_module.c:446-480` `ngx_rtc_stream_session_close` 仅 `ngx_stream_set_ctx(..., NULL)` + `ngx_rtc_session_remove` + `ngx_free(sess)`；nginx stream core 对非 proxy 的 UDP 会话不做空闲回收（`ngx_event_udp.c` 无任何 UDP 空闲定时器），UDP 连接由 `ngx_delete_udp_connection` 经 pool cleanup 触发，只有 `ngx_stream_finalize_session`/`ngx_stream_close_connection` 会销毁 pool。因此每个"来过的客户端 4 元组"对应的 `ngx_connection_t` 永久占用连接槽，累计到 `worker_connections`(1024) 后 nginx 无法为新观众创建 UDP 会话（丢数据报）。观看端断开越频繁、观众越多越早耗尽。
- **硬伤二（P1）**：source 生命周期无回收。`ngx_rtc_core.c:20-49` 只增不减，且 `ngx_rtc_rtp_ring_push`（`ngx_rtc_core.c:188-193`）在首个 RTP 到达时 `calloc(2048 × sizeof(slot))`，单 source 环约 2.4 MB，随推流改名次数线性累积，进程内永不复用。RTMP 断流重推也不重置 `video_seq/audio_seq/have_ts`（bridge 未接 source FSM 的 `PUBLISH_STOP`/`PUBLISH_START`），重推后 RTP seq/时间戳非单调，订阅者可能解码错乱。
- **P2**：session_find 线性 O(n)、reap 定时器全表 O(n)，会话数百级可接受，数千级有压力；UDP handler 每事件只读一个数据报（`ngx_rtc_stream_module.c:188`），高负载握手变慢。均为可后置优化。

### 2.3 状态机落地质量：双份状态源，存在漂移风险

- session HSM 已实际驱动（HTTP init、stream 各事件 dispatch、reap/close 查询 `is_ready`），但 HSM 定义的行为动作全部是 TODO 空壳：`ngx_rtc_session_fsm.c:112-121`（DTLS done 导出 SRTP 密钥）、`:128-142`（SRTP_READY entry 订阅）、`:162-170`（CLOSED entry 回收）都为空；真实动作仍内联在 `ngx_rtc_stream_module.c:400-431`（`ngx_rtc_stream_dtls_done` 完成 key 导出 + srtp_create + 订阅 + GOP 回放）与 `:446-480`（close 回收）。即"状态机说一套、实际逻辑做一套"，未来改动极易两边失配。
- source FSM 是完全死代码：`ngx_rtc_session_fsm.c` 定义了 `s_source_*` 全套状态/转移/API，但仓库内除 `session_fsm.c/h` 外无任何调用方（grep 无命中）。bridge 的 publish 启停、首关键帧均未驱动 source 机。约 250 行只增负担，不产生价值。
- 建议：要么把订阅/回收动作真正移入 HSM entry/exit action（并删掉 stream 模块内联重复），要么删除 HSM 中空 action 与 source 机，保留当前"纯状态跟踪"用法。当前状态属于过度设计与落地不彻底的中间态。

## 3 协议正确性缺陷

### 3.1 P0 - STUN BindingResponse 编码可越界写栈

- 位置：`ngx_rtc_stun.c:146`（仅校验 `out_len < 128`，编码全程不检查剩余空间）、`:167-218`（逐属性写入）；调用方栈缓冲 `ngx_rtc_stream_module.c:224` `uint8_t resp[128]`。
- 机理：请求 USERNAME 中远端 ufrag 长度由解码器放宽到 63 字节（`ngx_rtc_stun.c:99-108`），本地 ufrag 为 9 字节（`%08xu`）时，响应 USERNAME 值最长约 63 字节，整包 = 20 头 + (4+63+1 pad) + 12(XOR-MAPPED) + 24(MESSAGE-INTEGRITY) + 8(FINGERPRINT) ≈ 132 字节，超出 128 字节缓冲 4 字节。
- 影响：任何能拿到一个合法 session ufrag 的观看端（只需用正确 stream key 建一个 play session 即可获得自己的 ufrag），即可构造一个 `USERNAME=<自己的ufrag>:<超长串>` 的 STUN BindingRequest 触发 worker 栈破坏（启用栈保护则 abort，否则为未定义内存破坏）。单 worker 架构下即全站直播 DoS。
- 修复：响应缓冲扩到 256 或在编码器内对 `pos` 做 `out_len` 边界检查并返回 `-1`；同时将解码/编码的 ufrag 上限收紧到与实际分配值一致。

### 3.2 P1 - Opus 音频多帧同时间戳

- 位置：`ngx_rtmp_rtc_bridge_module.c:481`（`ctx.ts` 每次 transcode 调用固定一次）、`:499`、`:505`（每 Opus 帧都用同一 `ctx->ts`）；`ngx_rtc_audio.c:301-326` 编码循环一帧 AAC 可产出多帧 Opus。
- 机理：AAC 帧 1024 样本@48k（21.33 ms），Opus 帧固定 960 样本@48k（20 ms）；FIFO 每 ~15 个 AAC 帧会累积出一个额外 Opus 帧，即单次 `transcode` 可能 emit 2 帧 Opus，二者 RTP 时间戳相同、seq 连续。客户端 jitter buffer/解码器按时间戳去重，第 2 帧被丢弃 → 周期性 (~0.32 s 一次) 丢 20 ms 音频，听感为规律性卡顿。
- 修复：源级维护单调音频 RTP 时间戳计数，每成功 emit 一帧 Opus `ts += 960`（初值取首个 AAC tag 换算值），替代"每 AAC 帧用 tag 时间戳一次"。

### 3.3 P1 - GOP ring 混存音视频，NACK 按 seq 定位基本失效且忽略 media_ssrc

- 位置：bridge 把每个 RTP 包（含音频）都入同一 ring（`ngx_rtmp_rtc_bridge_module.c:519`）；`ngx_rtc_rtp_ring_get`（`ngx_rtc_core.c:236-270`）以"ring 最老槽的 16 位 seq"为基准做 `dist = rtp_seq - start_seq` 线性差定位；调用方 `ngx_rtc_stream_module.c:360-373` 未过滤 NACK 的 `media_ssrc`。
- 机理与影响：音视频 seq 各自独立计数，ring 最老槽常是异类媒体包；视频 NACK 的 seq 与音频基准 seq 差值远超 ring 容量(2048)，`dist >= count` 直接 miss → 视频重传基本永不命中；偶发命中时还可能把"seq 数值恰巧相等的异媒体槽"当作目标（`media_ssrc` 未核对），重传出错误流的数据。
- 修复：NACK 只服务视频且按 `media_ssrc` 过滤；ring 拆成 video/audio 两条，或 ring_get 改为在保留窗口内按"ssrc+seq"双重匹配。

### 3.4 P1 - NACK/PLI 处理已实现，但 SDP answer 不声明 rtcp-fb，按 RFC 该能力未协商、链路休眠

- 位置：answer 生成（`ngx_rtc_sdp.c:770-845`）只写 `rtcp-mux/rtcp-rsize/rtpmap/fmtp/ssrc`，无 `a=rtcp-fb`；对端 werift/浏览器的 NACK/PLI 只有在 offer 与 answer 同时声明才生效。服务端 `ngx_rtc_stream_module.c:360-378` 的 NACK 重传/PLI GOP 回放逻辑对合规客户端不会触发。
- 影响：表现为"实现了一整套反馈恢复，实际从未运行"，弱网无任何抗丢包手段，同时 3.3 的 ring 缺陷也被掩盖。要么在 answer 中按协商 PT 输出 `a=rtcp-fb:<pt> nack`、`a=rtcp-fb:<pt> nack pli`，要么删除这些休眠分支。
- 附带 P2（同属 SDP 一致性）：answer 固定输出 video+audio 两个 m= 行（`ngx_rtc_sdp.c:930-942`），若 offer 只含单媒体或 codec 集不含 H264/Opus，answer 违反 RFC 3264"answer 必须为 offer 格式子集"；PT/rtpmap 也不从 offer 校验。Chrome 会直接 SDP 错误。

### 3.5 P1 - 源级 PT/SSRC 单例化，异构多观众互操作失败

- 位置：`ngx_rtc_http_module.c:255-262` 首个 play 会话把 offer 的 H264/Opus PT 固化到 source；`ngx_rtc_http_module.c:311-314` 后续所有 answer 复用该 PT；bridge 以该 PT 广播（`ngx_rtmp_rtc_bridge_module.c:391,397,506`）。
- 机理与影响：WebRTC 动态 PT 每会话协商；第 2 个观众若 offer 的 H264 PT 与第 1 个不同（浏览器间常见 96/102/… 差异），answer 的 m= 行会带一个"不在其 offer 中的 PT"，RFC 3264 下协商失败。同构 werift 客户端因 PT 分配固定而侥幸通过。这是多观众场景的架构性限制：单一明文 RTP 流无法为不同观众重标 PT。
- 修复方向：按 SRS `rebuild_packet` 思路，明文模板共享但发送前按 session 重写 RTP PT（每 session 本就有独立 cipher buffer，成本仅 1 字节写）；或信令侧要求所有观众接受源 PT（不推荐）。

### 3.6 P2 - DTLS 健壮性与安全

- 无重传定时器/握手期限：`ngx_rtc_dtls.c:208-243` 只以 `SSL_read` 被动驱动，从不调用 `DTLSv1_handle_timeout`；服务端末段 flight 丢失时客户端重传 Finished 后 OpenSSL 不重发末段，握手悬挂，靠全局 10 s 会话 reap 兜底（`ngx_rtc_stream_module.c:45`）。公网丢包场景握手失败率上升。
- `SSL_VERIFY_NONE`（`ngx_rtc_dtls.c:131`）+ 不自检对端证书指纹与 offer 是否一致；且 cipher 用 `"ALL"`（`:121`）。作为 sendonly 直播源风险可接受，但应至少限制 DTLS 1.2 与 `!aNULL:!eNULL:!kRSA`。
- STUN 请求侧不校验 MESSAGE-INTEGRITY/FINGERPRINT（`ngx_rtc_stun.c:60-126` 解码未解析 MI/FPR；`ngx_rtc_stream_module.c:229` 仅按 ufrag 命中即回）。信令为明文 HTTP 时 ufrag/pwd 可被嗅探，存在会话劫持/反射放大面。文档 `架构设计.md §5.3` 已自认"待验证"，应补验。

## 4 健壮性、性能与资源管理评估

### 4.1 资源与生命周期

- 会话内存泄漏方向已修复（reap 定时器 + close 释放），但见 2.2 的连接槽位泄漏（P1）与 source/ring 永不释放（P1/P2）。HTTP 信令无 body 大小/会话数上限，`auth.lua` 限流 30 次/分/IP 只能缓解。
- `ngx_rtc_http_module.c:159` body_buf 8 KB 与 `:163` sdp 8 KB 栈缓冲：超出部分被静默截断（`ngx_rtc_http_module.c:198-202` 若 body 超 8 KB 则后半丢失；JSON 缺 `}` 时 `ngx_rtc_http_json_string` 返回失败）。大 offer 会话会被 400 拒绝，非内存安全问题。
- 数据路径无每包堆分配：RTP scratch 为栈上 1500 B、密文 buffer 常驻 session、ring 为固定槽数组，符合 zero-copy 文档结论。每 session "1 memcpy + 1 次 SRTP"是协议下界，拷贝点合理。

### 4.2 并发与事件模型

- 单 worker 单事件循环，广播/回放/加密都在同线程，无锁正确；`ngx_rtc_session_send_rtp`（`ngx_rtc_core.c:144-168`）无锁遍历订阅链表安全。
- 潜在阻塞点：GOP 回放一次可向新订阅者突发发送最多 2048 包（`ngx_rtc_core.c:214-234`），多观众同时加入时在单事件循环内串行突发，会瞬时拉高发送延迟并可能打爆客户端 jitter buffer（无 pacing）。订阅建立后 NACK/PLI 若启用也会突发。属 P2（加 pacing/限速）。
- 音频转码（FFmpeg decode + swresample + opus encode）同步跑在 RTMP 事件回调里（`ngx_rtc_audio.c` 全同步），每 AAC 帧数百 µs 级 CPU，单 worker 下多路推流会互相挤压；属架构已知边界（P2 记录，多路时需评估）。

### 4.3 测试与可维护性

- **P1**：协议核心（RTP/SDP/STUN/DTLS/SRTP/RTCP/HSM）零提交单测。`测试文档.md §1` 自认 L0"规划中"。这类 RFC 位级代码没有 host 单测，3.1/3.2/3.3 类缺陷只能靠端到端碰运气暴露（而端到端只数包、不校验音频连续性与 NACK 命中）。
- P2：`ngx_rtc_rtcp.h:18-58` 的"集成注意事项"注释已过期（实际已接入），与代码现状矛盾，会误导后续维护。

## 5 差距汇总、优先级建议

### 5.1 与 SRS / nginx-http-flv 最佳实践差距（独立验证）

| 主题 | SRS/参考实践 | 本方案现状 | 定级 |
| --- | --- | --- | --- |
| 会话回收 | `SrsRtcConnection` 定时 is_alive + 超时关 | 已实现 RTC 层回收，但底层 UDP 连接槽位泄漏 | P1 |
| 发送侧 NACK ARQ | 每 track 独立 ring + seq 索引 + `fetch_rtp_packet` | 音视频混用单 ring、seq 定位失效、未协商 rtcp-fb | P1 |
| 每订阅者重写 | `rebuild_packet` 重写 PT/seq/ts | 单源 PT 共享，异构客户端不兼容 | P1 |
| Opus 封装 | 每帧 `ts += 帧长` | 一 AAC 帧多 Opus 帧同 ts | P1 |
| 首帧加速 | IDR 前 STAP-A + 关键帧缓存 | STAP-A 已实现；GOP 缓存已实现但回放含混存音频、无 pacing | P2 |
| UDP 事件处理 | `do{}while(ev->available)` drain | 每事件单包 | P2 |
| 明文共享 + per-session 加密 | 同（不可消除） | 已按最小成本实现 | 符合 |
| 状态机 | 显式状态/动作单一来源 | HSM 空 action + 内联逻辑双份，source 机死代码 | P2 |

### 5.2 最高优先级改进建议（按序执行）

1. **修复 STUN BindingResponse 越界写（P0 阻断）**：`ngx_rtc_stun.c` 编码器补 `out_len` 边界检查并扩容调用方缓冲（`ngx_rtc_stream_module.c:224`），同时收紧 ufrag 长度并对请求做 MESSAGE-INTEGRITY 校验。
2. **修复音频 RTP 时间戳（P1）**：源级单调计数、每 Opus 帧 `+960`，替换"每 AAC 帧固定 ts"。
3. **让 RTCP 反馈闭环真正可用（P1）**：SDP answer 补 `rtcp-fb`（nack/pli）；NACK 按 `media_ssrc` 过滤并改用音视频分离的 ring（或按 ssrc+seq 双重匹配）；PLI 处理改为"仅对未出首帧/重同步窗口内订阅者回放最近关键帧"，避免回放过期 GOP。
4. **修复资源生命周期（P1）**：session 关闭时调用 nginx stream API 结束底层 UDP 连接（释放 `ngx_connection_t` 槽）；source 增加回收/复用（断流复位 seq/ts、可配置容量、随引用释放 ring）。
5. **收敛状态机并补齐单测（P1/P2）**：把订阅/回收动作真正移入 HSM entry/exit action 或删除空 action 与 source 机；为协议核心补 host 单测（STUN 长度边界、Opus 时间戳递增、FU-A/STAP-A 位级、NACK ring 命中/串流、SRTP 往返等）。

---

## 附录：问题清单（file:line）

| 级别 | 问题 | 位置 |
| --- | --- | --- |
| P0 | STUN BindingResponse 越界写栈（响应包可达 ~132B > 128B 缓冲） | `ngx_rtc_stun.c:146,167-218`；`ngx_rtc_stream_module.c:224,259` |
| P1 | Opus 多帧同 RTP 时间戳（周期性丢 20ms 音频） | `ngx_rtmp_rtc_bridge_module.c:481,499,505`；`ngx_rtc_audio.c:301-326` |
| P1 | GOP ring 混存音视频 + NACK 按 seq 线性差定位失效、忽略 media_ssrc | `ngx_rtc_core.c:236-270`；`ngx_rtmp_rtc_bridge_module.c:519`；`ngx_rtc_stream_module.c:360-373` |
| P1 | answer 未声明 rtcp-fb，NACK/PLI 按 RFC 未协商、链路休眠 | `ngx_rtc_sdp.c:770-845`；`ngx_rtc_stream_module.c:360-378` |
| P1 | 会话关闭不结束底层 stream UDP 连接，连接槽位泄漏直至耗尽 | `ngx_rtc_stream_module.c:446-480` |
| P1 | 源级 PT 单例化 + answer 固定双 m 行，异构多观众 SDP 协商失败 | `ngx_rtc_http_module.c:255-262,311-314`；`ngx_rtc_sdp.c:930-942` |
| P1 | 协议核心零提交单测，位级缺陷仅靠端到端碰运气 | `ngx-rtc-module/` 无测试工程；`docs/测试文档.md §1` |
| P2 | HSM entry/exit action 空壳 + stream 内联双份状态；source FSM 死代码 | `ngx_rtc_session_fsm.c:112-142,162-170,399-407`；无调用方 |
| P2 | STUN 请求不校验 MI/FINGERPRINT；信令明文 HTTP | `ngx_rtc_stun.c:60-126`；`ngx_rtc_stream_module.c:229` |
| P2 | DTLS 无重传定时器、SSL_VERIFY_NONE、cipher "ALL" | `ngx_rtc_dtls.c:121,131,208-243` |
| P2 | source/ring 内存永不释放，重推流不复位 seq/ts | `ngx_rtc_core.c:20-49,188-193`；`ngx_rtmp_rtc_bridge_module.c` |
| P2 | GOP 回放无 pacing，突发 2048 包 | `ngx_rtc_core.c:214-234` |
| P2 | UDP handler 单包读取；session_find O(n) | `ngx_rtc_stream_module.c:188`；`ngx_rtc_core.c:51-67` |
| P2 | `ngx_rtc_rtcp.h:18-58` 集成注释过期，误导维护 | `ngx_rtc_rtcp.h` |
