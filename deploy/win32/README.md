# nginx-rtc Windows HTTP-FLV 直播

Windows 版 nginx 不支持 UDP（`nginx.org/en/docs/windows.html`），因此本包只提供
**RTMP → HTTP-FLV / HLS / DASH** 直播，不含 WebRTC 媒体面（UDP 8000）。

## 目录内容

- `nginx.exe` —— OpenResty + nginx-http-flv-module + nginx-rtc-module 静态编译
- `lib*.dll` / `lua51.dll` —— 运行时依赖，必须与 `nginx.exe` 同目录
- `conf/` —— 配置（已去掉 WebRTC/UDP 段，`worker_processes 1`）
- `html/` —— 播放页（`flvplayer` 用 flv.js 播放 HTTP-FLV）
- `tools/` —— 可选；放一个 Windows 版 `ffmpeg.exe` 进去，`push_test.bat` 会优先用它
- `start.bat` / `stop.bat` —— 启停脚本
- `push_test.bat` —— 一键推测试流

## 启动

双击 `start.bat`，或命令行：

```cmd
cd /d D:\workspace\winopenresty
nginx.exe -p .
```

停止：双击 `stop.bat`，或 `nginx.exe -s stop`。

## 推流（RTMP）

方式一（推荐）：双击 `push_test.bat`，它生成彩色测试图案自动推 `live/livestream`，
无需准备视频文件。ffmpeg 由你提供：本包**不含** `ffmpeg.exe`（许可证与体积都归它自己），
脚本先找 `tools\ffmpeg.exe`，找不到就用 PATH 上的 `ffmpeg`。

方式二：用 ffmpeg 或 OBS 推自己的流，流名 `STREAM` 可自定义：

```cmd
ffmpeg -re -i test.mp4 -c:v libx264 -preset veryfast -b:v 800k -c:a aac -f flv rtmp://127.0.0.1:1935/live/STREAM
```

## 播放（HTTP-FLV）

浏览器打开播放页：

```
http://127.0.0.1:18082/flvplayer
```

或直接用 VLC / ffplay 拉流：

```
http://127.0.0.1:18082/live?app=live&stream=STREAM
```

HLS：`http://127.0.0.1:18082/hls/STREAM.m3u8`
DASH：`http://127.0.0.1:18082/dash/STREAM.mpd`

## 防火墙

首次运行放行 TCP 1935（推流）和 TCP 18082（播放）入站即可，无 UDP 端口。

## 说明

- Windows 版 nginx 单 worker、select 事件模型，适合开发验证，不适合高并发生产。
- 推流鉴权（`on_publish`）与播放鉴权（`flv_auth`）均已关闭，推流/播放无需任何密钥。
- 生产环境如需鉴权，取消 `conf/nginx.conf` 中 `on_publish` 与 `access_by_lua_file conf/flv_auth.lua`
  两行的注释，并按 HMAC 签名规则补 `t`/`sign` 参数。
