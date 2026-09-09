# rtc-gateway — 自研 RTMP/WHIP → WebRTC 低延迟直播网关

自研 C 模块(`module/ngx-rtc-module`)跑在 OpenResty/nginx 上，把 RTMP 或 WHIP 推流转成
RTP/SRTP，通过 UDP 直出给浏览器 WebRTC 播放；同源同时支持 HTTP-FLV / HLS / DASH 多协议输出。
架构一句话：`ffmpeg/WHIP 推流 → nginx(RTMP/HTTP) → 自研模块(bridge→媒体环/shm→SRTP/UDP) → 浏览器 WebRTC`。

> 详细设计见 `docs/`(架构、多 worker shm 设计、关键概念、评估报告等)。

## 目录

```
module/                 自研 nginx 模块源码(src C + config + test host 单测)
vendor/                 源码依赖
  nginx-http-flv-module/   HTTP-FLV/RTMP 引擎源码(v1.2.14-2-g2ad3dab)
  opus-1.3.1/              Opus 源码
deploy/nginx/
  conf/                   nginx.conf + 自研 *.lua(HMAC 鉴权/stats/flvplayer/观众计数…)
  html/                   rtcplayer.html(WebRTC 播放页)/flv.min.js/hmac-sha256.js
client/                  Node 端播放/推流脚本(play.mjs 播放、whip_push.mjs WHIP 推流)
scripts/                 build-deps.sh / build-openresty.sh / fetch-deps.sh
docs/                    设计、评估、实现指南等文档(含中文设计/测试/编译文档)
run.sh                   sync / nginx / push / keep-push / stop / verify
```

## 依赖与版本

| 依赖 | 形式 | 版本/来源 |
|---|---|---|
| OpenResty | build 时拉取 | 1.31.1.1 (openresty.org 发行) |
| nginx-http-flv-module | vendor 源码 | v1.2.14-2-g2ad3dab (winshining/nginx-http-flv-module) |
| Opus | vendor 源码 | 1.3.1 (xiph/opus) |
| libsrtp | build 时拉取 | 2.3.0 (ciscosystems/libsrtp) |
| FFmpeg 精简库 | build 时拉取 | aac 解码 + swresample + avutil |
| libavcodec/swresample/avutil | 见上 | 同上(音频 worker 用) |

预编译产物统一进 `build/third/{include,lib}`(与旧 `/.../third` 同构)。`module/config` 通过
`NGX_RTC_THIRD` 覆盖其位置(默认 `<repo>/build/third`)；本机已有预编译库时可
`export NGX_RTC_THIRD=/path/to/third` 跳过重编这些库。

## 构建

```bash
# 1) 自研模块 host 单测(不需要 nginx/第三方)
make -C module/test run_tests        # 期望全绿

# 2) 依赖静态库(opera: opus 用 vendor 源码; libsrtp/ffmpeg 联网拉取) → build/third
scripts/build-deps.sh

# 3) 拉 openresty 并装配编译 → 输出前缀(默认 build/nginx, 可 OPENRESTY_PREFIX=...)
OPENRESTY_PREFIX=$PWD/build/nginx scripts/build-openresty.sh
```

## 运行(运维)

```bash
OPENRESTY_PREFIX=/path/to/nginx-prefix ./run.sh nginx     # sync deploy 配置 + 启动
./run.sh push          # ffmpeg 推 livestream(画面左上角烧北京秒表, 便于目测延迟)
./run.sh keep-push     # 保活版推流(ffmpeg 退出自动重启, stop 会一并停掉)
./run.sh verify        # node client/play.mjs 冒烟播放
./run.sh stop
```

实例前缀解析顺序：`OPENRESTY_PREFIX` env → `build/nginx` → `../openresty-rtmp-new/nginx`(与现网共存)。
`run.sh` 的 `nginx|start` 会先 `sync`：把 `deploy/nginx/{conf,html}` 拷入前缀并生成
`conf/nginx.rtc.conf`(候选 IP 自动探测或 `RTC_CANDIDATE_IP` 覆盖)。

### 端口与入口

| 端口/协议 | 用途 |
|---|---|
| 18082 HTTP | `/flvplayer`(HTTP-FLV 页)、`/rtcplayer.html`(WebRTC 页)、`/rtc/v1/stats`、`/rtc/v1/flvcnt`、`/metrics` |
| 1935 RTMP | 推流与 HTTP-FLV 源 |
| 8000 UDP  | WebRTC SRTP/SRTCP + ICE/STUN |

鉴权统一 HMAC token：`t`=过期秒，`sign`=base64url(HMAC-SHA256(`<app>/<stream>|t=<t>`))；
默认演示 secret `demo-secret-0123456789abcdef0123456789abcdef`，每流 secret 见 `deploy/nginx/conf/stream_keys.lua`。

## 测试

- host 单测：`make -C module/test run_tests`(71 用例，纯 C 无 nginx 依赖)。
- 端到端：`./run.sh verify`(werift 客户端播放冒烟)。

## License

自研部分见仓库顶层 LICENSE(缺省私有，发布前请补)。`vendor/` 与 `deploy/nginx/html/flv.min.js`
为第三方，保留各自上游 LICENSE。
