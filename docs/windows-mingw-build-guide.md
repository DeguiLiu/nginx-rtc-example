# Windows MinGW 编译指南

结论：Windows 版直播服务不能直接使用 OpenResty 预编译包，必须重新编译
`nginx.exe`，把 `nginx-rtc-module` 和 `nginx-http-flv-module` 静态编入。
本指南以 OpenResty 1.31.1.1 源码为基准，与 `nginx-rtc-example` 的 Linux
构建版本保持一致。

## 范围：两个层次

Windows 兼容实际分两层，本指南下半部分的 `nginx.exe` 交叉编译属于第二层。

1. **协议核心可移植性（已实现并验证）**：`nginx-rtc-module/src/` 下不依赖
   nginx 的纯 C 核心（`rtp/sdp/stun/rtcp/hsm/session_fsm/core/ring/avsync`）
   已在 MinGW 下编译通过，host 单测交叉编译为 `run_tests.exe` 可在 Windows
   x86-64 运行。复现命令见 `nginx-rtc-module/scripts/cross-win64-tests.sh`，
   产物为 `nginx-rtc-module/dist/win64/`（`run_tests.exe` + 两个运行时 DLL）。
2. **完整 `nginx.exe` 直播服务（未完全跑通）**：把四个 nginx 模块静态编入
   OpenResty 1.31.1.1 的 `nginx.exe`。该路径依赖多、较脆弱，当前已知在
   OpenSSL 的 `windres` 资源编译处仍有坑，属于可选深化，不是本轮验收项。

## 背景

OpenResty 1.31.1.1 只发布源码和 Linux 包，没有 Windows 二进制包。官方最新
Windows 二进制包是 1.29.2.1，但 Windows 版 nginx 不能动态加载 C 模块，因此
不能把两个自研 addon 塞进现成 `nginx.exe`。

Windows OpenResty 使用 select 事件模型，默认单 worker，适合开发和验证，
不适合高并发生产。当前项目的媒体面使用 nginx stream UDP，Windows
OpenResty/nginx 1.31.1.1 已带 UDP 支持，但整条链路仍需要在 Windows 上实际
验证。

## 构建路径

推荐优先在 Windows 上使用 MSYS2 MINGW64 原生构建，OpenResty 官方维护的
`util/build-win32.sh` 已经覆盖 LuaJIT、OpenSSL、zlib、PCRE2。若没有 Windows
环境，也可以在 Linux 上用 MinGW 交叉编译，下面记录的是后一种路径。

## 交叉编译环境准备

以下命令不需要 sudo，工具链和依赖都安装到用户目录。

```sh
export WORK=/home/dgliu/workspace/webrtc
export MINGW_PREFIX=$HOME/.local/mingw
mkdir -p /tmp/mingw-debs

cd /tmp/mingw-debs
apt-get download \
  gcc-mingw-w64-base \
  gcc-mingw-w64-x86-64-posix-runtime \
  gcc-mingw-w64-x86-64-posix \
  binutils-mingw-w64-x86-64 \
  mingw-w64-x86-64-dev \
  mingw-w64-common

rm -rf "$MINGW_PREFIX"
mkdir -p "$MINGW_PREFIX"
for d in *.deb; do
  dpkg-deb -x "$d" "$MINGW_PREFIX"
done
```

生成 `x86_64-w64-mingw32-gcc` 这个无后缀入口，便于 LuaJIT 和 nginx 调用。

```sh
mkdir -p /tmp/winbin
ln -sf "$MINGW_PREFIX/usr/bin/x86_64-w64-mingw32-gcc-posix" \
  /tmp/winbin/x86_64-w64-mingw32-gcc
```

## 下载 OpenResty 1.31.1.1 源码

```sh
cd /tmp
curl -fsSL -o openresty-1.31.1.1.tar.gz \
  https://openresty.org/download/openresty-1.31.1.1.tar.gz
tar xzf openresty-1.31.1.1.tar.gz
cd openresty-1.31.1.1
```

网络受限时使用本地代理，例如 `curl --proxy http://127.0.0.1:7890 ...`。

