# nginx-rtc-example

Example deploy of [nginx-rtc-module](https://github.com/DeguiLiu/nginx-rtc-module), an in-nginx C module for RTMP/WHIP → WebRTC low-latency live streaming.

[中文文档](README.zh.md)

The module runs inside OpenResty/nginx. RTMP or WHIP pushes come in, the module turns them into RTP/SRTP and sends them over UDP straight to browser WebRTC players. The same origin also serves HTTP-FLV, HLS, and DASH, and records every stream to FLV on disk. If WebRTC fails or stalls, the player falls back to HTTP-FLV.

Pipeline:

```
ffmpeg/WHIP → nginx (RTMP/HTTP) → module (bridge → shm media ring → SRTP/UDP) → browser WebRTC
```

Both player pages below run against the same live stream; the wall clock burned into the top-left corner is what makes the latency difference readable at a glance:

![HTTP-FLV (`/flvplayer`) on the left, WebRTC (`/rtcplayer.html`) on the right](docs/images/webrtc-vs-http-flv.png)

<!-- One capture, both real pages side by side: the right pane is a live
     /rtcplayer.html, so the two burned-in clocks are directly comparable. -->

## Repos

The C code lives in its own public repo, [DeguiLiu/nginx-rtc-module](https://github.com/DeguiLiu/nginx-rtc-module) (MIT). This repo keeps only the glue: deploy config + Lua, player pages, client scripts, build/ops scripts, and docs. See `docs/` for architecture, multi-worker shm design, and evaluation notes.

## Layout

```
vendor/                 dependency notes (no embedded source, except one runtime asset, below)
deploy/nginx/
  conf/                 nginx.conf + *.lua (HMAC auth, stats, flvplayer, viewer count)
  html/                 rtcplayer.html / flv.min.js (flv.js v1.6.2) / hmac-sha256.js
client/                 play.mjs (play), whip_push.mjs (WHIP push), lib/token.mjs (HMAC)
scripts/                fetch-deps.sh / build-deps.sh / build-openresty.sh
docs/                   design, evaluation, implementation guides, nginx coding standards (Chinese)
  images/               README screenshots
run.sh                  sync / nginx / push / keep-push / stop / verify
```

## Dependencies

Nothing is vendored: neither the module nor third-party C source. `scripts/fetch-deps.sh` pulls everything at build time into `scripts/_cache/` (gitignored) at pinned refs, and the build scripts unpack/clone and compile it.

| Dependency | Form | Version / source |
|---|---|---|
| nginx-rtc-module | shallow clone at build time | v0.4.0 (DeguiLiu/nginx-rtc-module, MIT) |
| OpenResty | tarball at build time | 1.31.1.1 (openresty.org) |
| nginx-http-flv-module | shallow clone at build time | v1.2.14 (winshining/nginx-http-flv-module) |
| Opus | tarball at build time | 1.3.1 (xiph/opus) |
| libsrtp | shallow clone at build time | 2.3.0 (ciscosystems/libsrtp) |
| FFmpeg (subset) | shallow clone at build time | aac decode + swresample + avutil (FFmpeg n6.1) |

The one embedded third-party asset is `deploy/nginx/html/flv.min.js` (flv.js v1.6.2, Apache-2.0), kept so the player page works offline; see `vendor/README.md`.

Prebuilt libs land in `build/third/{include,lib}`. The module's addon `config` finds them via `NGX_RTC_THIRD`, which `build-openresty.sh` passes explicitly. If you already have a prebuilt tree, `export NGX_RTC_THIRD=/path/to/third` skips the rebuild.

## Build

```bash
# one-shot: fetch → build-deps → build-openresty
scripts/setup.sh

# module host unit tests run in the module repo (no nginx/ffmpeg needed):
#   git clone --depth 1 --branch v0.4.0 https://github.com/DeguiLiu/nginx-rtc-module
#   make -C nginx-rtc-module/test test

# fetch all dependency sources (cached runs are instant; on github-blocked
# hosts export HTTPS_PROXY=http://127.0.0.1:7890 first)
scripts/fetch-deps.sh

# build static libs (opus/libsrtp/ffmpeg) -> build/third
scripts/build-deps.sh

# configure + build openresty + module + http-flv -> build/nginx
OPENRESTY_PREFIX=$PWD/build/nginx scripts/build-openresty.sh
```

## Run

```bash
OPENRESTY_PREFIX=/path/to/nginx-prefix ./run.sh nginx   # sync config + start
./run.sh push          # ffmpeg pushes livestream (Beijing wall clock burned in for latency eyeballing)
./run.sh keep-push     # supervised push, auto-restarts ffmpeg
./run.sh verify        # node client/play.mjs smoke playback (any play.mjs flag passes through)
./run.sh stop
```

Prefix resolution: `OPENRESTY_PREFIX`, then `build/nginx`, else error. `run.sh nginx|start` syncs `deploy/nginx/{conf,html}` into the prefix and generates `conf/nginx.rtc.conf` (candidate IP auto-detected or `RTC_CANDIDATE_IP`).

### Ports

| Port | Purpose |
|---|---|
| 18082 HTTP | `/flvplayer`, `/rtcplayer.html`, `/rtc/v1/stats`, `/rtc/v1/flvcnt`, `/metrics` |
| 1935 RTMP | push ingest + HTTP-FLV source |
| 8000 UDP | WebRTC SRTP/SRTCP + ICE/STUN |

Auth is an HMAC token: `t` = expiry seconds, `sign` = base64url(HMAC-SHA256(`<app>/<stream>|t=<t>`)). Demo secret: `demo-secret-0123456789abcdef0123456789abcdef`. Per-stream secrets are in `deploy/nginx/conf/stream_keys.lua`.

### Recording

`record all; record_path rec;` in `application live` records each publish to `<prefix>/rec/<stream>-<timestamp>.flv` (written by the worker that actually receives it; auto_push copies are skipped). Files aren't served over HTTP — pull them from disk. `run.sh nginx` creates the directory.

### Player fallback

`rtcplayer.html` redirects to `/flvplayer?app=&stream=&key=` (same target prefilled) when WebRTC `connectionState`/`iceConnectionState` hits `failed`, or when no media arrives within 10 s.

## Testing

- Host unit tests: in [nginx-rtc-module](https://github.com/DeguiLiu/nginx-rtc-module), `make -C test test` (pure C, no nginx).
- End to end: `./run.sh verify` (werift playback smoke test).

## License

- C module: MIT (c) 2026 DeguiLiu, in [nginx-rtc-module](https://github.com/DeguiLiu/nginx-rtc-module).
- This repo (config, Lua, pages, client, docs, scripts): private; add a LICENSE before publishing.
- Build deps: fetched at build time, each keeps its own upstream LICENSE.
- `deploy/nginx/html/flv.min.js`: flv.js v1.6.2, Apache-2.0; see `vendor/README.md`.
