// Подписи платёжных сервисов: SHA (Web Crypto есть и в Deno, и в Node), HMAC и MD5 — Робокасса по
// умолчанию подписывает MD5, а в Web Crypto его нет.

const enc = new TextEncoder();

function hex(buf: ArrayBuffer | Uint8Array): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export async function digest(alg: 'md5' | 'sha1' | 'sha256' | 'sha384' | 'sha512', text: string): Promise<string> {
  if (alg === 'md5') return md5(text);
  const name = { sha1: 'SHA-1', sha256: 'SHA-256', sha384: 'SHA-384', sha512: 'SHA-512' }[alg];
  return hex(await crypto.subtle.digest(name, enc.encode(text)));
}

export async function hmacBase64(key: string, body: string): Promise<string> {
  const k = await crypto.subtle.importKey('raw', enc.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(body)));
  let s = '';
  for (const b of sig) s += String.fromCharCode(b);
  return btoa(s);
}

/** Сравнение подписей за одно время, без подсказки, на каком знаке разошлись. */
export function same(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

// MD5 (RFC 1321) над UTF-8.
export function md5(text: string): string {
  const msg = enc.encode(text);
  const len = msg.length;
  const words = new Uint32Array((((len + 8) >>> 6) + 1) * 16);
  for (let i = 0; i < len; i++) words[i >>> 2] |= msg[i] << ((i % 4) * 8);
  words[len >>> 2] |= 0x80 << ((len % 4) * 8);
  words[words.length - 2] = (len * 8) >>> 0;
  words[words.length - 1] = Math.floor((len * 8) / 0x100000000);
  const s = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21];
  const k = Array.from({ length: 64 }, (_, i) => Math.floor(Math.abs(Math.sin(i + 1)) * 0x100000000) >>> 0);
  let a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
  for (let o = 0; o < words.length; o += 16) {
    let a = a0, b = b0, c = c0, d = d0;
    for (let i = 0; i < 64; i++) {
      let f: number, g: number;
      if (i < 16) [f, g] = [(b & c) | (~b & d), i];
      else if (i < 32) [f, g] = [(d & b) | (~d & c), (5 * i + 1) % 16];
      else if (i < 48) [f, g] = [b ^ c ^ d, (3 * i + 5) % 16];
      else [f, g] = [c ^ (b | ~d), (7 * i) % 16];
      const sh = s[(i >>> 4) * 4 + (i % 4)];
      const x = (a + f + k[i] + words[o + g]) >>> 0;
      a = d;
      d = c;
      c = b;
      b = (b + ((x << sh) | (x >>> (32 - sh)))) >>> 0;
    }
    a0 = (a0 + a) >>> 0;
    b0 = (b0 + b) >>> 0;
    c0 = (c0 + c) >>> 0;
    d0 = (d0 + d) >>> 0;
  }
  const out = new Uint8Array(16);
  [a0, b0, c0, d0].forEach((v, i) => {
    for (let j = 0; j < 4; j++) out[i * 4 + j] = (v >>> (8 * j)) & 0xff;
  });
  return hex(out);
}