## 交叉编译必需的 OpenResty 源码补丁

OpenResty 源码默认假设在 MSYS2 内构建。Linux 交叉编译需要以下改动，改动范围
仅限临时源码树，不改变模块仓库。

1. 在 `configure` 的 LuaJIT `gmake` 调用中加入 `HOST_CC` 和 `HOST_SYS`，
   防止主机工具被交叉编译器误编译。

```perl
shell "${make} -j$cores$extra_opts HOST_CC=/usr/bin/gcc HOST_SYS=Linux TARGET_SYS=Windows PREFIX=$luajit_prefix", $dry_run;
```

2. 在同一文件安装 LuaJIT 产物时，把生成的导入库复制为 `liblua51.dll.a`，
   否则 `ngx_lua` 的 `-llua51` 探测失败。

```perl
shell "install -m 0755 src/luajit.exe src/lua51.dll $lib/"
      . " && install -m 0644 src/libluajit-5.1.dll.a $lib/liblua51.dll.a",
      $dry_run;
```

3. 修改 `bundle/nginx-1.31.1/auto/init`，让 win32 交叉配置检查
   `autotest.exe` 而不是 `autotest`。

```sh
if [ ".$NGX_PLATFORM" = ".win32" ]; then
    NGX_AUTOTEST=$NGX_OBJS/autotest.exe
else
    NGX_AUTOTEST=$NGX_OBJS/autotest
fi
```

4. 在生成 `build/nginx-1.31.1/objs/Makefile` 后，手工修正 PCRE2 和
   OpenSSL 的交叉编译规则。PCRE2 加 `--host`，OpenSSL 使用
   `Configure mingw64`。

```make
./configure --host=x86_64-w64-mingw32 --disable-shared --enable-jit
```

```make
./Configure mingw64 no-shared no-threads -g \
  --prefix=/tmp/openresty-build-deps/src/openssl-3.5.6/.openssl
```

5. 若 `make` 阶段 `lua-cjson` 或 `lua-redis-parser` 报 Lua 符号未定义，
   把动态库链接命令中的对象文件放到 `-llua51` 之前。

```make
# lua-cjson
$(CC) -o $@ $(LDFLAGS) $(OBJS) $(CJSON_LDFLAGS)

# lua-redis-parser
$(CC) -o $@ $^ $(LDFLAGS)
```

## 下载 Windows 第三方依赖

模块需要 libavcodec、libavutil、libswresample、libopus、libsrtp2。这里使用
MSYS2 的预编译包，比交叉编译 FFmpeg 更简单。

```sh
cd /tmp
for p in \
  mingw-w64-x86_64-ffmpeg-8.0.1-7-any.pkg.tar.zst \
  mingw-w64-x86_64-opus-1.6.1-1-any.pkg.tar.zst \
  mingw-w64-x86_64-libsrtp-2.8.0-1-any.pkg.tar.zst; do
  curl -fsSL --proxy http://127.0.0.1:7890 \
    "https://repo.msys2.org/mingw/mingw64/$p" -o "$p"
  tar --zstd -xf "$p" -C "$MINGW_PREFIX"
done
```

提取后，`$MINGW_PREFIX/mingw64` 下应有 `include` 和 `lib`，这正是
`nginx-rtc-module/config` 中 `NGX_RTC_THIRD` 期望的目录结构。

`nginx-http-flv-module` 的 `ngx_rtmp.h` 在 MinGW 下与 `stdint.h` 的 `int8_t`
冲突，`fetch-deps.sh` 拉取后需把第 30 行附近的守卫改成：

```c
#if (NGX_WIN32 && defined(_MSC_VER))
typedef __int8              int8_t;
typedef unsigned __int8     uint8_t;
#endif
```

该文件位于 git 忽略的 `build/src/nginx-http-flv-module/ngx_rtmp.h`，每次
重新 `fetch-deps.sh` 后都要重打一次这个补丁（本仓库不内嵌第三方源码）。

## 下载并解压 PCRE2、zlib、OpenSSL 源码

