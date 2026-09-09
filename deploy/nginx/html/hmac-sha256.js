/* Minimal SHA-256 + HMAC-SHA256 in vanilla JS (no WebCrypto), so HMAC token
 * signing works over plain http on a LAN. Exposes:
 *   hmacSha256Base64url(secret, msg) -> base64url string (no padding)
 * Must match server-side resty.openssl.hmac + Node crypto digest("base64url"). */
(function () {
  var K = [
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
  ];
  function rrot(x, n) { return (x >>> n) | (x << (32 - n)); }

  function sha256(bytes) {
    var H = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
    var l = bytes.length;
    var bitLen = l * 8;
    var withOne = new Uint8Array(l + 1);
    withOne.set(bytes); withOne[l] = 0x80;
    var paddedLen = Math.ceil((withOne.length + 8) / 64) * 64;
    var m = new Uint8Array(paddedLen);
    m.set(withOne);
    var dv = new DataView(m.buffer);
    dv.setUint32(paddedLen - 8, Math.floor(bitLen / 0x100000000), false);
    dv.setUint32(paddedLen - 4, bitLen >>> 0, false);
    var wU = new Uint32Array(64);
    for (var i = 0; i < paddedLen; i += 64) {
      var t;
      for (t = 0; t < 16; t++) wU[t] = dv.getUint32(i + t * 4, false);
      for (t = 16; t < 64; t++) {
        var s0 = rrot(wU[t-15],7) ^ rrot(wU[t-15],18) ^ (wU[t-15] >>> 3);
        var s1 = rrot(wU[t-2],17) ^ rrot(wU[t-2],19) ^ (wU[t-2] >>> 10);
        wU[t] = (wU[t-16] + s0 + wU[t-7] + s1) >>> 0;
      }
      var a=H[0],b=H[1],c=H[2],d=H[3],e=H[4],f=H[5],g=H[6],h=H[7];
      for (t = 0; t < 64; t++) {
        var S1 = rrot(e,6)^rrot(e,11)^rrot(e,25);
        var ch = (e&f)^((~e)&g);
        var temp1 = (h + S1 + ch + K[t] + wU[t]) >>> 0;
        var S0 = rrot(a,2)^rrot(a,13)^rrot(a,22);
        var maj = (a&b)^(a&c)^(b&c);
        var temp2 = (S0 + maj) >>> 0;
        h=g; g=f; f=e; e=(d+temp1)>>>0; d=c; c=b; b=a; a=(temp1+temp2)>>>0;
      }
      H[0]=(H[0]+a)>>>0; H[1]=(H[1]+b)>>>0; H[2]=(H[2]+c)>>>0; H[3]=(H[3]+d)>>>0;
      H[4]=(H[4]+e)>>>0; H[5]=(H[5]+f)>>>0; H[6]=(H[6]+g)>>>0; H[7]=(H[7]+h)>>>0;
    }
    var out = new Uint8Array(32);
    var odv = new DataView(out.buffer);
    for (var j = 0; j < 8; j++) odv.setUint32(j*4, H[j], false);
    return out;
  }

  function utf8(s) {
    var out = [];
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0|(c>>6), 0x80|(c&63));
      else if (c < 0xd800 || c >= 0xe000) out.push(0xe0|(c>>12), 0x80|((c>>6)&63), 0x80|(c&63));
      else { var c2 = s.charCodeAt(++i); var cp = 0x10000 + ((c&0x3ff)<<10) + (c2&0x3ff);
             out.push(0xf0|(cp>>18),0x80|((cp>>12)&63),0x80|((cp>>6)&63),0x80|(cp&63)); }
    }
    return new Uint8Array(out);
  }

  function b64url(bytes) {
    var b = "";
    var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (var i = 0; i < bytes.length; i += 3) {
      var n = bytes[i] << 16 | (bytes[i+1]||0) << 8 | (bytes[i+2]||0);
      b += chars[(n>>18)&63] + chars[(n>>12)&63]
         + (i+1 < bytes.length ? chars[(n>>6)&63] : "=")
         + (i+2 < bytes.length ? chars[n&63] : "=");
    }
    return b.replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");
  }

  window.hmacSha256Base64url = function (secret, msg) {
    var key = utf8(secret);
    var block = 64;
    if (key.length > block) key = sha256(key);
    var ipad = new Uint8Array(block), opad = new Uint8Array(block);
    var i;
    for (i = 0; i < block; i++) { ipad[i] = 0x36; opad[i] = 0x5c; }
    for (i = 0; i < key.length; i++) { ipad[i] ^= key[i]; opad[i] ^= key[i]; }
    var data = utf8(msg);
    var inner = new Uint8Array(block + data.length);
    inner.set(ipad); inner.set(data, block);
    var ih = sha256(inner);
    var outer = new Uint8Array(block + 32);
    outer.set(opad); outer.set(ih, block);
    return b64url(sha256(outer));
  };
})();
