# ngx-rtc-module 架构指导（第一份）—— 借鉴 SRS 6.0 与 nginx 源码

## 结论

1. 当前 ngx-rtc-module 已打通「RTMP → RTP 封装 → SRTP → UDP」主链路，但 UDP 媒体面**完全丢弃客户端上行 SRTCP**（`ngx_rtc_stream_module.c` 注释明确 "Else: SRTP/SRTCP; the server only sends SRTP, so nothing to do"），导致 WebRTC 服务器侧的 QoS 闭环整体缺失：无 NACK 重传、无关键帧请求/首帧加速、无 session 超时回收。
2. 对 sub-500ms 直播，**三项必须立即补**：SRTCP 收发 + RTCP 编解码（前提）、NACK 下行重传、首帧加速（缓存最近关键帧/GOP）。TWCC/GCC/REMB 对「RTMP 推流 → 单向播放」场景**不适用，可后置**。
3. 关键架构差异：SRS 的推流端是浏览器（RTC 推流），其 PLI 机制是把关键帧请求送回**浏览器编码器**；而 ngx-rtc-module 的推流端是 RTMP（TCP 可靠、无 RTC 上行），PLI 无处可送，**必须用「缓存最近关键帧 + 订阅即发」替代 PLI**。因此 ngx 只需要 SRS 发送侧 ARQ（NACK 重传）的一半，不需要 SRS 接收侧丢包检测（`SrsRtcNackForReceiver`）的那一半。

---

## 1. 差距清单（SRS 有、ngx-rtc-module 缺）

SRS 路径均相对 `srs-server-6.0-r1/trunk/src/`；ngx 路径相对 `ngx-rtc-module/src/`。

| # | 机制 | SRS 实现位置 | 对 sub-500ms 是否必需 | 建议优先级 |
|---|------|-------------|---------------------|-----------|
| 1 | SRTCP 加解密（protect/unprotect_rtcp） | `srs_app_rtc_conn.cpp` SrsSecurityTransport::protect/unprotect_rtcp；ngx 的 `ngx_rtc_srtp.c` 只有 protect/unprotect_rtp | **必需**（一切 RTCP 的前提） | P0 |
| 2 | RTCP 编解码（compound、NACK/PID+BLP、PLI、RR 最小集） | `srs_kernel_rtc_rtcp.cpp` SrsRtcpCompound/Nack/Pli/RR | **必需** | P0 |
| 3 | NACK 下行重传（发送侧 ARQ + 源级 RTP 环形缓存） | `srs_app_rtc_source.cpp` SrsRtcSendTrack::on_nack/on_recv_nack/fetch_rtp_packet（L2905-2950）；`srs_app_rtc_queue.cpp` SrsRtpRingBuffer | **必需**（丢包 >3% 时无 NACK 画面迅速劣化） | P0 |
| 4 | 首帧加速：缓存最近关键帧/GOP + 订阅即发（替代 PLI） | SRS 6.0 实际 `consumer_dumps` 打印 "no gop cache"（`srs_app_rtc_source.cpp` L568），靠 PLI + 每次 IDR 前 STAP-A；RTMP 场景无 PLI 可用，须自建 GOP/关键帧缓存 | **必需**（否则新观众等 2-5s 下一个 IDR） | P0 |
| 5 | Session 生命周期 + 超时回收 | SRS SrsRtcConnection::is_alive（last_stun_time + session_timeout）；ngx 的 session 用 `ngx_alloc` 后从不释放 | **必需**（资源正确性） | P0 |
| 6 | Opus 音频封装（timestamp=dts*48、marker=1、一包一帧） | `srs_app_rtc_source.cpp` SrsRtcRtpBuilder::package_opus（L1033）；转码在 `srs_app_rtc_codec.cpp`（音频转码另有他人做，封装归属本模块） | **必需**（完整直播） | P0 |
| 7 | RR + XR RRTR（维护 RTT、供客户端丢包统计/同步） | `srs_app_rtc_conn.cpp` send_rtcp_rr（L2373）、send_rtcp_xr_rrtr（L2413），定时 1s | 建议（RTT 自适应 NACK 间隔是优化，不是必需） | P1 |
| 8 | NACK 间隔随 RTT 自适应 | `srs_app_rtc_queue.cpp` SrsRtpNackForReceiver::update_rtt（L302）；`srs_kernel_rtc_rtcp.cpp` XR dlrr/lrr 算 RTT | 建议（弱网更稳） | P1 |
| 9 | 每订阅者独立 SSRC/seq/timestamp 重写 | `srs_app_rtc_source.cpp` SrsRtcSendTrack::rebuild_packet + SrsRtcSeqJitter/SrsRtcTsJitter（L2785-2903）；ngx 目前共享 seq/ts/ssrc | 建议（共享 seq + 源级缓存也可 work，见 §3 决策点） | P1 |
| 10 | TWCC（transport-wide cc，上行带宽估计） | `srs_app_rtc_conn.cpp` on_rtp_cipher 在 SRTP 解密前解析 TWCC（L1388）、send_periodic_twcc（L1550）；`srs_kernel_rtc_rtcp.cpp` SrsRtcpTWCC | 不适用（RTMP→RTC 单向播放，无上行媒体） | P2/不做 |
| 11 | GCC 带宽估计 | SRS 未在服务器实现下行 GCC，`on_rtcp_feedback_twcc` 为空实现（L2193） | 不适用（服务器无编码器可调码率） | P2/不做 |
| 12 | REMB | SRS 忽略（`on_rtcp_feedback_remb` 空，L2198）；Chrome 已转向 TWCC | 不适用 | 不做 |
| 13 | 音视频 NTP/RTP 同步（avsync） | `srs_app_rtc_source.cpp` SrsRtcRecvTrack::update_send_report_time/cal_avsync_time（L2532-2581） | 不适用（下行音频/视频 timestamp 均源自同一 RTMP timestamp，天然同步；该机制是 RTC→RTMP 桥接用） | P2/不做 |
| 14 | 多 worker 共享内存（source/session 注册表 + shm） | nginx 特有：`ngx_shm_zone`/`ngx_slab_pool`/`ngx_shmtx`；ngx 目前单 worker 全局链表 | 建议（多 worker 正确性/扩展性） | P1 |
| 15 | UDP 收包循环 drain（每次事件处理多包） | nginx `ngx_event_udp.c` ngx_event_recvmsg 的 `do { } while (ev->available)` 模式；ngx 现 handler 每次只读一包 | 建议（高负载丢包风险） | P1 |

