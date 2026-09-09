import { RTCPeerConnection, useH264, useOPUS } from "werift";
const pc = new RTCPeerConnection({ codecs: { audio: [useOPUS()], video: [useH264()] } });
let n = 0;
pc.onTrack.subscribe((t) => {
  if (t.kind !== "video") return;
  t.onReceiveRtp.subscribe((rtp) => {
    const p = rtp.payload;
    if (!p) return;
    const t0 = p[0] & 0x1f;
    const tn = t0 === 28 ? "FU-A" : t0 === 24 ? "STAP-A" : t0 === 5 ? "IDR" : "NAL"+t0;
    const h = rtp.header;
    console.log(`${n}: ${tn} seq=${h.sequenceNumber} ts=${h.timestamp} len=${p.length}`);
    n++;
    if (n >= 12) process.exit(0);
  });
});
pc.addTransceiver("audio", { direction: "recvonly" });
pc.addTransceiver("video", { direction: "recvonly" });
const offer = await pc.createOffer();
await pc.setLocalDescription(offer);
const res = await fetch("http://127.0.0.1:18082/rtc/v1/play/", { method: "POST", headers: {"Content-Type":"application/json"},
  body: JSON.stringify({ sdp: offer.sdp, streamurl:"webrtc://127.0.0.1:18082/live/livestream", api:"http://127.0.0.1:18082", clientip:"127.0.0.1", key:"demo-key-123" }) });
const data = await res.json();
await pc.setRemoteDescription({ type: "answer", sdp: data.sdp });
await new Promise(r => setTimeout(r, 3000));
