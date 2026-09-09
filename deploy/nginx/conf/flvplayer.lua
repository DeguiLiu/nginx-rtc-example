-- conf/flvplayer.lua - HTTP-FLV 播放页 (OpenResty 服务端渲染).
-- 充分利用 OpenResty: 直接读 rtc_stats 共享 dict(每 1s 由 C 模块镜像)把"在线流 +
-- viewer 数"内联进 HTML, 页面零二次 fetch 即得可选流; key 校验仍走 /live 的
-- flv_auth(与 WebRTC/RTMP 同源 config.check), 本页只负责生成播放 URL.
-- 前端与 html/rtcplayer.html 同一套卡片/徽章/日志视觉; 实时统计来自
-- flv.js statisticsInfo(解码/丢帧/码率/缓冲延迟), 不依赖服务端接口.

local cjson = require "cjson"

local function esc(s)
    s = tostring(s or "")
    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    s = s:gsub('"', "&quot;")
    return s
end

local raw = ngx.shared.rtc_stats:get("stats")
local opts = {}        -- 在线流 option 片段
local streams = {}     -- 名字数组, 供 JS 前端直达
local nlive = 0

if raw then
    local ok, d = pcall(cjson.decode, raw)
    if ok and "table" == type(d) then
        for _, s in ipairs(d.streams or {}) do
            local nm = s.name or ""
            local app, stream = nm:match("^([^/]+)/(.+)$")
            if s.publishing and app and stream then
                nlive = nlive + 1
                local label = nm .. " (" .. tostring(s.clients or 0) .. " 观众)"
                opts[#opts + 1] = '<option value="' .. esc(nm) .. '">'
                                 .. esc(label) .. "</option>"
                streams[#streams + 1] = nm
            end
        end
    end
end

local opthtml = #opts > 0
    and table.concat(opts, "\n")
    or '<option value="">(暂无在线推流, 请手填 app/stream)</option>'

local live_sub = (#streams > 0)
    and ('当前 <b>%d</b> 路在线推流, 从下拉选择即自动填入'):format(#streams)
    or "当前无在线推流"

ngx.header["Content-Type"] = "text/html; charset=utf-8"

local page = [[<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>HTTP-FLV 播放器</title>
<style>
  :root { --accent:#1a73e8; --danger:#e33; --bg:#f0f2f7; }
  body { font-family: "Microsoft YaHei", sans-serif; background: var(--bg); margin: 0;
         padding: 20px; color: #333; }
  h1 { font-size: 20px; color: var(--accent); margin: 0 0 4px; }
  .sub { color: #888; font-size: 12px; margin-bottom: 12px; line-height: 1.7; }
  .nav { margin: 2px 0 12px; }
  .nav a { color: var(--accent); text-decoration: none; font-size: 13px; margin-right: 14px; }
  .nav a.on { font-weight: 700; text-decoration: underline; }
  .card { background: #fff; border-radius: 8px; padding: 16px 20px; margin-bottom: 14px;
          box-shadow: 0 1px 3px rgba(0,0,0,.1); }
  .card h2 { font-size: 14px; color: var(--accent); margin: 0 0 10px; }
  .row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; margin: 6px 0; }
  label { font-size: 13px; color: #555; min-width: 46px; }
  input, select { padding: 6px 8px; border: 1px solid #ccc; border-radius: 4px; font-size: 13px;
                  box-sizing: border-box; }
  input[type=text] { width: 170px; }
  #stream { width: 190px; }
  #key { width: 300px; }
  button { padding: 8px 18px; border: none; border-radius: 4px; font-size: 14px; cursor: pointer; }
  .btn-play { background: var(--accent); color: #fff; }
  .btn-stop { background: var(--danger); color: #fff; }
  button:disabled { opacity: .5; cursor: not-allowed; }
  .hint { color: #999; font-size: 12px; }

  /* video 区域: 16:9 黑底 + 叠加徽章/提示层 */
  .stage { position: relative; width: 100%; max-width: 720px; aspect-ratio: 16 / 9;
           background: #000; border-radius: 6px; overflow: hidden; }
  .stage video { position: absolute; inset: 0; width: 100%; height: 100%;
                 background: #000; }
  .overlay { position: absolute; inset: 0; display: flex; flex-direction: column;
             align-items: center; justify-content: center; color: #bbb; font-size: 13px;
             gap: 6px; background: rgba(0,0,0,.25); pointer-events: none; }
  .overlay .big { font-size: 30px; }
  .vbadge { position: absolute; top: 8px; right: 8px; display: none; gap: 6px; }
  .vbadge span { background: rgba(0,0,0,.6); color: #fff; padding: 2px 8px; border-radius: 10px;
                 font-size: 12px; }
  .sctrl { position: absolute; top: 36px; right: 8px; display: flex; gap: 6px; z-index: 5; }
  .sctrl button { background: rgba(0,0,0,.55); color: #fff; border: none; border-radius: 6px;
                  padding: 2px 10px; cursor: pointer; font-size: 15px; line-height: 1.5; }
  .sctrl button:hover { background: rgba(0,0,0,.85); }
  .badge { display:inline-block; padding:2px 8px; border-radius:10px; font-size:12px; margin-left:6px; }
  .ok { background:#e6f4ea; color:#137333; } .err { background:#fce8e6; color:#c5221f; }
  .warn { background:#fef7e0; color:#b06000; }
  .hint .badge { margin-left: 0; }

  /* 实时统计: 两列 metric */
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(230px, 1fr));
          gap: 2px 22px; }
  .metric { display: flex; justify-content: space-between; padding: 4px 0;
            border-bottom: 1px dashed #eee; font-size: 13px; }
  .metric .k { color: #777; }
  .metric .v { font-variant-numeric: tabular-nums; color: #222; }
  .metric .v.dim { color: #999; }
  .metric .v.loss { color: #b06000; font-weight: 600; }
  .metric .v.live { color: #137333; font-weight: 600; }

  #log { font-family: monospace; font-size: 12px; background: #1e1e1e; color: #7fdbca;
         border-radius: 4px; padding: 10px; max-height: 150px; overflow-y: auto;
         white-space: pre-wrap; }
  .tbl { font-family: monospace; font-size: 11px; background:#0f1420; color:#9ecbff;
         border-radius:4px; padding:8px 10px; margin-bottom:8px; }
</style>
</head>
<body>
  <h1>📺 HTTP-FLV 直播播放器</h1>
  <div class="sub">nginx-http-flv-module 输出 · flv.js 播放<br>
    亚秒级延迟(秒开) · 弱网模块按 GOP 丢帧保证音频/视频时序不积压<br>
    <span class="hint"><b>]] .. live_sub .. [[</b></span>
  </div>
  <div class="nav">
    <a href="/" style="color:#888">◀ 门户</a>
    <a href="/rtcplayer.html" style="color:#e8710a">切换 WebRTC 低延迟播放器 ▶</a>
    <a href="/metrics" style="color:#888">服务端指标</a>
  </div>

  <div class="card">
    <div class="row"><label>在线流</label>
      <select id="liveSel" style="min-width:260px">]] .. opthtml .. [[</select>
    </div>
    <div class="row"><label>应用</label><input type="text" id="app" value="live">
      <label>流名</label><input type="text" id="stream" value="livestream">
    </div>
    <div class="row"><label>密钥</label><input type="text" id="key" value="demo-secret-0123456789abcdef0123456789abcdef">
      <button class="btn-play" id="btnPlay" onclick="play()">▶ 播放</button>
      <button class="btn-stop" id="btnStop" onclick="stop()" disabled>■ 停止</button>
      <span id="state"><span class="badge warn">未连接</span></span>
    </div>
  </div>

  <div class="card">
    <div class="stage">
      <video id="video" autoplay muted controls playsinline></video>
      <div class="vbadge" id="vbadge"><span id="bRes"></span><span id="bLive">LIVE</span></div>
      <div class="sctrl">
        <button id="btnMute" onclick="toggleMute()" title="静音/出声">🔇</button>
        <button id="btnFs" onclick="toggleFs()" title="全屏">⛶</button>
      </div>
      <div class="overlay" id="overlay"><span class="big">▶</span><span id="ovText">就绪, 点播放开始</span></div>
    </div>
  </div>

  <div class="card">
    <h2>实时统计 (flv.js)</h2>
    <div class="grid" id="stats"></div>
  </div>

  <div class="card">
    <h2>发布端 / 服务端状态 (跨 worker)</h2>
    <div class="grid" id="svr"></div>
    <div class="hint">来源 /rtc/v1/stats(shm 汇聚, 准确反映发布与 RTC 观众)+ /rtc/v1/flvcnt。HTTP-FLV 在线观众由 /live 的 Lua 钩子(access 加 / log 减)在 shared dict 计数, 跨 worker 准确; 替代多 worker 下 worker 本地不可靠的 rtmp_stat /stat + stat.xsl。</div>
  </div>

  <div class="card"><h2>播放日志</h2><div id="log"></div></div>

<script src="/flv.min.js"></script>
<script src="/hmac-sha256.js"></script>
<script>
"use strict";
const $ = id => document.getElementById(id);
const el = { video: $("video"), overlay: $("overlay"), ovText: $("ovText"), stats: $("stats"),
             log: $("log"), state: $("state"), vbadge: $("vbadge"), bRes: $("bRes"),
             btnPlay: $("btnPlay"), btnStop: $("btnStop"), svr: $("svr"),
             btnMute: $("btnMute"), btnFs: $("btnFs") };
let player = null;
let t0 = 0;                 // 本次播放起点 (ms)
let firstFrame = 0;         // 首关键帧相对耗时 (ms)
let statTimer = null;
let lastBytes = { v: 0, a: 0, ts: 0 };

function log(m) {
  el.log.textContent += new Date().toISOString().slice(11, 19) + " " + m + "\n";
  el.log.scrollTop = el.log.scrollHeight;
}
function setState(txt, cls) {
  el.state.innerHTML = `<span class="badge ${cls}">${txt}</span>`;
}
function setOv(txt) { el.ovText.textContent = txt; }

function fmtMs(ms) { return ms == null || isNaN(ms) ? "—" : ms.toFixed(0) + " ms"; }
function fmtKBps(kbps) { return kbps == null || isNaN(kbps) ? "—" : kbps.toFixed(0) + " KB/s"; }
function fmtFps(f) { return f ? f.toFixed(0) + " fps" : "—"; }
function fmtRes(w, h) { return w && h ? w + "×" + h : "—"; }

$("liveSel").onchange = function () {
  var m = this.value.match(/^([^/]+)\/(.+)$/);
  if (m) { $("app").value = m[1]; $("stream").value = m[2]; }
};

function signToken(secret, app, stream, ttl) {
  var t = Math.floor(Date.now() / 1000) + ttl;
  var msg = app + "/" + stream + "|t=" + t;
  return { t: t, sign: window.hmacSha256Base64url(secret, msg) };
}

function row(k, v, cls) {
  return `<div class="metric"><span class="k">${k}</span><span class="v ${cls || ""}">${v}</span></div>`;
}

function toggleMute() {
  el.video.muted = !el.video.muted;
  el.btnMute.textContent = el.video.muted ? "🔇" : "🔊";
}

function toggleFs() {
  const v = el.video;
  if (document.fullscreenElement) { document.exitFullscreen(); }
  else if (v.requestFullscreen) { v.requestFullscreen(); }
  else if (v.webkitRequestFullscreen) { v.webkitRequestFullscreen(); }
}

function fmtBytes(n) {
  if (n == null) return "—";
  return n >= 1048576 ? (n / 1048576).toFixed(1) + " MB"
       : n >= 1024   ? (n / 1024).toFixed(0) + " KB"
       : String(n) + " B";
}

let svrTimer = null;

// 服务端卡: /rtc/v1/stats(shm 发布+WebRTC 观众) + /rtc/v1/flvcnt(Lua 计数的
// HTTP-FLV 在线观众), 每 2s 刷新。
async function renderServer() {
  const app = $("app").value.trim() || "live";
  const stream = $("stream").value.trim();
  if (!stream) { return; }
  const nm = app + "/" + stream;
  const escTxt = s => String(s == null ? "" : s).replace(/[&<>"]/g,
      c => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"}[c]));
  try {
    const rs = await (await fetch("/rtc/v1/stats")).json();
    const fc = await (await fetch("/rtc/v1/flvcnt")).json();
    const s = (rs.streams || []).find(x => x.name === nm);
    if (!s) {
      el.svr.innerHTML = `<div class="metric"><span class="k">结果</span>` +
        `<span class="v">服务端无「${escTxt(nm)}」发布记录</span></div>`;
      return;
    }
    const flv = (fc.streams || []).find(x => x.name === nm);
    const v = s.video || {}, a = s.audio || {};
    const rows = [];
    rows.push(row("发布", s.publishing ? "✓ 推流中" : "否", s.publishing ? "live" : "loss"));
    rows.push(row("发布 worker", "#" + s.pub_worker + (s.cross_worker ? " (跨 worker)" : " (同 worker)")));
    rows.push(row("观众(WebRTC)", String(s.clients == null ? "—" : s.clients)));
    rows.push(row("HTTP-FLV 在线观众", flv ? String(flv.viewers) : "0",
                  flv && flv.viewers > 0 ? "live" : ""));
    rows.push(row("视频 SSRC/PT", (v.ssrc || "—") + " / " + (v.pt || "—")));
    rows.push(row("视频包 / 字节", (v.packets || 0) + " / " + fmtBytes(v.octets)));
    rows.push(row("音频 SSRC/PT", (a.ssrc || "—") + " / " + (a.pt || "—")));
    rows.push(row("音频包 / 字节", (a.packets || 0) + " / " + fmtBytes(a.octets)));
    rows.push(row("发送失败 / 拥塞", (s.send_failed || 0) + " / " + (s.send_eagain || 0),
                  (s.send_failed || s.send_eagain) > 0 ? "loss" : ""));
    el.svr.innerHTML = rows.join("");
  } catch (e) {
    el.svr.innerHTML = `<div class="hint">服务端状态不可用: ${escTxt(e.message)}</div>`;
  }
}

function startServer() {
  renderServer();
  if (svrTimer) { clearInterval(svrTimer); }
  svrTimer = setInterval(renderServer, 2000);
}
function stopServer() {
  if (svrTimer) { clearInterval(svrTimer); svrTimer = null; }
}

function renderStats() {
  const st = player ? player.statisticsInfo : null;
  const now = Date.now();
  const run = now - t0;

  // 首关键帧解码: flv.js 记录 performance 时间戳, 与启动点取差
  if (st && st.firstVideoKeyFrameDecodedTime && !firstFrame) {
    firstFrame = Math.max(0, st.firstVideoKeyFrameDecodedTime - performance.timeOrigin - t0 + now - performance.now());
    if (firstFrame < 0) firstFrame = 0;
    log("首帧: " + firstFrame.toFixed(0) + " ms");
    setState("播放中", "ok");
    el.overlay.style.display = "none";
  }

  const vd = st && st.video ? st.video : {};
  const ad = st && st.audio ? st.audio : {};
  const vBps = lastBytes.ts && vd.bytes ? (vd.bytes - lastBytes.v) * 8 / ((now - lastBytes.ts) / 1000) : 0;
  const aBps = lastBytes.ts && ad.bytes ? (ad.bytes - lastBytes.a) * 8 / ((now - lastBytes.ts) / 1000) : 0;
  lastBytes = { v: vd.bytes || 0, a: ad.bytes || 0, ts: now };

  const w = el.video.videoWidth, h = el.video.videoHeight;
  if (w && h) {
    el.bRes.textContent = fmtRes(w, h) + " " + (vd.fps ? vd.fps.toFixed(0) + "fps" : "");
    el.vbadge.style.display = "flex";
  }

  // 丢帧>0 是弱网信号(模块按 GOP 丢帧); 缓冲延迟小 = 实时
  const dropCls = vd.dropped > 0 ? "loss" : "";
  const rows = [];
  rows.push(row("已运行", (run / 1000).toFixed(1) + " s"));
  rows.push(row("首帧耗时", fmtMs(firstFrame)));
  rows.push(row("下载速度", fmtKBps(st ? st.speed : null)));
  rows.push(row("缓冲延迟(实时度)", st ? fmtMs(st.currentBufferLatency) : "—",
                st && st.currentBufferLatency != null && st.currentBufferLatency < 400 ? "live" : ""));
  rows.push(row("缓存时长", st ? fmtMs(st.currentBufferSize) : "—"));
  rows.push(row("视频码率", fmtKBps(vBps / 8)));
  rows.push(row("音频码率", fmtKBps(aBps / 8)));
  rows.push(row("解码帧", vd.decoded != null ? vd.decoded : "—"));
  rows.push(row("丢帧(弱网丢帧)", vd.dropped != null ? vd.dropped : "—", dropCls));
  rows.push(row("已收视频/音频", (vd.bytes != null ? (vd.bytes / 1024).toFixed(0) + "/" : "—") +
                (ad.bytes != null ? (ad.bytes / 1024).toFixed(0) + " KB" : "—")));
  rows.push(row("视频/音频编码", (vd.codecType || "—") + " / " + (ad.codecType || "—")));
  rows.push(row("解码状态", vd.decoded > 0 ? "✓ 已出图" : "等待视频帧…",
                vd.decoded > 0 ? "live" : ""));

  // 有界延迟保护: 一旦 MSE 缓冲年龄超过 2.5s(解码停滞时缓冲会无限积压,
  // 旧 flv.js 无 live-sync 不会自动跳到直播边缘), 就主动跳到直播边缘, 防止
  // 画面时钟落后墙钟几分钟。断流停机恢复后的旧缓冲也因此被兜住。
  try {
    if (player && !el.video.paused && el.video.readyState >= 2) {
      const b = el.video.buffered;
      if (b && b.length > 0) {
        const end = b.end(b.length - 1);
        const age = end - el.video.currentTime;
        if (isFinite(age) && age > 2.5) {
          el.video.currentTime = Math.max(el.video.currentTime, end - 0.4);
          log("缓冲积压 " + age.toFixed(1) + "s, 已跳至直播边缘");
        }
      }
    }
  } catch (e) {}

  el.stats.innerHTML = rows.join("");
}

function play() {
  stop();
  const app = $("app").value.trim() || "live";
  const stream = $("stream").value.trim();
  const secret = $("key").value.trim();
  if (!stream) { log("缺少流名"); setState("缺少流名", "err"); return; }
  if (!window.flvjs) { log("flv.js 未加载 (检查 /flv.min.js)"); setState("无 flv.js", "err"); return; }
  if (!flvjs.isSupported()) { log("此浏览器不支持 MSE/HTTP-FLV"); setState("不支持", "err"); return; }
  if (!window.hmacSha256Base64url) { log("hmac-sha256.js 未加载"); setState("无 hmac", "err"); return; }

  const tk = signToken(secret, app, stream, 3600);
  const url = "/live?app=" + encodeURIComponent(app) + "&stream=" + encodeURIComponent(stream)
            + "&t=" + tk.t + "&sign=" + encodeURIComponent(tk.sign);

  el.btnPlay.disabled = true; el.btnStop.disabled = false;
  setState("连接中…", "warn");
  setOv("连接 " + app + "/" + stream + " …");
  el.video.onplaying = function () { el.overlay.style.display = "none"; };
  log("开始播放 " + app + "/" + stream);

  // Smooth-first: let MSE buffer absorb browser/network micro-jitter instead of
  // the old zero-stash (enableStashBuffer:false) config that re-buffered on any
  // hiccup and showed the spinner. Costs ~sub-second latency.
  player = flvjs.createPlayer({ type: "flv", url: url, isLive: true,
                                hasAudio: true, hasVideo: true, enableStashBuffer: true });
  player.on(flvjs.Events.ERROR, function (type, detail) {
    const info = detail && detail.info ? detail.info.code + " " + (detail.info.msg || "") : JSON.stringify(detail);
    log("ERROR [" + type + "] " + info);
    setState("错误: " + type, "err");
    setOv("播放失败: " + type);
    el.overlay.style.display = "flex";
  });
  if (flvjs.Events.MEDIA_INFO) {
    player.on(flvjs.Events.MEDIA_INFO, function (mi) {
      if (mi) log("media: isLive=" + mi.isLive + " video=" + (mi.videoCodec || "-") +
                  " audio=" + (mi.audioCodec || "-"));
    });
  }
  if (flvjs.Events.RECOVERED_EARLY_EOF) {
    player.on(flvjs.Events.RECOVERED_EARLY_EOF, function () { log("RECOVERED_EARLY_EOF(直播换 key 帧)"); });
  }
  player.attachMediaElement(el.video);
  player.load(); player.play();

  t0 = Date.now();
  firstFrame = 0;
  lastBytes = { v: 0, a: 0, ts: 0 };
  statTimer = setInterval(renderStats, 500);
  startServer();   // play() 先 stop() 清了 server 轮询, 这里重启
}

function stop() {
  if (statTimer) { clearInterval(statTimer); statTimer = null; }
  stopServer();
  if (player) {
    try { player.pause(); player.unload(); player.detachMediaElement(); player.destroy(); } catch (e) {}
    player = null;
  }
  el.video.removeAttribute("src");
  el.vbadge.style.display = "none";
  setState("已停止", "warn");
  setOv("已停止, 点播放重开");
  el.overlay.style.display = "flex";
  el.btnPlay.disabled = false; el.btnStop.disabled = true;
  el.stats.innerHTML = "";
}
window.onbeforeunload = stop;

// 进页即显示默认流(live/livestream)的服务端状态, 不必等点播放
startServer();
</script>
</body>
</html>]]

ngx.print(page)
