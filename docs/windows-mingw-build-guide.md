# Windows 编译指南（MSYS2 原生编译）

结论：Windows 版直播服务不能直接用 OpenResty 官方二进制包，必须重新编译
`nginx.exe`，把 `nginx-rtc-module` 和 `nginx-http-flv-module` 静态编入。
推荐路径是在 Windows 上用 MSYS2 MINGW64 原生编译（OpenResty 官方维护的
`util/build-win32.sh` 流程）。注意 Windows 版 nginx 无 UDP，只能做 RTMP →
HTTP-FLV/HLS/DASH，不含 WebRTC 媒体面。

## 为什么必须重新编译

OpenResty 1.31.1.1 官方发布提供了 Win32/Win64 二进制包，但：

- Windows 版 nginx 不支持动态加载 C 模块（无 `--add-dynamic-module`）。
- 官方二进制包不含 `nginx-rtc-module` 和 `nginx-http-flv-module`。

因此只能从源码把两个模块静态编入 `nginx.exe`。

## 范围：两个层次

Windows 兼容分两层：

1. **协议核心可移植性（已实现并验证）**：`nginx-rtc-module/src/` 下不依赖
   nginx 的纯 C 核心（`rtp/sdp/stun/rtcp/hsm/session_fsm/core/ring/avsync`）
   已在 MinGW 下编译通过，host 单测交叉编译为 `run_tests.exe` 可在 Windows
   x86-64 运行。复现命令见 `nginx-rtc-module/scripts/cross-win64-tests.sh`。
2. **完整 `nginx.exe` 直播服务（本指南主体）**：把四个 nginx 模块静态编入
   OpenResty 1.31.1.1 的 `nginx.exe`，在 Windows MSYS2 MINGW64 里原生编译。

## 环境准备

1. 安装 MSYS2：<https://www.msys2.org/>
2. 启动 **MSYS2 MINGW64** 快捷方式（不要用 MSYS2 MSYS）。
3. 验证环境，四项都要通过：

```bash
echo $MSYSTEM      # 应为 MINGW64
gcc -dumpmachine   # 应为 x86_64-w64-mingw32
make --version     # 应为 GNU Make
perl -v            # 应能输出版本
```

4. 把 `nginx-rtc-example` 仓库放到本机（`git clone` 或映射共享目录）。

## 一键编译

```bash
cd nginx-rtc-example
./scripts/build-win64-msys2.sh
```

脚本自动完成（对应 OpenResty 官方 `util/build-win32.sh` 流程 + 两个模块）：

1. pacman 安装 mingw64 工具链 + `libopus`/`libsrtp`（不再装 `libffmpeg`，见第 5 步）。
2. 下载 OpenResty 1.31.1.1 + OpenSSL 3.5.6 / zlib 1.3.2 / PCRE2 10.47 源码，并浅克隆 FFmpeg `n8.0`。
3. clone `nginx-rtc-module`（分支 `win32-compat`，非发行 tag；可用 `NGX_RTC_MODULE_SRC` 指向本地工作副本）+ `nginx-http-flv-module` `v1.2.14`。
4. 打 http-flv `int8_t` 补丁：把 `ngx_rtmp.h` 的 `#if (NGX_WIN32)` 收窄为 `#if (NGX_WIN32 && defined(_MSC_VER))`（MinGW 与 `stdint.h` 冲突）。
5. 用 n8.0 源码编一个只含 AAC 的**动态库** FFmpeg（`--enable-shared --disable-static`），避免 pacman 完整版拖入 x264/x265/libaom 等几十个编解码 DLL。
6. 把 FFmpeg 的 `*.dll.a` 与 pacman 的 `libopus.dll.a`/`libsrtp2.dll.a` 合成混合三方目录 `build-win64/third`。
7. `NGX_RTC_THIRD=build-win64/third` 跑 `configure`（OpenResty 官方 Windows 参数 + `--add-module`，含 `--with-select_module`、`-DFD_SETSIZE=1024`）。
8. `make && make install`，再从 `nginx.exe` 的导入表递归收集运行时 DLL 到安装前缀。

产物目录：`build-win64/openresty-win64/`（`nginx.exe`、`lua51.dll`、`conf/`、
`html/`、`lua/` 及媒体依赖 DLL）。

网络受限时先设置代理：

```bash
export https_proxy=http://127.0.0.1:7890
```

## 部署与运行

1. 用 Windows 专用配置覆盖安装目录：`deploy/win32/nginx-flv.conf` → `conf/nginx.conf`，并把
   `deploy/nginx/html/*` 拷入 `html/`。Windows 配置已去掉 WebRTC/stream 段，`worker_processes 1`、`rtmp_auto_push off`、推流/播放鉴权关闭。
2. 确认安装目录下 DLL 齐全（脚本已自动收集）。
3. Windows 防火墙只需放行 TCP 1935（RTMP 推流）与 TCP 18082（HTTP-FLV/HLS/DASH 播放）；Windows 版 nginx 无 UDP。
4. 启动：

```cmd
cd build-win64\openresty-win64
nginx.exe -p .
```

推流端连 RTMP 1935，播放端浏览器访问 `http://127.0.0.1:18082/flvplayer`（HTTP-FLV），或直接拉 `http://127.0.0.1:18082/live?app=live&stream=STREAM`、`/hls/STREAM.m3u8`、`/dash/STREAM.mpd`。也可用 `scripts/package-win64.sh` 出二进制 zip。

## 已知限制

- Windows 版 nginx 无 UDP，**WebRTC 媒体面（UDP 8000）不可用**；包只提供 RTMP → HTTP-FLV/HLS/DASH，且推流/播放鉴权关闭（见 `deploy/win32/README.md`）。
- Windows 版 nginx 仅支持 `select` 事件模型、单 worker，适合开发验证，不适合
  高并发生产（OpenResty 官方 README-windows 明确说明）。
- 并发连接默认上限 1024（MSYS2 脚本用 `--with-cc-opt='-DFD_SETSIZE=1024'`）。
- Linux MinGW 完整 `nginx.exe` 交叉构建当前阻塞：`build/lua-resty-signal-0.04/resty_signal.c` 使用 `SIGURG`，交叉目标下未定义（`error: 'SIGURG' undeclared`）。MSYS2 原生路径不受影响。
- `nginx-http-flv-module` 的 `int8_t` 补丁由脚本 clone 后自动打上；本仓库不
  内嵌第三方源码。