### SRS 关键机制速览（写代码时的直接参照）

- **NACK 发送侧 ARQ**：`SrsRtcSendTrack::on_nack` 把发出的包按 seq 存入 ring buffer（视频 1000 / 音频 100，支持 no-copy）；收到客户端 NACK 后 `on_recv_nack` → `fetch_rtp_packet`（校验 seq 完全一致再重传，避免 SRTP 失败）→ `do_send_packet` 重新 protect 后发送。这是 ngx 需要复刻的核心，但 buffer 应放在 `ngx_rtc_source_t`（源级，共享 seq 方案）。
- **首帧/关键帧**：SRS 每次 IDR 前用缓存 SPS/PPS 组 STAP-A（`package_stap_a`），ngx 已实现同款；SRS 靠 `SrsRtcPLIWorker` 去重限频地向推流端要关键帧。ngx 推流端是 RTMP，改为缓存「最近一次 IDR 的 STAP-A + 该 IDR 的 RTP 包」即可，订阅建立时先发缓存再发实时流。
- **TWCC 的一个坑（若将来做 RTC 推流再参考）**：必须在 `srtp_unprotect` **之前**解析 RTP 头里的 TWCC sequence，因为 padding 包/重复 NACK 包会导致 SRTP 解密失败（`on_rtp_cipher` L1400 注释）。
- **Opus 封装要点**：`pkt->header.set_timestamp(audio->dts * 48)`、marker 恒 true、一个 Opus 帧一个 RTP 包；libopus 侧 `compression_level=1`、`opus_delay=25ms`（`srs_app_rtc_codec.cpp` L248-253）。

---

## 2. nginx 模块开发要点（对自研模块的具体指导）

### 2.1 UDP 收发：ngx_event_udp.c 的既有机制

