.pragma library
// Client-side TOTP (RFC 6238, SHA-1) — bw serve exposes no totp endpoint,
// so the code is computed locally from the item's otpauth:// or base32 seed.
// Instant and offline; no bw subprocess (measured 3-21s per CLI call).

function _rotl(x, n) { return (x << n) | (x >>> (32 - n)); }

function _sha1(msg) {
    const ml = msg.length;
    const total = ((ml + 9 + 63) >> 6) << 6;
    const buf = new Uint8Array(total);
    buf.set(msg);
    buf[ml] = 0x80;
    const bits = ml * 8;
    buf[total - 4] = (bits >>> 24) & 0xff;
    buf[total - 3] = (bits >>> 16) & 0xff;
    buf[total - 2] = (bits >>> 8) & 0xff;
    buf[total - 1] = bits & 0xff;
    let h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;
    const w = new Int32Array(80);
    for (let b = 0; b < total; b += 64) {
        for (let i = 0; i < 16; i++) {
            w[i] = (buf[b + 4 * i] << 24) | (buf[b + 4 * i + 1] << 16) | (buf[b + 4 * i + 2] << 8) | buf[b + 4 * i + 3];
        }
        for (let i = 16; i < 80; i++) {
            w[i] = _rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) | 0;
        }
        let a = h0, b2 = h1, c = h2, d = h3, e = h4;
        for (let i = 0; i < 80; i++) {
            let f, k;
            if (i < 20) { f = (b2 & c) | (~b2 & d); k = 0x5A827999; }
            else if (i < 40) { f = b2 ^ c ^ d; k = 0x6ED9EBA1; }
            else if (i < 60) { f = (b2 & c) | (b2 & d) | (c & d); k = 0x8F1BBCDC; }
            else { f = b2 ^ c ^ d; k = 0xCA62C1D6; }
            const t = (_rotl(a, 5) + f + e + k + w[i]) | 0;
            e = d; d = c; c = _rotl(b2, 30); b2 = a; a = t;
        }
        h0 = (h0 + a) | 0; h1 = (h1 + b2) | 0; h2 = (h2 + c) | 0; h3 = (h3 + d) | 0; h4 = (h4 + e) | 0;
    }
    const out = new Uint8Array(20);
    const hs = [h0, h1, h2, h3, h4];
    for (let i = 0; i < 5; i++) {
        out[4 * i] = (hs[i] >>> 24) & 0xff;
        out[4 * i + 1] = (hs[i] >>> 16) & 0xff;
        out[4 * i + 2] = (hs[i] >>> 8) & 0xff;
        out[4 * i + 3] = hs[i] & 0xff;
    }
    return out;
}

function _hmacSha1(key, msg) {
    let k = key;
    if (k.length > 64) k = _sha1(k);
    const ip = new Uint8Array(64 + msg.length);
    const op = new Uint8Array(64 + 20);
    for (let i = 0; i < 64; i++) {
        const kb = i < k.length ? k[i] : 0;
        ip[i] = kb ^ 0x36;
        op[i] = kb ^ 0x5c;
    }
    ip.set(msg, 64);
    op.set(_sha1(ip), 64);
    return _sha1(op);
}

function _b32(s) {
    const A = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    let bits = 0, val = 0;
    const out = [];
    for (let i = 0; i < s.length; i++) {
        const ch = s.charAt(i).toUpperCase();
        if (ch === "=") break;
        const idx = A.indexOf(ch);
        if (idx < 0) continue;
        val = (val << 5) | idx;
        bits += 5;
        if (bits >= 8) { out.push((val >>> (bits - 8)) & 0xff); bits -= 8; }
    }
    return new Uint8Array(out);
}

function _parse(seed) {
    if (!seed) return null;
    if (seed.lastIndexOf("otpauth://", 0) === 0) {
        const m = /secret=([A-Za-z2-7=]+)/.exec(seed);
        if (!m) return null;
        const pd = /period=(\d+)/.exec(seed);
        const dg = /digits=(\d+)/.exec(seed);
        return { secret: m[1], period: pd ? parseInt(pd[1], 10) : 30, digits: dg ? parseInt(dg[1], 10) : 6 };
    }
    return { secret: seed, period: 30, digits: 6 };
}

// code(seed[, nowSec]) -> "123456" / "12345678", or "" when seed unusable.
function code(seed, nowSec) {
    const p = _parse(seed);
    if (!p) return "";
    const key = _b32(p.secret);
    if (key.length === 0) return "";
    const t = (nowSec === undefined) ? Math.floor(Date.now() / 1000) : nowSec;
    const counter = Math.floor(t / p.period);
    const msg = new Uint8Array(8); // upper 4 bytes zero: fine until year 8921
    msg[4] = (counter >>> 24) & 0xff;
    msg[5] = (counter >>> 16) & 0xff;
    msg[6] = (counter >>> 8) & 0xff;
    msg[7] = counter & 0xff;
    const h = _hmacSha1(key, msg);
    const off = h[19] & 0x0f;
    const bin = (((h[off] & 0x7f) << 24) | (h[off + 1] << 16) | (h[off + 2] << 8) | h[off + 3]) >>> 0;
    const digits = (p.digits === 8) ? 8 : 6;
    const mod = (digits === 8) ? 100000000 : 1000000;
    let s = String(bin % mod);
    while (s.length < digits) s = "0" + s;
    return s;
}

// RFC 6238 SHA-1 test vectors + otpauth-URI parsing. Returns bool.
function selftest() {
    const seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"; // "12345678901234567890"
    const V = [
        [59, "94287082"], [1111111109, "07081804"], [1111111111, "14050471"],
        [1234567890, "89005924"], [2000000000, "69279037"], [20000000000, "65353130"]
    ];
    const uri8 = "otpauth://totp/Vec:x?issuer=Vec&period=30&digits=8&secret=" + seed;
    for (let i = 0; i < V.length; i++) {
        if (code(uri8, V[i][0]) !== V[i][1]) return false; // RFC vectors are 8-digit
    }
    if (code(seed, 59) !== "287082") return false; // same vector, default 6 digits
    return code(null, 59) === "" && code("!!!!", 59) === "" && code("otpauth://totp/x?period=30", 59) === "";
}
