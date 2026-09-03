// SPDX-License-Identifier: GPL-3.0-or-later
// Utility functions for hypr-shuzhi

import GLib from 'gi://GLib?version=2.0';
import Soup from 'gi://Soup?version=3.0';

// Polyfills for older SpiderMonkey
if (!Math.sumPrecise) Math.sumPrecise = a => a.reduce((s, x) => s + x, 0);
if (!Math.clamp) Math.clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);

// Cascade operators (from tuberry/shuzhi)
export const $ = Symbol('Chain Call');
export const $s = Symbol('Chain Calls');
export const $_ = Symbol('Chain If Call');
export const $$ = Symbol('Chain Seq Call');
Object.defineProperties(Object.prototype, {
  [$]: { get() { return new Proxy(this, { get: (t, k) => (...xs) => (t[k] instanceof Function ? t[k](...xs) : ([t[k]] = xs), t) }); } },
  [$s]: { get() { return new Proxy(this, { get: (t, k) => xs => (xs?.forEach(x => Array.isArray(x) ? t[k](...x) : t[k](x)), t) }); } },
  [$_]: { get() { return new Proxy(this, { get: (t, k) => (b, ...xs) => b ? t[$][k](...xs) : t }); } },
  [$$]: { value(f) { f(this); return this; } },
});

export const id = x => x;
export const nop = () => { };
export const Y = f => (...xs) => f(Y(f))(...xs);
export const decode = x => new TextDecoder().decode(x);
export const encode = x => new TextEncoder().encode(x);
export const lot = x => x[Math.floor(Math.random() * x.length)];
export const array = (n, f = id) => Array.from({ length: n }, (_x, i) => f(i));
export const omap = (o, f) => Object.fromEntries(Object.entries(o).flatMap(f));
export const vmap = (o, f) => omap(o, ([k, v]) => [[k, f(v)]]);
export const essay = (f, g = nop) => { try { return f(); } catch (e) { return g(e); } };
export const esc = (x, i = -1) => GLib.markup_escape_text(x, i);
export const format = (x, f) => x.replace(/\{\{(\w+)\}\}|\{(\w+)\}/g, (m, a, b) => b ? f(b) ?? m : f(a) === undefined ? m : `{${a}}`);

export function* chunk(list, step = 2, from = 0) {
  let next = step instanceof Function ? i => { while (++i < list.length && !step(list[i], i)); return i; } : i => i + step;
  while (from < list.length) yield list.slice(from, from = next(from));
}

// Hard ceiling on any response body we will read into memory. The real
// payload is a few hundred bytes; anything remotely near this is hostile or
// broken, and send_and_read() would happily buffer gigabytes of it.
export const MAX_RESPONSE_BYTES = 256 * 1024;

export function request(method, url, param = null, limit = MAX_RESPONSE_BYTES) {
  let session = new Soup.Session({ timeout: 30 });
  let msg = param ? Soup.Message.new_from_encoded_form(method, url, Soup.form_encode_hash(param))
    : Soup.Message.new(method, url);

  // send() streams, unlike send_and_read() which buffers the whole body first.
  let stream = session.send(msg, null);
  if (msg.statusCode !== Soup.Status.OK) {
    try { stream.close(null); } catch (e) { /* best effort */ }
    throw new Error(`HTTP ${msg.statusCode}: ${msg.get_reason_phrase()}`);
  }

  // Reject early when the server declares an oversized body; a lying or absent
  // Content-Length is still caught by the read loop below.
  let declared = msg.get_response_headers()?.get_content_length?.() ?? 0;
  if (declared > limit) {
    try { stream.close(null); } catch (e) { /* best effort */ }
    throw new Error(`response too large: ${declared} bytes > ${limit}`);
  }

  let chunks = [];
  let total = 0;
  try {
    for (;;) {
      // Read one byte past the remaining budget so an over-limit body trips the
      // check below instead of being silently truncated into valid-looking JSON.
      let bytes = stream.read_bytes(Math.min(16384, limit - total + 1), null);
      let n = bytes.get_size();
      if (n === 0) break;
      total += n;
      if (total > limit) throw new Error(`response exceeded ${limit} bytes`);
      chunks.push(bytes.get_data());
    }
  } finally {
    try { stream.close(null); } catch (e) { /* best effort */ }
  }

  let buf = new Uint8Array(total);
  let at = 0;
  for (let c of chunks) { buf.set(c, at); at += c.length; }
  return decode(buf);
}

export function execute(cmd) {
  let [_, stdout, stderr, status] = GLib.spawn_command_line_sync(cmd);
  if (status !== 0) throw new Error(stderr ? decode(stderr).trim() : `exit ${status}`);
  return stdout ? decode(stdout).trim() : '';
}

export function ensureDir(path, mode = 0o755) {
  GLib.mkdir_with_parents(path, mode);
}

export function readJSON(path) {
  let [_, contents] = GLib.file_get_contents(path);
  return JSON.parse(decode(contents));
}
