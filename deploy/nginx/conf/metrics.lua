-- Prometheus /metrics endpoint (text exposition format).
-- Reads the C-side stats snapshot mirrored into lua_shared_dict rtc_stats.

local cjson = require "cjson"

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
            parts[#parts + 1] = k .. '="' .. tostring(v):gsub('"', '\\"') .. '"'
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
end

ngx.print(table.concat(out, "\n"))