- nginx 为每个 UDP peer 建立并复用 `ngx_connection_t`：按 `(sockaddr, local_sockaddr)` 的 CRC32 建 rbtree 查找（`ngx_event_udp.c` `ngx_lookup_udp_connection`）。首个数据报放在 `c->buffer`，后续通过 `c->recv`（`ngx_udp_shared_recv`）读取；`c->send = ngx_udp_send`（sendto 到 peer），`c->send_chain = ngx_udp_send_chain`（支持批发送）。
- **指导 1（当前缺陷）**：`ngx_rtc_stream_handler` 每次事件只读一个数据报（先读 `c->buffer` 再 `c->recv` 一次就返回）。参考 `ngx_event_recvmsg` 的 `do { } while (ev->available)` 循环，改为循环 drain 直到 `NGX_AGAIN`，否则高负载时单事件多包会滞留（epoll level-triggered 下只是延迟，但 STUN/DTLS 握手变慢）。
- **指导 2**：session 的 peer 地址应利用 `c->sockaddr`，不要额外存 `sess->peer_addr` 副本；STUN 匹配后可把 session 挂到 `ngx_stream_set_ctx`（已是）或 `c->data`，避免 `ngx_rtc_session_find` 对全局链表的 O(n) 线性查找——建议换 rbtree（key = ufrag 的 CRC32）或直接复用 UDP 连接的 rbtree。
- **指导 3（阻塞风险）**：DTLS/SRTP 处理目前同步跑在 stream handler 里。OpenSSL DTLS 通常非阻塞，但要注意 SSL 库是否有同步等待；ngx 单进程事件循环里任何阻塞都会拖垮所有连接。后续若发现握手耗时，把 DTLS 握手拆到非阻塞状态机（nginx 已有 `ngx_ssl_handshake` 的 NGX_AGAIN 模式可参照）。

### 2.2 内存：ngx_pool_t vs 进程级对象

- RTC session/source **跨请求存活**，不能用 `r->pool`（请求结束即销毁）。现状 `ngx_rtc_http_module.c` 用 `ngx_alloc` 分配 session 但**从不释放**——泄漏。正确做法三选一：
  - **独立 pool**：`ngx_create_pool` + 挂 `ngx_pool_cleanup_add` 到连接/cycle，session 结束 `ngx_destroy_pool`（推荐，符合 nginx 惯例）。
  - **shm + slab**：多 worker 共享 source/session 注册表时用（见 2.5）。
  - 单 worker 若想最小改动：至少在 DTLS alert（Close Notify）或超时定时器里 `ngx_free`，并把 session 从 `ngx_rtc_sessions` 链表摘除。
- **指导 4**：NACK 环形缓存里的 RTP 包属于热路径，避免每包 `ngx_palloc`。预分配固定容量数组（如 `ngx_rtc_source_t` 里 `ngx_rtc_pkt_cache_t[1000]`，每个 slot 存 seq + 指针 + 长度，数据区用一块预分配大缓冲或按 MTU 分片），与 SRS `SrsRtpRingBuffer` 的 `SrsRtpPacket*` 数组同构。

### 2.3 ngx_chain_t / ngx_buf_t 零拷贝

- SRTP 每订阅者 auth tag 不同，**RTP 明文无法跨订阅者零拷贝**——每个订阅者必须有自己的密文缓冲（现状 `ngx_rtc_rtc_emit` 里栈上 `cipher[1600]` + `ngx_memcpy` + protect，是正确的、也是最小成本方案，保持即可）。
- **指导 5**：不要引入 `ngx_chain_t`/`ngx_output_chain` 到 RTP 热路径——`ngx_buf_t` 的 file/shadow/mmap 语义对 UDP 单包发送无收益，反而增加分配。`c->send(c, buf, len)` 一条 sendto 已够；批量优化用 `ngx_udp_send_chain`（它内部会拼 iovec/sendmmsg）。
- **指导 6**：`ngx_create_temp_buf`/`ngx_alloc_chain_link` 用于 HTTP 信令响应没问题（现 `ngx_rtc_http_module.c` 已正确使用），但媒体面不要复用这层。

### 2.4 事件循环与定时器

