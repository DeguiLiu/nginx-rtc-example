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

## Linux MinGW 交叉编译（无 Windows 机器也可出包）

没有 Windows 机器时，可以在 Linux 上用 MinGW 交叉编译出同样的 `nginx.exe`。
这条路径已实测走通，但比 MSYS2 原生编译多几处手工补丁，适合 CI 或一次性出包。
前提：本机已有 MinGW 交叉工具链（如 `$HOME/.local/mingw`）和 MSYS2 预编译包
（openssl/pcre2/zlib/opus/libsrtp 的 `mingw64` 目录）。

### 关键补丁一：OpenSSL windres 找不到 winver.h

MinGW 的 `windres` 编译 OpenSSL 的 `.rc` 资源文件时，默认不继承 gcc 的
include 搜索路径，也不定义 `_WIN32`。用一个 wrapper 补齐两处：

```sh
mkdir -p /tmp/winbin
cat > /tmp/winbin/windres <<'EOF'
#!/bin/sh
exec "$HOME/.local/mingw/usr/bin/x86_64-w64-mingw32-windres" \
    -D_WIN32 \
    -I"$HOME/.local/mingw/usr/x86_64-w64-mingw32/include" \
    "$@"
EOF
chmod +x /tmp/winbin/windres
export PATH=/tmp/winbin:$PATH
```

同时把 `x86_64-w64-mingw32-gcc-posix` 链成无后缀入口，供 OpenResty/nginx 调用：

```sh
ln -sf "$HOME/.local/mingw/usr/bin/x86_64-w64-mingw32-gcc-posix" \
    /tmp/winbin/x86_64-w64-mingw32-gcc
```

### 关键补丁二：完整版 FFmpeg 拖入 40+ 个 DLL

MSYS2 的完整 ffmpeg 是动态库，依赖 x264/x265/libaom 等几十个编解码 DLL。
本项目只用 AAC 解码，交叉编译成「只含 AAC」的静态库即可。命令已固化为
[scripts/build-ffmpeg-min-mingw.sh](/home/dgliu/workspace/webrtc/nginx-rtc-example/scripts/build-ffmpeg-min-mingw.sh)：

```sh
./scripts/build-ffmpeg-min-mingw.sh
```

产出 `/tmp/winffmpeg-min/lib/{libavcodec,libavutil,libswresample}.a`。
把这几个静态库和 opus/libsrtp 的动态导入库合成一个混合第三方目录：

```sh
THIRD=/tmp/winthird-min
mkdir -p "$THIRD/lib" "$THIRD/include"
cp /tmp/winffmpeg-min/lib/libavcodec.a \
   /tmp/winffmpeg-min/lib/libavutil.a \
   /tmp/winffmpeg-min/lib/libswresample.a "$THIRD/lib/"
cp "$HOME/.local/mingw/mingw64/lib/libopus.dll.a" "$THIRD/lib/libopus.a"
cp "$HOME/.local/mingw/mingw64/lib/libsrtp2.dll.a" "$THIRD/lib/libsrtp2.a"
cp -r /tmp/winffmpeg-min/include/* "$THIRD/include/"
cp -r "$HOME/.local/mingw/mingw64/include/opus" "$THIRD/include/"
cp -r "$HOME/.local/mingw/mingw64/include/srtp2" "$THIRD/include/"
```

这样 `nginx.exe` 自包含 FFmpeg，运行时只需 5 个 DLL：`libopus-0.dll`、
`libsrtp2-1.dll`、`libcrypto-3-x64.dll`、`libwinpthread-1.dll`、`lua51.dll`。

### 交叉编译流程

1. 下载 OpenResty 1.31.1.1 + OpenSSL/zlib/PCRE2 源码，解压。
2. 给 OpenResty 源码打 5 处交叉编译补丁（LuaJIT `HOST_CC`、`liblua51.dll.a`
   安装、`auto/init` 的 `autotest.exe`、lua-cjson / lua-redis-parser 链接顺序）。
3. 交叉编译精简 FFmpeg，合成混合第三方目录，应用 windres wrapper。
4. 用 `NGX_RTC_THIRD=$THIRD` 跑 OpenResty `configure`（带 `--crossbuild=win32`）
   + `make` + `make install`。
5. 收集 5 个运行时 DLL，复制 `deploy/nginx/{conf,html}`，把 `worker_processes`
   改成 1，`rtmp_auto_push off`，打包分发。

交叉编译版 `nginx.exe` 依赖 `bcrypt` 等 Windows 系统 API，因此链接行需补
`-lbcrypt`；若 `make` 报 `undefined reference to BCrypt*`，在 `objs/Makefile`
的链接行加 `-lbcrypt` 即可。

## 已知限制

- Windows 版 nginx 仅支持 `select` 事件模型、单 worker，适合开发验证，不适合
  高并发生产（OpenResty 官方 README-windows 明确说明）。
- 并发连接默认上限 1024。
- WebRTC 黑屏优先检查防火墙 UDP 8000 入站、VPN 是否改变默认路由。
- `nginx-http-flv-module` 的 `int8_t` 补丁由脚本 clone 后自动打上；本仓库不
  内嵌第三方源码。
