# Windows 编译指南（MSYS2 原生编译）

结论：Windows 版直播服务不能直接用 OpenResty 官方二进制包，必须重新编译
`nginx.exe`，把 `nginx-rtc-module` 和 `nginx-http-flv-module` 静态编入。
正确路径是在 Windows 上用 MSYS2 MINGW64 原生编译（OpenResty 官方维护的
`util/build-win32.sh` 流程），而不是在 Linux 上交叉编译。

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

1. pacman 安装 mingw64 工具链 + FFmpeg/opus/libsrtp 第三方库。
2. 下载 OpenResty 1.31.1.1 + OpenSSL 3.5.6 / zlib 1.3.2 / PCRE2 10.47 源码。
3. clone `nginx-rtc-module` + `nginx-http-flv-module`。
4. 打 http-flv `int8_t` 补丁（MinGW 与 `stdint.h` 冲突）。
5. `configure`（官方参数 + `--add-module` + `NGX_RTC_THIRD=/mingw64`）。
6. `make && make install`，并收集 FFmpeg/opus/libsrtp/pthread 运行时 DLL。

产物目录：`build-win64/openresty-win64/`（`nginx.exe`、`lua51.dll`、`conf/`、
`html/`、`lua/` 及媒体依赖 DLL）。

网络受限时先设置代理：

```bash
export https_proxy=http://127.0.0.1:7890
```

## 手动编译（不跑脚本）

等价步骤（脚本即把下面自动化）：

```bash
# 1. 依赖
pacman -S mingw-w64-x86_64-toolchain base-devel perl \
    mingw-w64-x86_64-ffmpeg mingw-w64-x86_64-opus mingw-w64-x86_64-libsrtp

# 2. 下载 OpenResty 源码并 cd 进去

# 3. 下载 OpenSSL/zlib/PCRE2 到 OpenResty 父目录，解压到 objs/lib

# 4. clone 两个模块，打 http-flv int8_t 补丁

# 5. configure（其余参数见官方 util/build-win32.sh）
NGX_RTC_THIRD=/mingw64 ./configure \
    --with-cc=gcc --prefix=/c/nginx-win --sbin-path=nginx.exe \
    --add-module=/path/nginx-rtc-module \
    --add-module=/path/nginx-http-flv-module

# 6. make && make install
```

## 部署与运行

1. 把本仓库 `deploy/nginx/conf`、`deploy/nginx/html` 覆盖到安装目录的
   `conf/`、`html/`。
2. 确认安装目录下 DLL 齐全（脚本已自动收集）。
3. Windows 防火墙放行 UDP 8000（媒体面）、TCP 1935（RTMP）、TCP 1985（信令）。
4. 启动：

```bash
cd build-win64/openresty-win64
./nginx.exe -p .
```

推流端连 RTMP 1935，播放端浏览器访问 `html/rtcplayer.html`（WebRTC UDP 8000）。

## 已知限制

- Windows 版 nginx 仅支持 `select` 事件模型、单 worker，适合开发验证，不适合
  高并发生产（OpenResty 官方 README-windows 明确说明）。
- 并发连接默认上限 1024。
- WebRTC 黑屏优先检查防火墙 UDP 8000 入站、VPN 是否改变默认路由。
- `nginx-http-flv-module` 的 `int8_t` 补丁由脚本 clone 后自动打上；本仓库不
  内嵌第三方源码。