- nginx 定时器是全局 rbtree（`ngx_event_timer.c`），`ngx_event_add_timer(ev, ms)` / `ngx_event_del_timer`，到期置 `ev->timedout=1` 并回调 `ev->handler`。**RTC 的周期性任务必须走这条机制，禁止自建线程/定时器**。
- **指导 7**：对应 SRS 的三个定时器，用 nginx 事件定时器替换：
  - NACK 检测/重传：SRS 20ms（`SrsRtcConnectionNackTimer`）→ ngx 里其实无需独立 NACK 定时器（接收 NACK 是事件驱动），只有「session 超时」需要定时器；
  - Session 超时：参考 SRS `session_timeout`（默认约 30s，STUN 心跳刷新 `last_stun_time`），在 stream 模块给每个 UDP session 挂一个 `ngx_event_t`，收 STUN 时重置；
  - RR 周期发送：1s 定时器（P1，做 RTT 统计时再加）。
- **指导 8**：注意 `ngx_event_timer` 的 key 单位是 `ngx_current_msec`（毫秒），SRS 的参数（20ms/50ms/1s）可直接映射。

### 2.5 多 worker：ngx_shm_zone / ngx_slab_pool / ngx_shmtx

- 现状 `ngx_rtc_core.c` 用**进程内静态链表**（`static ngx_rtc_source_t *ngx_rtc_sources`），注释自认 "Single-worker MVP"。多 worker 下 HTTP 信令落在 worker A，而 UDP 媒体可能落在 worker B（取决于 reuseport/哈希），session 查不到。
- **指导 9（P1）**：把 `ngx_rtc_source_t` 的**索引**（name、ssrc、pt、sps/pps、subscriber 计数）放进 `ngx_shm_zone` + `ngx_slab_pool`，用 `ngx_shmtx` 保护；RTP 环形缓存（NACK 用）**不必共享**——每个 worker 只缓存自己发过的包。注意 `ngx_slab_alloc` 只适合小块（页内），大对象需独立 `ngx_shm_alloc` 或固定数组。
- **指导 10**：更简单的过渡方案是 UDP `listen ... reuseport` 时用一致哈希把同一 ufrag 分到同 worker（nginx-http-flv 已有类似模式），或信令阶段把 session 的候选端口做成 per-worker 端口。短期可接受，长期仍建议 shm。

### 2.6 配置解析：ngx_command_t

- 现 `ngx_rtc_stream_commands`（`rtc` 无参开关）和 `ngx_rtc_http_commands`（`rtc_play`/`rtc_candidate_ip`/`rtc_candidate_port`）是标准写法，已用 `ngx_conf_set_str_slot`/`ngx_conf_set_num_slot`，无需自写 setter。
- **指导 11**：新加开关（如 `rtc_nack on|off`、`rtc_gop_cache_size`、`rtc_session_timeout`）沿用 `NGX_CONF_TAKE1` + 内置 set 函数 + `NGX_CONF_UNSET` 判默认值的模式；布尔开关参考 `ngx_conf_set_flag_slot`。不要在 `init_process` 里做需要配置值的逻辑（配置在 `postconfiguration` 合并完成后才可用）。

---

## 3. 给主 agent 的下一步行动清单

### 第一梯队：补 WebRTC 完整性（必需，缺了功能不达标）

按依赖顺序执行，每步都是独立可验证的增量：

1. **SRTCP 收发 + RTCP 编解码（P0，前提）**
   在 `ngx_rtc_srtp.c` 增加 `ngx_rtc_srtp_protect_rtcp/unprotect_rtcp`（libsrtp2 的 `srtp_protect_rtcp`/`srtp_unprotect_rtcp`）；新建 `ngx_rtc_rtcp.c/h`，先实现最小集：compound 解码、NACK（PID+BLP）解码、PLI 解码、RR 编码。参照 `srs_kernel_rtc_rtcp.cpp` 的 `SrsRtcpCompound`/`SrsRtcpNack`/`SrsRtcpPli`。stream 模块的 `else` 分支改为「unprotect_rtcp → 分发 RTCP」。

2. **源级 RTP 环形缓存 + NACK 下行重传（P0）**
   在 `ngx_rtc_source_t` 增加固定容量 RTP 缓存（视频 1000 包 / 音频 100 包，含 seq 校验），`ngx_rtmp_rtc_emit` 发之前把明文 RTP 按 seq 存缓存；收到 NACK 后按 seq 取包 → 重新 `protect_rtp` → 发给该订阅者。参照 `SrsRtcSendTrack::on_recv_nack` + `fetch_rtp_packet`（校验 seq 完全一致再发，避免 SRTP 失败）。

