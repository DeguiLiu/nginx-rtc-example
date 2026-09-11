# Windows 编译指南（MSYS2 原生编译）

结论：Windows 版直播服务不能直接用 OpenResty 官方二进制包，必须重新编译
`nginx.exe`，把 `nginx-rtc-module` 和 `nginx-http-flv-module` 静态编入。
推荐路径是在 Windows 上用 MSYS2 MINGW64 原生编译（OpenResty 官方维护的
`util/build-win32.sh` 流程）；Linux 交叉编译见文末，协议核心已通、完整
`nginx.exe` 尚未闭环。注意 Windows 版 nginx 无 UDP，只能做 RTMP →
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

## 手动编译（不跑脚本）

等价步骤（脚本即把下面自动化）：

```bash
# 1. 依赖（ffmpeg 不装 pacman 完整版，见第 5 步）
pacman -S mingw-w64-x86_64-toolchain base-devel perl \
    mingw-w64-x86_64-opus mingw-w64-x86_64-libsrtp

# 2. 下载 OpenResty 源码并 cd 进去

# 3. 下载 OpenSSL/zlib/PCRE2 到 OpenResty 父目录，解压到 objs/lib

# 4. clone 两个模块（nginx-rtc-module 用 win32-compat 分支），打 http-flv int8_t 补丁

# 5. 编只含 AAC 的动态库 FFmpeg，再与 pacman 的 opus/libsrtp 导入库合成
#    build-win64/third/{lib,include}

# 6. configure（其余参数见官方 util/build-win32.sh）
NGX_RTC_THIRD=/path/to/build-win64/third ./configure \
    --with-cc=gcc --prefix=/c/nginx-win --sbin-path=nginx.exe \
    --add-module=/path/nginx-rtc-module \
    --add-module=/path/nginx-http-flv-module

# 7. make && make install
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

推流端连 RTMP 1935，播放端浏览器访问 `http://127.0.0.1:18082/flvplayer`（HTTP-FLV），或直接拉 `http://127.0.0.1:18082/live?app=live&stream=STREAM`、`/hls/STREAM.m3u8`、`/dash/STREAM.mpd`。也可用 `scripts/package-win64.sh` 出二进制 zip（见下）。

## Linux MinGW 交叉编译（无 Windows 机器也可出包）

没有 Windows 机器时，可以在 Linux 上用 MinGW 交叉编译出 `nginx.exe`。前提：本机已有 MinGW 交叉工具链（如 `$HOME/.local/mingw`）和 MSYS2 预编译包（openssl/pcre2/zlib/opus/libsrtp 的 `mingw64` 目录）。

现状：**协议核心交叉已走通**（`nginx-rtc-module/scripts/cross-win64-tests.sh` 出 `run_tests.exe`）；**完整 `nginx.exe` 交叉构建尚未闭环**，卡在 `lua-resty-signal` 的 `SIGURG` 未定义（见“已知限制”）。下面的补丁与 configure 参数来自一次成功的现场，重跑前先补上 `SIGURG` 守卫。

那次构建的现场记录（`/tmp` 树与日志清单、逐条原始命令）归档在 `docs/archive/win64-linux-crossbuild-notes.md`；下节的补丁与 configure 参数即由它整理而成，遇到本节没写到的细节可回到那份记录。

### 补丁（必须落在 `bundle/`，只改 `build/` 下次 configure 会被覆盖）

1. **windres wrapper**：已固化在 `scripts/win64-windres-wrapper.sh`——给 `windres` 补 `-D_WIN32` 与 MinGW include 路径（否则 OpenSSL 的 `.rc` 找不到 `winver.h`）。另需手工把 `x86_64-w64-mingw32-gcc-posix` 软链成无后缀的 `x86_64-w64-mingw32-gcc` 供 configure 调用（wrapper 脚本本身不建这个软链；脚本注释指向本指南，完整流程目前仍是手工步骤）。
2. **LuaJIT 交叉目标**：`bundle/LuaJIT-*/Makefile` 的 `TARGET_SYS?= $(HOST_SYS)` 会把交叉构建误判为宿主，改为 `TARGET_SYS= Windows`。
3. **LuaJIT 安装分支**：OpenResty `configure` 中 LuaJIT 安装分 `msys` 与 `else` 两支，交叉构建走 `else` 会去找宿主的 `src/luajit` 并报 `install: 对 'luajit' 调用 stat 失败`。把 LuaJIT 安装段内两处 `if ($platform eq 'msys')` 改为 `if ($platform eq 'msys' || $ENV{'NGX_RTC_CROSS_WIN32'})`，用 `NGX_RTC_CROSS_WIN32=1` 触发。LuaJIT 产物 `build/LuaJIT-*/src/{luajit.exe,lua51.dll,libluajit-5.1.dll.a}` 本身是齐的。
4. **LuaJIT 宿主工具**：configure 的 LuaJIT 编译行需 `HOST_CC=/usr/bin/gcc HOST_SYS=Linux TARGET_SYS=Windows`，否则 buildvm 无法在 Linux 上运行。
5. **lua-cjson / lua-redis-parser 链接顺序**：只在 `CJSON_LDFLAGS` 这类变量行追加 `-llua51` 不够（该变量位于 `$(OBJS)` 之前，静态链接顺序不对，符号仍找不到）。必须把 `-L<lua-root> -llua51` 追加到编译命令**末尾**（`$(CC) -o $@ ... $(OBJS) -L… -llua51`），`build/` 与 `bundle/` 两份 Makefile 都要改。Lua 导入库在 `build/luajit-root/liblua51.dll.a`（安装前缀根目录另有一份）。
6. **精简 FFmpeg**：MSYS2 完整 ffmpeg 是动态库，依赖 x264/x265/libaom 等几十个 DLL；本项目只用 AAC 解码，用 `scripts/build-ffmpeg-min-mingw.sh` 交叉编译成「只含 AAC」的静态库，再与 opus/libsrtp 导入库合成混合三方目录：