nginx 的 `--with-pcre`、`--with-zlib`、`--with-openssl` 采用源码方式，所以
还需要下载对应源码。

```sh
mkdir -p /tmp/openresty-build-deps/src
cd /tmp/openresty-build-deps/src
curl -fsSL -o openssl-3.5.6.tar.gz \
  https://github.com/openssl/openssl/releases/download/openssl-3.5.6/openssl-3.5.6.tar.gz
curl -fsSL -o zlib-1.3.2.tar.gz \
  https://zlib.net/zlib-1.3.2.tar.gz
curl -fsSL -o pcre2-10.47.tar.gz \
  https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.gz

tar xzf openssl-3.5.6.tar.gz
tar xzf zlib-1.3.2.tar.gz
tar xzf pcre2-10.47.tar.gz
```

OpenSSL 3.5.6 需要打上 OpenResty 自带的 `openssl-3.5.5-sess_set_get_cb_yield.patch`。

```sh
cd openssl-3.5.6
patch -p1 < /tmp/openresty-1.31.1.1/patches/openssl-3.5.5-sess_set_get_cb_yield.patch
```

## 配置

```sh
cd /tmp/openresty-1.31.1.1
export PATH=/tmp/winbin:/home/dgliu/.local/mingw/usr/bin:/usr/bin:/bin
unset CROSS
export CC=x86_64-w64-mingw32-gcc
export TARGET_SYS=Windows
export NGX_RTC_THIRD=$MINGW_PREFIX/mingw64

./configure \
  --platform=msys \
  --prefix=/tmp/winopenresty \
  --with-cc=x86_64-w64-mingw32-gcc \
  --with-cc-opt='-DFD_SETSIZE=1024' \
  --with-pcre-jit \
  --with-pcre=/tmp/openresty-build-deps/src/pcre2-10.47 \
  --with-zlib=/tmp/openresty-build-deps/src/zlib-1.3.2 \
  --with-openssl=/tmp/openresty-build-deps/src/openssl-3.5.6 \
  --crossbuild=win32 \
  --sbin-path=nginx.exe \
  --add-module="$WORK/nginx-rtc-module" \
  --add-module="$WORK/nginx-rtc-example/build/src/nginx-http-flv-module" \
  --without-http_rds_json_module \
  --without-http_rds_csv_module \
  --without-lua_rds_parser
```

`--platform=msys` 是 OpenResty 的测试参数，用来强制采用 Windows/msys 的安装
布局；`--crossbuild=win32` 是 nginx 的交叉编译开关。两个必须同时使用。

## 编译与安装

```sh
make -j4
make install
```

产物默认位于 `/tmp/winopenresty/nginx.exe`，同时会生成 `lua51.dll`、
`libwinpthread-1.dll`、OpenSSL 等运行时文件。

## 部署到 Windows

1. 把 `/tmp/winopenresty` 整体复制到 Windows。
2. 用 `nginx-rtc-example` 的 `deploy/nginx/conf`、`deploy/nginx/html` 覆盖
   `conf` 和 `html`。
3. 在 CMD 或 PowerShell 中进入该目录执行 `nginx.exe`。
4. 用浏览器访问播放页，推流端连接 RTMP 1935，播放端使用 WebRTC UDP 8000。

Windows 版 nginx 默认单 worker，`select` 事件模型，监听 1024 连接限制。
若 WebRTC 黑屏，优先检查 Windows 防火墙是否放行 UDP 8000 入站，以及 VPN 是否
改变了默认路由。

## 已知问题

`make` 阶段最容易出现的三类错误：

1. `host/minilua.exe` 或 `HOSTCC` 使用了 MinGW 编译器，说明 `HOST_CC` 未指向
   `/usr/bin/gcc`。
2. `cannot run C compiled programs`，说明 PCRE2 配置缺少 `--host`。
3. `x86_64-w64-mingw32-x86_64-w64-mingw32-gcc`，说明 OpenSSL `Configure`
   已经带了工具前缀，不要再传 `--cross-compile-prefix`。
