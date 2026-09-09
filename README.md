# nginx-rtc-example — 自研 nginx-rtc-module 的部署示例(RTMP/WHIP → WebRTC 低延迟直播)

自研 C 模块跑在 OpenResty/nginx 上，把 RTMP 或 WHIP 推流转成
RTP/SRTP，通过 UDP 直出给浏览器 WebRTC 播放；同源同时支持 HTTP-FLV / HLS / DASH 多协议输出。
架构一句话：`ffmpeg/WHIP 推流 → nginx(RTMP/HTTP) → 自研模块(bridge→媒体环/shm→SRTP/UDP) → 浏览器 WebRTC`。

> **代码导航**：自研 C 源码在独立**公开仓 [DeguiLiu/nginx-rtc-module](https://github.com/DeguiLiu/nginx-rtc-module)**
> (MIT, 当前钉 tag v0.1.0)；本仓只保留组装件：deploy 配置/Lua、播放页、client、构建运维脚本与文档。
> 详细设计见 `docs/`(架构、多 worker shm 设计、关键概念、评估报告等)。

## 目录

```
vendor/                 依赖说明(不内嵌任何源码; 唯一内嵌三方运行时资产见下)
deploy/nginx/
  conf/                   nginx.conf + 自研 *.lua(HMAC 鉴权/stats/flvplayer/观众计数…)
  html/                   rtcplayer.html(WebRTC 播放页)/flv.min.js(flv.js v1.6.2 三方)/hmac-sha256.js
client/                  Node 端播放/推流脚本(play.mjs 播放、whip_push.mjs WHIP 推流)
scripts/                 fetch-deps.sh(拉三方) / build-deps.sh(编静态库) / build-openresty.sh(编 nginx)
docs/                    设计、评估、实现指南等文档(含中文设计/测试/编译文档)
run.sh                   sync / nginx / push / keep-push / stop / verify
```

## 依赖与版本

仓库**不内嵌任何 C 源码/二进制**(自研模块与三方依赖都不入库)。全部由 `scripts/fetch-deps.sh`
构建时按钉死 ref 拉取到 `scripts/_cache/`(gitignored), 再经 build 脚本解包/浅克隆编译:

| 依赖 | 形式 | 版本/来源 |
|---|---|---|
| nginx-rtc-module(自研 C 模块) | build 时浅克隆钉 tag | v0.1.0 (公开 DeguiLiu/nginx-rtc-module, MIT) |
| OpenResty | build 时拉取 | 1.31.1.1 (openresty.org 发行) |
| nginx-http-flv-module | build 时浅克隆钉 tag | v1.2.14 (winshining/nginx-http-flv-module) |
| Opus | build 时拉取 | 1.3.1 (xiph/opus) |
| libsrtp | build 时拉取 | 2.3.0 (ciscosystems/libsrtp) |
| FFmpeg 精简库 | build 时拉取 | aac 解码 + swresample + avutil (FFmpeg n6.1) |
| libavcodec/swresample/avutil | 见上 | 同上(音频 worker 用) |

唯一内嵌的第三方是运行时 web 资产 `deploy/nginx/html/flv.min.js`(flv.js v1.6.2, Apache-2.0),
播放页直接引用、保证离线完整; 来源见 `vendor/README.md`。

预编译产物统一进 `build/third/{include,lib}`(与旧 `/.../third` 同构)。模块的 addon `config`
(fetch 至 `build/src/nginx-rtc-module`)经 `NGX_RTC_THIRD` 定位——`build-openresty.sh` 已显式传入；
本机已有预编译库时可 `export NGX_RTC_THIRD=/path/to/third` 跳过重编。

## 构建

```bash
# 一键入口(推荐): 串起下面三步, 等价于 fetch → build-deps → build-openresty
scripts/setup.sh

# 0) 模块 host 单测在模块仓做(不需要 nginx/第三方):
#    git clone --depth 1 --branch v0.1.0 https://github.com/DeguiLiu/nginx-rtc-module
#    make -C nginx-rtc-module/test run_tests

# 1) 拉取全部依赖源: 自研模块/http-flv/opus 浅克隆钉 tag, openresty/libsrtp/ffmpeg 下载
#    (已缓存则秒过; github 被墙的主机先 export HTTPS_PROXY=http://127.0.0.1:7890)
scripts/fetch-deps.sh

# 2) 编静态库(opus/libsrtp/ffmpeg-lite) → build/third
scripts/build-deps.sh

# 3) 装配 openresty + nginx-rtc-module + nginx-http-flv-module 编译 → 输出前缀(默认 build/nginx)
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

- 模块 host 单测：在 [nginx-rtc-module](https://github.com/DeguiLiu/nginx-rtc-module) 仓
  `make -C test run_tests`(71 用例，纯 C 无 nginx 依赖)。
- 端到端：`./run.sh verify`(werift 客户端播放冒烟)。

## License

- 自研 C 模块：**MIT**(c) 2026 DeguiLiu, 见公开仓 [nginx-rtc-module](https://github.com/DeguiLiu/nginx-rtc-module)。
- 本仓(部署配置/Lua/播放页/client/docs/脚本)：缺省私有，发布前补 LICENSE。
- 编译依赖(OpenResty / nginx-http-flv-module / opus / libsrtp / FFmpeg)：构建时拉取, 各自保留上游 LICENSE。
- 唯一内嵌第三方运行时资产：`deploy/nginx/html/flv.min.js`(flv.js v1.6.2, Apache-2.0), 来源见 `vendor/README.md`。
