# nginx-rtc-example

[nginx-rtc-module](https://github.com/DeguiLiu/nginx-rtc-module) 的部署示例——一个跑在 nginx 里的 C 模块，把 RTMP/WHIP 推流转成 WebRTC 低延迟直播。

[English](README.md)

模块跑在 OpenResty/nginx 里。RTMP 或 WHIP 推流进来后，模块转成 RTP/SRTP，走 UDP 直出给浏览器 WebRTC 播放；同一 origin 还同时提供 HTTP-FLV / HLS / DASH 多协议输出，并把每条推流录成 FLV 落盘。WebRTC 失败或超时会自动降级到 HTTP-FLV。

链路：

```
ffmpeg/WHIP → nginx (RTMP/HTTP) → 模块 (bridge → shm 媒体环 → SRTP/UDP) → 浏览器 WebRTC
```

## 仓库划分

C 源码在独立公开仓 [DeguiLiu/nginx-rtc-module](https://github.com/DeguiLiu/nginx-rtc-module)（MIT）。本仓只留组装件：deploy 配置 + Lua、播放页、client 脚本、构建运维脚本、文档。设计细节见 `docs/`（架构、多 worker shm 设计、评估报告等）。

## 目录

```
vendor/                 依赖说明（不内嵌源码，唯一内嵌三方资产见下）
deploy/nginx/
  conf/                 nginx.conf + *.lua（HMAC 鉴权、stats、flvplayer、观众计数）
  html/                 rtcplayer.html / flv.min.js（flv.js v1.6.2）/ hmac-sha256.js
client/                 play.mjs（播放）、whip_push.mjs（WHIP 推流）
scripts/                fetch-deps.sh / build-deps.sh / build-openresty.sh
docs/                   设计、评估、实现指南（中文）
run.sh                  sync / nginx / push / keep-push / stop / verify
```

## 依赖

仓库不内嵌任何 C 源码或二进制，模块和三方依赖都不入库。`scripts/fetch-deps.sh` 构建时按钉死 ref 拉进 `scripts/_cache/`（gitignored），再由 build 脚本解包/浅克隆编译。

| 依赖 | 形式 | 版本/来源 |
|---|---|---|
| nginx-rtc-module | build 时浅克隆 | v0.2.0（DeguiLiu/nginx-rtc-module，MIT） |
| OpenResty | build 时拉 tarball | 1.31.1.1（openresty.org） |
| nginx-http-flv-module | build 时浅克隆 | v1.2.14（winshining/nginx-http-flv-module） |
| Opus | build 时拉 tarball | 1.3.1（xiph/opus） |
| libsrtp | build 时浅克隆 | 2.3.0（ciscosystems/libsrtp） |
| FFmpeg（精简） | build 时浅克隆 | aac 解码 + swresample + avutil（FFmpeg n6.1） |

唯一内嵌的三方是 `deploy/nginx/html/flv.min.js`（flv.js v1.6.2，Apache-2.0），保留是为了播放页离线可用；来源见 `vendor/README.md`。

预编译产物进 `build/third/{include,lib}`。模块的 addon `config` 经 `NGX_RTC_THIRD` 定位，`build-openresty.sh` 已显式传入；本机已有预编译库时 `export NGX_RTC_THIRD=/path/to/third` 跳过重编。

## 构建

```bash
# 一键入口：fetch → build-deps → build-openresty
scripts/setup.sh

# 模块 host 单测在模块仓做（不需要 nginx/ffmpeg）：
#   git clone --depth 1 --branch v0.2.0 https://github.com/DeguiLiu/nginx-rtc-module
#   make -C nginx-rtc-module/test test

# 拉全部依赖源（已缓存秒过；github 被墙的主机先 export HTTPS_PROXY=http://127.0.0.1:7890）
scripts/fetch-deps.sh

# 编静态库（opus/libsrtp/ffmpeg）→ build/third
scripts/build-deps.sh

# 装配编译 openresty + 模块 + http-flv → build/nginx
OPENRESTY_PREFIX=$PWD/build/nginx scripts/build-openresty.sh
```

## 运行

```bash
OPENRESTY_PREFIX=/path/to/nginx-prefix ./run.sh nginx   # sync 配置 + 启动
./run.sh push          # ffmpeg 推 livestream（左上角烧北京秒表，便于目测延迟）
./run.sh keep-push     # 保活推流，ffmpeg 退出自动重启
./run.sh verify        # node client/play.mjs 冒烟播放
./run.sh stop
```

前缀解析：`OPENRESTY_PREFIX` → `build/nginx`，都没有则报错。`run.sh nginx|start` 先 sync：把 `deploy/nginx/{conf,html}` 拷进前缀并生成 `conf/nginx.rtc.conf`（候选 IP 自动探测或 `RTC_CANDIDATE_IP` 覆盖）。

### 端口

| 端口 | 用途 |
|---|---|
| 18082 HTTP | `/flvplayer`、`/rtcplayer.html`、`/rtc/v1/stats`、`/rtc/v1/flvcnt`、`/metrics` |
| 1935 RTMP | 推流 + HTTP-FLV 源 |
| 8000 UDP | WebRTC SRTP/SRTCP + ICE/STUN |

鉴权统一 HMAC token：`t`=过期秒，`sign`=base64url(HMAC-SHA256(`<app>/<stream>|t=<t>`))。演示 secret：`demo-secret-0123456789abcdef0123456789abcdef`。每流 secret 见 `deploy/nginx/conf/stream_keys.lua`。

### 录制

`application live` 里 `record all; record_path rec;` 把每条推流录到 `<prefix>/rec/<stream>-<timestamp>.flv`（只由实际收流 worker 写，auto_push 副本跳过）。文件不走 HTTP，直接从磁盘拉；`run.sh nginx` 会先建好目录。

### 播放器降级

`rtcplayer.html` 在 WebRTC `connectionState`/`iceConnectionState` 进入 `failed`，或 10 秒内没收到媒体时，自动跳 `/flvplayer?app=&stream=&key=`（同目标预填），弱网或连接失败时仍能播。

## 测试

- host 单测：在 [nginx-rtc-module](https://github.com/DeguiLiu/nginx-rtc-module) 里 `make -C test test`（纯 C，无 nginx）。
- 端到端：`./run.sh verify`（werift 播放冒烟）。

## License

- C 模块：MIT (c) 2026 DeguiLiu，见 [nginx-rtc-module](https://github.com/DeguiLiu/nginx-rtc-module)。
- 本仓（配置、Lua、页面、client、文档、脚本）：缺省私有，发布前补 LICENSE。
- 构建依赖：构建时拉取，各自保留上游 LICENSE。
- `deploy/nginx/html/flv.min.js`：flv.js v1.6.2，Apache-2.0；见 `vendor/README.md`。
