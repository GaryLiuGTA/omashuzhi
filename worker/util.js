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

export function request(method, url, param = null) {
  let session = new Soup.Session({ timeout: 30 });
  let msg = param ? Soup.Message.new_from_encoded_form(method, url, Soup.form_encode_hash(param))
    : Soup.Message.new(method, url);
  let ans = session.send_and_read(msg, null);
  if (msg.statusCode !== Soup.Status.OK) throw new Error(`HTTP ${msg.statusCode}: ${msg.get_reason_phrase()}`);
  return decode(ans.get_data());
}

export function execute(cmd) {
  let [_, stdout, stderr, status] = GLib.spawn_command_line_sync(cmd);
  if (status !== 0) throw new Error(stderr ? decode(stderr).trim() : `exit ${status}`);
  return stdout ? decode(stdout).trim() : '';
}

export function ensureDir(path) {
  GLib.mkdir_with_parents(path, 0o755);
}

export function readJSON(path) {
  let [_, contents] = GLib.file_get_contents(path);
  return JSON.parse(decode(contents));
}