```sh
./scripts/build-ffmpeg-min-mingw.sh     # -> /tmp/winffmpeg-min/lib/{libavcodec,libavutil,libswresample}.a
THIRD=/tmp/winthird-min
mkdir -p "$THIRD/lib" "$THIRD/include"
cp /tmp/winffmpeg-min/lib/libavcodec.a /tmp/winffmpeg-min/lib/libavutil.a \
   /tmp/winffmpeg-min/lib/libswresample.a "$THIRD/lib/"
cp "$HOME/.local/mingw/mingw64/lib/libopus.dll.a" "$THIRD/lib/libopus.a"
cp "$HOME/.local/mingw/mingw64/lib/libsrtp2.dll.a" "$THIRD/lib/libsrtp2.a"
cp -r /tmp/winffmpeg-min/include/* "$THIRD/include/"
cp -r "$HOME/.local/mingw/mingw64/include/opus" "$THIRD/include/"
cp -r "$HOME/.local/mingw/mingw64/include/srtp2" "$THIRD/include/"
```

这样 `nginx.exe` 自包含 FFmpeg，运行时只需 5 个 DLL：`libopus-0.dll`、`libsrtp2-1.dll`、`libcrypto-3-x64.dll`、`libwinpthread-1.dll`、`lua51.dll`。

### configure 参数

```sh
export PATH=/path/winbin:$PATH HOST_CC=/usr/bin/gcc HOST_SYS=Linux TARGET_SYS=Windows
./configure --prefix=/path/winopenresty \
  --with-cc=x86_64-w64-mingw32-gcc --with-pcre-jit \
  --with-pcre=/path/openresty-build-deps/src/pcre2-10.47 \
  --with-zlib=/path/openresty-build-deps/src/zlib-1.3.2 \
  --with-openssl=/path/openresty-build-deps/src/openssl-3.5.6 \
  --crossbuild=win32 --sbin-path=nginx.exe \
  --add-module=/path/nginx-rtc-module \
  --add-module=/path/nginx-http-flv-module \
  --with-openssl-opt=-g --with-pcre-opt=-g --with-zlib-opt=-g \
  --with-stream --with-stream_ssl_module --with-stream_ssl_preread_module \
  --with-http_ssl_module
```

`configure` 是 Perl 脚本，必须 `./configure` 直接执行；`sh ./configure` 会因 `use` 语句报语法错误。模块新增源文件（如 `src/ngx_rtc_core_module.c`）不会出现在旧的 `objs/Makefile` 里，改动后必须重跑 configure。交叉编译版 `nginx.exe` 依赖 `bcrypt` 等 Windows 系统 API，若链接报 `undefined reference to BCrypt*`，在 `objs/Makefile` 的链接行补 `-lbcrypt`。

### 出包

```bash
NGINX_DIR=/path/winopenresty ./scripts/package-win64.sh   # -> dist/nginx-rtc-win64.zip
```

`package-win64.sh` 用 `deploy/win32/nginx-flv.conf` 覆盖 `conf/nginx.conf`，拷入 `deploy/nginx/html`、`start.bat`/`stop.bat`/`push_test.bat`/`README.md`，并收集 `*.dll`、`lua`、`lualib`（可选 `FFMPEG_EXE` 打为 `tools/ffmpeg.exe`）。Windows nginx 无 UDP，包是 auth-free HTTP-FLV/HLS/DASH 专用；重打的收益是版本可追溯，不改变 Windows 侧行为。

## 已知限制

- Windows 版 nginx 无 UDP，**WebRTC 媒体面（UDP 8000）不可用**；包只提供 RTMP → HTTP-FLV/HLS/DASH，且推流/播放鉴权关闭（见 `deploy/win32/README.md`）。
- Windows 版 nginx 仅支持 `select` 事件模型、单 worker，适合开发验证，不适合
  高并发生产（OpenResty 官方 README-windows 明确说明）。
- 并发连接默认上限 1024（MSYS2 脚本用 `--with-cc-opt='-DFD_SETSIZE=1024'`）。
- Linux MinGW 完整 `nginx.exe` 交叉构建当前阻塞：`build/lua-resty-signal-0.04/resty_signal.c` 使用 `SIGURG`，交叉目标下未定义（`error: 'SIGURG' undeclared`），需为该文件补 Windows 侧定义/守卫后才能继续 `make`。
- `nginx-http-flv-module` 的 `int8_t` 补丁由脚本 clone 后自动打上；本仓库不
  内嵌第三方源码。
