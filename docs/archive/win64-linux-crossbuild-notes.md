# Windows 包交叉编译现场记录（Linux + MinGW）

> 记录时间：2026-09-11。来源：整理 2026-09-10 那次成功的交叉构建在 `/tmp` 留下的现场与日志。
> 目的：让"在 Linux 上出 Windows 包"这条路径可复现，而不是每次照文档手敲。

## 1 为什么需要这份记录

- `scripts/build-win64-msys2.sh` 只能在 Windows 的 MSYS2 MINGW64 里跑（脚本会检查
  `MSYSTEM != MINGW64` 并直接退出），Linux 上没有原生入口。
- 2026-09-10 那次是在 Linux 上用 MinGW 手敲命令完成的，**没有留下脚本**；现场只剩
  `/tmp` 下的构建树、依赖和日志。一次 `./configure` 就会用 `bundle/` 覆盖 `build/`，
  把配好的 `objs` 树清掉（本记录写成时它已被清掉），所以必须脚本化。

## 2 `/tmp` 现场盘点

注意：本机 `/tmp` 是符号链接（`/tmp -> /home/ci/sdb1/jenkins_workspace/jenkins_data_tmp`），
`find /tmp` 会得到**假阴性**，必须用 `find -L /tmp`。

| 路径 | 内容 |
|---|---|
| `/tmp/openresty-1.31.1.1` | OpenResty 源码树；`configure` 已按下面第 3 节打过补丁 |
| `/tmp/openresty-build-deps/src/{pcre2-10.47,zlib-1.3.2,openssl-3.5.6}` | 依赖源码 |
| `/tmp/winbin` | windres wrapper（本仓库 `scripts/win64-windres-wrapper.sh`）+ `x86_64-w64-mingw32-gcc` 软链 |
| `/tmp/winffmpeg-min`、`/tmp/winthird-min`、`/tmp/winthird-dll` | 精简 FFmpeg 静态库与合并后的第三方目录 |
| `/tmp/winopenresty` | 安装前缀（`nginx.exe`），即 `package-win64.sh` 的 `NGINX_DIR` |
| `/tmp/openresty-win-configure*.log`、`/tmp/*win*make*.log` | 构建日志，含完整命令行 |

`nginx.exe` 全 `/tmp` 只有两处：`/tmp/winopenresty/nginx.exe`（本项目）与
`/tmp/openresty-win64/openresty-1.29.2.1-win64/nginx.exe`（官方预编译发行版，无关）。

## 3 跨编译必需的补丁（都要打在会被重生成之前的位置）

1. **windres wrapper**：见 `scripts/win64-windres-wrapper.sh`；另把
   `x86_64-w64-mingw32-gcc-posix` 软链成 `x86_64-w64-mingw32-gcc` 供 configure 调用。
2. **LuaJIT 交叉目标**：`bundle/LuaJIT-*/Makefile` 的 `TARGET_SYS?= $(HOST_SYS)` 会把
   交叉构建误判为宿主，改为 `TARGET_SYS= Windows`。注意 `configure` 每次用 `bundle/`
   覆盖 `build/`，所以**补丁必须落在 `bundle/`**，只改 `build/` 下次即失效。
3. **LuaJIT 安装分支**：OpenResty 的 `configure` 里，LuaJIT 安装分两支——`msys` 支拷
   `src/luajit.exe`、`src/lua51.dll`、`src/libluajit-5.1.dll.a`；`else` 支执行
   `make install`，在交叉构建下会去找宿主的 `src/luajit` 而失败
   （报 `install: 对 'luajit' 调用 stat 失败`）。Linux 上交叉构建走的是 `else` 支，
   需要让这两处安装分支（`configure` 中 `if ($platform eq 'msys')` 的两处，
   位于 LuaJIT 安装段内）在交叉构建时也走 `msys` 支。产物本身是齐的：
   `build/LuaJIT-*/src/{luajit.exe,lua51.dll,libluajit-5.1.dll.a}` 均已生成。
4. **LuaJIT 宿主工具**：configure 的 LuaJIT 编译行需要
   `HOST_CC=/usr/bin/gcc HOST_SYS=Linux TARGET_SYS=Windows`（2026-09-10 的现场里
   这三项已硬编码在 `configure` 的该行上），否则 buildvm 无法在 Linux 上运行。
5. **精简 FFmpeg**：`scripts/build-ffmpeg-min-mingw.sh` 产出的静态库，再与
   `~/.local/mingw/mingw64/lib/{libopus.dll.a,libsrtp2.dll.a}` 合成混合 third 目录；
   否则 MSYS2 的完整 ffmpeg 会拖入 40+ 个 DLL。

## 4 configure 参数（从 2026-09-10 日志恢复，须原样使用）