3. **首帧加速：缓存最近关键帧 + 订阅即发（P0，替代 PLI）**
   `ngx_rtc_source_t` 已有 sps/pps 缓存；再缓存「最近一次 IDR 的 STAP-A RTP 包 + 该 IDR 各 FU-A/单包 RTP」。session DTLS 完成订阅时（`ngx_rtc_stream_dtls_done`），先按序发缓存关键帧包，再接实时流。注意限制缓存大小（一个 GOP 或几 KB 级），后续可加 pacer 平滑发送。

4. **Session 超时回收 + 内存修复（P0）**
   session 用独立 pool 或至少显式 `ngx_free` + 从链表摘除；stream 模块加超时定时器（STUN 心跳刷新，参考 SRS `session_timeout`）；DTLS alert（Close Notify）触发清理。修复 `ngx_rtc_http_module.c` 现有 session 泄漏。

5. **Opus 音频封装接入（P0，与音频转码协作）**
   桥接模块在音频转码产出 Opus 帧后，按 `timestamp = dts * 48`、marker=1、一帧一包封装成 RTP 广播。封装逻辑已具备复用价值（`ngx_rtc_rtp.h` 加一个 `ngx_rtc_opus_packetize` 即可）。

### 第二梯队：性能优化（可后置）

6. **每订阅者独立 SSRC/seq/ts 重写（P1）**：SRS `rebuild_packet` + seq/ts jitter。当前共享 seq + 源级缓存可先跑通 NACK，重写是后续做 RTX/多路复用时的正确性需求。
7. **RR + XR RRTR + RTT 自适应 NACK 间隔（P1）**：先发固定间隔 RR（1s），后续接 XR RRTR 算 RTT 调 NACK 重传节奏。
8. **多 worker shm 化注册表（P1）**：source/session 索引迁 `ngx_shm_zone` + `ngx_shmtx`。
9. **UDP handler 循环 drain + STUN 查找 rbtree（P1）**：消除线性查找与单包处理。
10. **Pacer（P2）**：GOP dump 时按帧率平滑发送，避免首帧洪泛打爆客户端 jitter buffer。

### 明确「不做的」

- **TWCC / GCC / REMB**：RTMP→RTC 单向播放场景服务器是纯转发，无上行媒体、无编码器可调码率，做了也只是解析再丢弃。除非未来引入「浏览器推流到服务器」或「多码率 ABR」，否则不投入。
- **音视频 NTP avsync（服务器侧）**：下行音视频 timestamp 同源（都从 RTMP timestamp 派生），客户端 jitter buffer 自行对齐，服务器不需要做 NTP 映射。

---

## 附：核心参照文件索引

| 目标 | 文件 |
|------|------|
| NACK 队列/环形缓存/参数 | `srs-server-6.0-r1/trunk/src/app/srs_app_rtc_queue.cpp` |
| 发送侧 ARQ / seq-ts 重写 / PT 重映射 | `srs-server-6.0-r1/trunk/src/app/srs_app_rtc_source.cpp`（L2816-3050） |
| RTCP 编解码（compound/NACK/PLI/RR/TWCC） | `srs-server-6.0-r1/trunk/src/kernel/srs_kernel_rtc_rtcp.cpp` |
| 连接调度 / PLI worker / RR / XR / do_send_packet | `srs-server-6.0-r1/trunk/src/app/srs_app_rtc_conn.cpp` |
| RTMP→RTC 桥接（B帧过滤/STAP-A/Opus 封装） | `srs-server-6.0-r1/trunk/src/app/srs_app_rtc_source.cpp`（L828-1408） |
| AAC→Opus 转码（另有人做，供参考） | `srs-server-6.0-r1/trunk/src/app/srs_app_rtc_codec.cpp` |
| UDP 收包/连接复用 | `openresty-1.31.1.1/bundle/nginx-1.31.1/src/event/ngx_event_udp.c` |
| 事件定时器 | `openresty-1.31.1.1/bundle/nginx-1.31.1/src/event/ngx_event_timer.c` |
| 内存池 / chain / slab / shmtx | `ngx_palloc.h`、`ngx_buf.h`、`ngx_slab.h`、`ngx_shmtx.h` |
