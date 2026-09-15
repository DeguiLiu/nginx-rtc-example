-- Prometheus /metrics endpoint (text exposition format).
-- Reads the C-side stats snapshot mirrored into lua_shared_dict rtc_stats.

local ngx = ngx
local cjson = require "cjson"
local client_latency = require "client_latency"

local raw = ngx.shared.rtc_stats:get("stats")
ngx.header["Content-Type"] = "text/plain; version=0.0.4"

if not raw then
    ngx.print("# rtc stats mirror not ready\n")
    return
end

local ok, d = pcall(cjson.decode, raw)
if not ok or "table" ~= type(d) then
    ngx.print("# invalid rtc stats snapshot\n")
    return
end

local out = {}

local function help(name, text)
    out[#out + 1] = "# HELP " .. name .. " " .. text
end

local function typ(name, t)
    out[#out + 1] = "# TYPE " .. name .. " " .. t
end

local function sample(name, labels, value)
    local l = ""
    if labels and next(labels) then
        local parts = {}
        for k, v in pairs(labels) do
            -- Prometheus exposition requires backslash, double quote and newline
            -- to be escaped. Backslash must go first or the escapes inserted for
            -- the other two get doubled; a value ending in a backslash otherwise
            -- escapes its own closing quote and truncates the label set.
            parts[#parts + 1] = k .. '="'
                .. tostring(v):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
                .. '"'
        end
        table.sort(parts)
        l = "{" .. table.concat(parts, ",") .. "}"
    end
    out[#out + 1] = name .. l .. " " .. tostring(value)
end

help("rtc_streams", "Number of live streams.")
typ("rtc_streams", "gauge")
help("rtc_clients", "Number of WebRTC viewers.")
typ("rtc_clients", "gauge")
help("rtc_stream_clients", "Viewer count per stream.")
typ("rtc_stream_clients", "gauge")
help("rtc_stream_publishing", "Whether the stream has an active publisher.")
typ("rtc_stream_publishing", "gauge")
help("rtc_video_packets", "Video RTP packets sent.")
typ("rtc_video_packets", "counter")
help("rtc_video_octets", "Video RTP payload octets sent.")
typ("rtc_video_octets", "counter")
help("rtc_audio_packets", "Audio RTP packets sent.")
typ("rtc_audio_packets", "counter")
help("rtc_audio_octets", "Audio RTP payload octets sent.")
typ("rtc_audio_octets", "counter")
help("rtc_send_failed", "RTP datagrams dropped per stream (send NGX_ERROR / short write).")
typ("rtc_send_failed", "counter")
help("rtc_send_eagain", "RTP datagrams dropped per stream (send NGX_AGAIN, UDP buffer full).")
typ("rtc_send_eagain", "counter")
-- Per-reason drop accounting, summed over the stream's sessions. One series per
-- reason rather than three metric names because the question they answer is
-- always the same one -- "is the server dropping this stream's packets, and
-- why" -- and a reason label keeps that a single query. silent is the one that
-- has no other symptom: the server stopped sending to a session because the
-- peer went quiet, which from the viewer's side is indistinguishable from loss.
help("rtc_session_drops", "Media held back per stream, by the stage that refused it.")
typ("rtc_session_drops", "counter")
local DROP_REASONS = { "pacer", "gop", "silent" }
-- Round trip on the media path, measured by this server from the clients'
-- receiver reports (RFC 3550) -- the one latency that needs no cooperation
-- beyond the RTCP the client already sends. Worst session, not mean: a single
-- viewer on a bad path is what an operator needs to see, and averaging it
-- against the healthy majority is how it stops being visible. 0 means no
-- report has come back yet, which is different from 0 ms.
help("rtc_stream_rtt_ms", "Worst session round trip per stream, milliseconds (0 = no report yet).")
typ("rtc_stream_rtt_ms", "gauge")
-- The other half of the latency story, and the only half the server cannot
-- measure for itself: what the viewer's browser saw between ingest and the
-- frame being on screen. Reported by the player page and joined here by ICE
-- ufrag, so these series only exist for sessions that are still live -- a
-- number from a tab that has gone away is not a measurement, it is a memory.
-- Read it against rtc_stream_rtt_ms: if e2e is large while rtt is small, the
-- time is in the viewer's jitter buffer or decoder, not on the wire.
help("rtc_client_e2e_ms", "Viewer-measured ingest-to-display, milliseconds (page-reported mean).")
typ("rtc_client_e2e_ms", "gauge")
help("rtc_client_jitter_buffer_ms", "Viewer-side jitter buffer delay per frame, milliseconds.")
typ("rtc_client_jitter_buffer_ms", "gauge")
help("rtc_client_decode_ms", "Viewer-side decode time per frame, milliseconds.")
typ("rtc_client_decode_ms", "gauge")

sample("rtc_streams", nil, d.total_streams or 0)
sample("rtc_clients", nil, d.total_clients or 0)

for _, s in ipairs(d.streams or {}) do
    local labels = { stream = s.name or "unknown" }
    sample("rtc_stream_clients", labels, s.clients or 0)
    sample("rtc_stream_publishing", labels, (s.publishing and 1 or 0))
    sample("rtc_video_packets", labels, (s.video and s.video.packets or 0))
    sample("rtc_video_octets", labels, (s.video and s.video.octets or 0))
    sample("rtc_audio_packets", labels, (s.audio and s.audio.packets or 0))
    sample("rtc_audio_octets", labels, (s.audio and s.audio.octets or 0))
    sample("rtc_send_failed", labels, s.send_failed or 0)
    sample("rtc_send_eagain", labels, s.send_eagain or 0)

    local drops = { pacer = 0, gop = 0, silent = 0 }
    local rtt_max = 0
    for _, x in ipairs(s.sessions or {}) do
        drops.pacer = drops.pacer + (x.drop_pacer or 0)
        drops.gop = drops.gop + (x.drop_gop or 0)
        drops.silent = drops.silent + (x.drop_silent or 0)
        local v = x.rtt_ms or 0
        if v > rtt_max then rtt_max = v end

        -- Round trip is the server's own measurement; e2e is the viewer's. Only
        -- sessions that are still in the registry get the second one, which is
        -- what keeps a departed tab's last number from being exported forever.
        local rep = client_latency.get(x.ufrag)
        if rep then
            local labels2 = { stream = s.name or "unknown", ufrag = x.ufrag or "" }
            sample("rtc_client_e2e_ms", labels2, rep.e2e_ms or 0)
            if rep.jb_ms then
                sample("rtc_client_jitter_buffer_ms", labels2, rep.jb_ms)
            end
            if rep.decode_ms then
                sample("rtc_client_decode_ms", labels2, rep.decode_ms)
            end
        end
    end
    for _, reason in ipairs(DROP_REASONS) do
        sample("rtc_session_drops",
               { stream = s.name or "unknown", reason = reason },
               drops[reason])
    end
    sample("rtc_stream_rtt_ms", labels, rtt_max)
end

-- Session lifecycle states, from a count the C side takes over the whole shm
-- session list. That list, not the per-stream arrays, is what makes a session
-- wedged in NEW or mid-handshake visible: it has not subscribed yet, and a WHIP
-- publisher never subscribes at all. This is the series to alert on when
-- viewers connect but no picture appears -- a plateau on ICE_BOUND or
-- DTLS_HANDSHAKE names the step that is stuck.
--
-- CLOSED is not a label and is never counted: a closed session leaves the
-- registry outright, so it would read as a permanently-zero series, which says
-- "nothing ever closes" rather than "this one did". Emit every other state even
-- at zero, so a transition is a visible step rather than a disappearing series.
local SESSION_STATES = { "UNKNOWN", "NEW", "ICE_BOUND", "DTLS_HANDSHAKE",
                         "SRTP_READY" }
help("rtc_sessions", "Live RTC sessions by lifecycle state.")
typ("rtc_sessions", "gauge")
for _, state in ipairs(SESSION_STATES) do
    sample("rtc_sessions", { state = state },
           (d.session_states or {})[state] or 0)
end

ngx.print(table.concat(out, "\n"))
