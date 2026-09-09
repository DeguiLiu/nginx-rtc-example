# vendor — 第三方依赖说明

本仓库**不内嵌任何编译源码/二进制**(自研模块与三方依赖都不入库)。全部由
`../scripts/fetch-deps.sh` 构建时按钉死 ref 拉取到 `scripts/_cache/`(gitignored), 再经
`build-deps.sh` / `build-openresty.sh` 解包或浅克隆编译。改依赖版本时同步改 `fetch-deps.sh`
的 ref 与本文件:

| 依赖 | 用途 | 钉住 ref | 来源 |
|---|---|---|---|
| nginx-rtc-module(自研) | RTC 核心 + 4 个注册模块, 随 nginx 同编 | tag v0.2.0 | DeguiLiu/nginx-rtc-module(MIT, 公开) |
| OpenResty | 宿主 nginx | 1.31.1.1 | openresty.org |
| nginx-http-flv-module | HTTP-FLV / RTMP 引擎, 与其 RTMP 核心同编 | tag v1.2.14 | winshining/nginx-http-flv-module |
| Opus | libopus.a(Opus 编码) | v1.3.1 | xiph/opus |
| libsrtp | libsrtp2.a(SRTP) | v2.3.0 | cisco/libsrtp |
| FFmpeg 精简库 | libavcodec/swresample/avutil(aac 解码) | n6.1 | FFmpeg/FFmpeg |

> 网络: github.com 被 DNS 劫持的主机, 拉取前先
> `export HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890`。

## 内嵌的第三方运行时资产(非编译源码)

`../deploy/nginx/html/flv.min.js` — **flv.js v1.6.2** 发行版 dist (bilibili/flv.js, Apache-2.0),
HTTP-FLV 播放页直接引用, 与 CDN 引库同理, 保留入库以保证离线页面完整。更新时自
https://github.com/bilibili/flv.js/releases 取对应发行版 dist 覆盖, 并同步本文件。