```sh
export PATH=/tmp/winbin:$PATH HOST_CC=/usr/bin/gcc HOST_SYS=Linux TARGET_SYS=Windows
cd /tmp/openresty-1.31.1.1
./configure --prefix=/tmp/winopenresty \
  --with-cc=x86_64-w64-mingw32-gcc --with-pcre-jit \
  --with-pcre=/tmp/openresty-build-deps/src/pcre2-10.47 \
  --with-zlib=/tmp/openresty-build-deps/src/zlib-1.3.2 \
  --with-openssl=/tmp/openresty-build-deps/src/openssl-3.5.6 \
  --crossbuild=win32 --sbin-path=nginx.exe \
  --add-module="$PWD/../nginx-rtc-module" \
  --add-module="$PWD/../nginx-rtc-example/build/src/nginx-http-flv-module" \
  --with-openssl-opt=-g --with-pcre-opt=-g --with-zlib-opt=-g \
  --with-stream --with-stream_ssl_module --with-stream_ssl_preread_module \
  --with-http_ssl_module
```

说明：`configure` 是 Perl 脚本，必须直接执行（`./configure`），用 `sh ./configure`
会因 `use` 语句报语法错误。

## 5 已知坑

- **必须重跑 configure**：模块新增源文件（如 `src/ngx_rtc_core_module.c`）不会出现在旧的
  `objs/Makefile` 里，不重跑 configure 会链接失败。
- **链接阶段可能需要 `-lbcrypt`**：交叉编译版 `nginx.exe` 依赖 `bcrypt` 等 Windows API，
  若报 `undefined reference to BCrypt*`，在 `objs/Makefile` 链接行补 `-lbcrypt`。
- **configure 会清 `build/`**：它从 `bundle/` 复制生成 `build/`，因此已编译的
  `build/nginx-*/objs` 会丢失；改动补丁后要预留全量重编的时间。
- **不要动** `/tmp/winopenresty` 与 `dist/`：那是现有唯一可用产物。

## 6 出包

```sh
cd nginx-rtc-example
NGINX_DIR=/tmp/winopenresty ./scripts/package-win64.sh   # 产出 dist/nginx-rtc-win64.zip
```

核验包里确实是新代码（`gone from session_list` 是本项目 2026-09-11 引入的字面量）：

```sh
strings dist/win64-package/nginx.exe | grep -c 'gone from session_list'   # 应 > 0
```

Windows nginx 无 UDP，包是 auth-free HTTP-FLV 专用；重打的收益是版本可追溯，
不是改变 Windows 侧行为。

## 7 2026-09-11 续编进展（现场已搬到工程目录）

构建现场已从 `/tmp` 搬到 `build-win64/`（`openresty-1.31.1.1`、`openresty-build-deps`、
`winbin`、`winffmpeg-min`、`winthird-min`、`winopenresty`），不再在 `/tmp` 里编译。

已解决：

1. **LuaJIT 安装分支**：`openresty-1.31.1.1/configure` 中两处
   `if ($platform eq 'msys')`（LuaJIT 安装段第 820、855 行）改为
   `if ($platform eq 'msys' || $ENV{'NGX_RTC_CROSS_WIN32'})`，并用
   `NGX_RTC_CROSS_WIN32=1` 触发。configue 通过（退出码 0），新模块文件
   `src/ngx_rtc_core_module.c` 已出现在 `build/nginx-1.31.1/objs/Makefile`（命中 6 处）。
2. **lua-cjson / lua-redis-parser 链接**：只在 `CJSON_LDFLAGS` 这类变量行追加
   `-llua51` **不够**（该变量位于 `$(CC) ... $(OBJS)` 的 `$(OBJS)` **之前**，静态链接
   顺序不对，符号仍找不到）。必须把 `-L<lua-root> -llua51` 追加到**编译命令末尾**，
   即 `$(CC) -o $@ ... $(OBJS) -L… -llua51`；`build/` 与 `bundle/` 两份 Makefile 都要改。
   Lua 导入库位置：`build/luajit-root/liblua51.dll.a`（另有一份在安装前缀根目录）。

当前阻塞：

3. **lua-resty-signal**：`build/lua-resty-signal-0.04/resty_signal.c:136`
   使用 `SIGURG`，交叉目标下未定义：
   `error: 'SIGURG' undeclared (first use in this function)`。
   需要为该文件提供 Windows 侧的定义/守卫（编译期 define 或源码内 `#ifdef`）。

后续仍是：修完该项继续 `gmake -j8` → `gmake install`（若报 `BCrypt*` 未定义则在链接行补
`-lbcrypt`）→ `NGINX_DIR=build-win64/winopenresty ./scripts/package-win64.sh` →
`strings` 核验 `gone from session_list`。

构建时的环境变量（每次 `gmake` 都要带）：

```sh
export PATH=$PWD/build-win64/winbin:$PATH \
       HOST_CC=/usr/bin/gcc HOST_SYS=Linux TARGET_SYS=Windows NGX_RTC_CROSS_WIN32=1
```
