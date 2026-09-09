# vendor — 源码依赖

收录构建 rtc-gateway 所需的小型第三方源码，避免在线拉取与"漂移"。均为**上游源码裁剪拷贝**
(去掉 `.git`、`samples/` 媒体素材与 in-tree 构建产物)；大件(OpenResty、libsrtp、FFmpeg)由
`../scripts/fetch-deps.sh` 在构建时按固定版本拉取。

| 目录 | 组件 | 版本 | 上游 | 本仓库保留 |
|---|---|---|---|---|
| `nginx-http-flv-module/` | HTTP-FLV / RTMP 引擎 | v1.2.14-2-g2ad3dab | https://github.com/winshining/nginx-http-flv-module | 源码(`config`, `*.c/*.h`, dash/hls/doc, LICENSE)；已删 `.git/` 与 `samples/` |
| `opus-1.3.1/` | Opus 编解码源码 | 1.3.1 | https://github.com/xiph/opus | 源码(configure/autotools + celt/silk/src)；已删 in-tree 构建物与根 `config.h` |

更新方式：从上游按上表版本拉取后按同样的裁剪规则替换目录内容，并更新上表与本 README。
