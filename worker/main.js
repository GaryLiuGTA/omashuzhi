#!/usr/bin/env -S gjs -m
// SPDX-License-Identifier: GPL-3.0-or-later
// omashuzhi: Generate wallpapers with Chinese poetry (Omarchy 4.0 plugin worker)

import GLib from 'gi://GLib?version=2.0';
import Gio from 'gi://Gio?version=2.0';
import Cairo from 'gi://cairo';
import Pango from 'gi://Pango?version=1.0';

import * as T from './util.js';
import * as Draw from './draw.js';
import * as Motto from './motto.js';
import { Palette } from './color.js';

const STATE_BACKGROUND = GLib.build_filenamev([
  GLib.get_home_dir(), '.local', 'state', 'omarchy', 'current', 'background',
]);

const Sketch = { WAVE: 0, BLOB: 1, OVAL: 2, TREE: 3, CLOUD: 4 };
const SKETCH_MAP = {
  wave: Sketch.WAVE, blob: Sketch.BLOB, oval: Sketch.OVAL,
  tree: Sketch.TREE, cloud: Sketch.CLOUD,
};
const SKETCH_NAMES = ['wave', 'blob', 'oval', 'tree', 'cloud'];
const DARK_SKETCHES = [Sketch.WAVE, Sketch.BLOB, Sketch.OVAL, Sketch.CLOUD];
const LIGHT_SKETCHES = [Sketch.WAVE, Sketch.BLOB, Sketch.OVAL, Sketch.TREE];

function die(msg) {
  printerr(msg);
  imports.system.exit(1);
}

function getMonitorSize() {
  // Retry a few times — after boot, Hyprland may not have configured monitors yet
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      let json = T.execute('hyprctl monitors -j');
      let monitors = JSON.parse(json);
      let m = monitors.reduce((p, x) => p.width * p.height > x.width * x.height ? p : x, { width: 0, height: 0 });
      if (m.width > 0 && m.height > 0) return { W: m.width, H: m.height };
    } catch (e) {
      if (attempt === 4) logError(e, 'Failed to detect monitor size');
    }
    if (attempt < 4) GLib.usleep(2000000); // wait 2s before retry
  }
  return { W: 1920, H: 1080 };
}

function pickSketch(dark, sketchName) {
  if (sketchName && sketchName !== 'random') {
    let idx = SKETCH_MAP[sketchName];
    if (idx !== undefined) return idx;
  }
  return T.lot(dark ? DARK_SKETCHES : LIGHT_SKETCHES);
}

function getSketchModule(idx, dark) {
  switch (idx) {
    case Sketch.WAVE: return Draw.Wave;
    case Sketch.BLOB: return Draw.Blob;
    case Sketch.OVAL: return Draw.Oval;
    case Sketch.TREE: return dark ? Draw.Cloud : Draw.Tree;
    case Sketch.CLOUD: return dark ? Draw.Cloud : Draw.Tree;
    default: return Draw.Wave;
  }
}

function setWallpaper(pngPath) {
  // Replace the link atomically, the way omarchy-theme-bg-set does with
  // `ln -nsf`. The previous delete-then-create left a window with no link at
  // all — which the shell's background plugin can observe — and if the path
  // was ever a regular file the delete destroyed it silently. rename(2) over
  // the target has neither problem.
  let tmpPath = `${STATE_BACKGROUND}.omashuzhi-${Date.now()}`;
  let tmpFile = Gio.File.new_for_path(tmpPath);
  try { tmpFile.delete(null); } catch (e) { /* not there: fine */ }
  tmpFile.make_symbolic_link(pngPath, null);
  if (GLib.rename(tmpPath, STATE_BACKGROUND) !== 0) {
    try { tmpFile.delete(null); } catch (e) { /* best effort */ }
    die(`could not point ${STATE_BACKGROUND} at ${pngPath}`);
  }

  // Omarchy >= 4.0 renders the background via the omarchy-shell (Quickshell), not swaybg.
  // Invoked via absolute path since keybind-triggered execs run under Hyprland's own $PATH,
  // which doesn't include /usr/share/omarchy/bin. No -q: it masks failures (omarchy-shell -q
  // exits 0 on every failure path), so exit(3) here means "shell down / not ready".
  try {
    T.execute(`/usr/bin/omarchy-shell background set ${GLib.shell_quote(pngPath)}`);
  } catch (e) {
    logError(e, 'omarchy-shell background set failed');
    imports.system.exit(3);
  }
}

function resolveTheme(config) {
  let theme = config.theme ?? (config.dark != null ? (config.dark ? 'dark' : 'light') : 'dark');
  if (theme === 'random') return Math.random() < 0.5;
  return theme === 'dark';
}

// Cache entries we will even look at in one pass. A pathologically full
// directory must not stall the render or balloon memory.
const MAX_CACHE_ENTRIES = 10000;

// Resolve the live background symlink in-process. Parsing `readlink -f` output
// from a shell to decide what to delete is both slower and easier to fool.
function liveBackgroundPath() {
  try {
    let f = Gio.File.new_for_path(STATE_BACKGROUND);
    let info = f.query_info('standard::type,standard::symlink-target', Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
    // get_symlink_target() is only valid on an actual symlink; calling it on a
    // regular file raises a GLib critical.
    if (info.get_file_type() !== Gio.FileType.SYMBOLIC_LINK) return f.get_path();
    let target = info.get_symlink_target();
    if (!target) return f.get_path();
    if (!GLib.path_is_absolute(target)) {
      target = GLib.build_filenamev([GLib.path_get_dirname(STATE_BACKGROUND), target]);
    }
    return Gio.File.new_for_path(target).get_path();
  } catch (e) {
    return null; // no link yet, or unreadable — nothing to protect
  }
}

// The cache directory is attacker-relevant: we write PNGs into it and unlink
// from it. Refuse to touch it unless it is a real directory we own, is not a
// symlink, and is not group/world-writable. Otherwise a swapped symlink turns
// our writes and deletes into someone else's problem.
function assertSafeCacheDir(cacheDir) {
  let info;
  try {
    info = Gio.File.new_for_path(cacheDir)
      .query_info('standard::type,unix::uid,unix::mode', Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
  } catch (e) {
    throw new Error(`cache directory ${cacheDir} is unreadable: ${e.message ?? e}`);
  }
  if (info.get_file_type() !== Gio.FileType.DIRECTORY) {
    throw new Error(`cache path ${cacheDir} is not a directory (symlink or file?)`);
  }
  if (info.get_attribute_uint32('unix::uid') !== GLib_getuid()) {
    throw new Error(`cache directory ${cacheDir} is not owned by this user`);
  }
  let mode = info.get_attribute_uint32('unix::mode') & 0o777;
  if (mode & 0o022) {
    throw new Error(`cache directory ${cacheDir} is group/world writable (mode ${mode.toString(8)})`);
  }
}

// GLib.get_user_*() has no uid accessor in GJS; read it once from /proc.
let _uid = null;
function GLib_getuid() {
  if (_uid === null) {
    let self = Gio.File.new_for_path('/proc/self')
      .query_info('unix::uid', Gio.FileQueryInfoFlags.NONE, null);
    _uid = self.get_attribute_uint32('unix::uid');
  }
  return _uid;
}

// Validate the cache path and hand back a directory it is safe to write to.
// Two things the leaf-only check missed:
//  - T.ensureDir() creates the leaf THROUGH whatever the prefix resolves to,
//    so a symlinked ~/.cache meant we happily created and wrote inside an
//    attacker-chosen directory while the leaf itself passed every check.
//  - mkdir_with_parents is a no-op on an existing directory, so a leaf left
//    at 0755 by an older version was never corrected.
// Failures die() with a readable message instead of throwing a JS stack at
// the user through the popup's status line.
function prepareCacheDir() {
  let home = GLib.get_home_dir();
  let parent = GLib.build_filenamev([home, '.cache']);
  let cacheDir = GLib.build_filenamev([parent, 'omashuzhi']);

  try {
    // Every component we did not create ourselves must be a real directory we
    // own — checked with NOFOLLOW so a symlink is seen as a symlink.
    for (let dir of [home, parent]) {
      let info = Gio.File.new_for_path(dir)
        .query_info('standard::type,unix::uid', Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
      if (info.get_file_type() !== Gio.FileType.DIRECTORY) {
        die(`${dir} is not a directory (symlink?); refusing to create a cache under it`);
      }
      if (info.get_attribute_uint32('unix::uid') !== GLib_getuid()) {
        die(`${dir} is not owned by this user; refusing to create a cache under it`);
      }
    }
  } catch (e) {
    if (e && e.message && e.message.startsWith('omashuzhi:')) throw e;
    die(`cannot validate the cache path: ${e.message ?? e}`);
  }

  T.ensureDir(cacheDir, 0o700);
  try {
    let info = Gio.File.new_for_path(cacheDir)
      .query_info('standard::type,unix::uid,unix::mode', Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
    let mode = info.get_attribute_uint32('unix::mode') & 0o777;
    if (info.get_file_type() === Gio.FileType.DIRECTORY
        && info.get_attribute_uint32('unix::uid') === GLib_getuid()
        && mode !== 0o700) {
      // Tighten a merely-loose mode inherited from an older version (0755 was
      // shipped for a while); mkdir_with_parents would not correct it.
      // But do NOT quietly adopt a group/world-WRITABLE directory by
      // chmod'ing it: anything could already have been planted inside, and a
      // planted symlink at a name we later write would be followed. Refuse and
      // let the user look at it.
      if (mode & 0o022) {
        die(`cache directory ${cacheDir} is group/world writable (mode ${mode.toString(8)}); `
          + `refusing to use it — inspect it and 'chmod 700' it yourself`);
      }
      GLib.chmod(cacheDir, 0o700);
    }
  } catch (e) {
    if (e && e.message && String(e.message).includes('group/world writable')) throw e;
    /* otherwise assertSafeCacheDir below is the gate */
  }

  try {
    assertSafeCacheDir(cacheDir);
  } catch (e) {
    die(`${e.message ?? e}`);
  }
  return cacheDir;
}

function pruneCache(cacheDir, prefix, keepName) {
  try {
    assertSafeCacheDir(cacheDir);
  } catch (e) {
    die(`${e.message ?? e}`);
  }

  // Never delete whichever file the live background symlink resolves to —
  // deleting it out from under the link leaves a dangling link (black desktop).
  let livePath = liveBackgroundPath();

  let dir = Gio.File.new_for_path(cacheDir);
  // NOFOLLOW_SYMLINKS: we must see a symlink as a symlink, not as whatever it
  // points at, or a planted link would have us unlink an arbitrary file.
  let enumerator = dir.enumerate_children(
    'standard::name,standard::type,unix::uid,unix::mode',
    Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
  let info;
  let candidates = [];
  let seen = 0;
  let capped = false;
  while ((info = enumerator.next_file(null))) {
    if (++seen > MAX_CACHE_ENTRIES) { capped = true; break; }
    let name = info.get_name();
    if (!name.startsWith(prefix)) continue;
    // Regular files only: never unlink a symlink, directory, socket or device.
    if (info.get_file_type() !== Gio.FileType.REGULAR) continue;
    // Ours only.
    if (info.get_attribute_uint32('unix::uid') !== GLib_getuid()) continue;
    candidates.push(name);
  }
  enumerator.close(null);
  if (capped) {
    printerr(`omashuzhi: cache directory has more than ${MAX_CACHE_ENTRIES} entries; pruning only the first ${MAX_CACHE_ENTRIES}`);
  }

  // Filenames are wallpaper-<theme>-<epoch>.png, so lexical order is normally
  // chronological — but "normally" is not a guarantee we can delete on. A
  // single file with a larger epoch in its name (a clock step, a stray touch)
  // made every later run compute `newest` as that file and delete the PNG it
  // had just written, leaving current/background dangling and a black desktop.
  // So `keepName` — the file this run wrote — is protected explicitly, and it
  // needs to be: it is not yet the live file, so livePath cannot cover it.
  candidates.sort();
  let newest = candidates.length ? candidates[candidates.length - 1] : null;
  for (let name of candidates) {
    let path = GLib.build_filenamev([cacheDir, name]);
    if (keepName && name === keepName) continue;
    if (name === newest) continue;
    if (livePath && path === livePath) continue;
    GLib.unlink(path);
  }
}

function generate(config) {
  // Validate the cache path FIRST. An unusable cache used to surface as an
  // uncaught JS stack trace only after a full-resolution render had already
  // been paid for.
  let cacheDir = prepareCacheDir();

  let dark = resolveTheme(config);
  let orientation = config.orientation ?? (config.level != null ? (config.level ? 'horizontal' : 'vertical') : 'horizontal');
  let level = orientation !== 'vertical';
  let fonts = config.font;
  let fontName = Array.isArray(fonts) ? T.lot(fonts) : (fonts || 'Serif');
  let fontSize = config.fontSize ?? 36;
  let sketchName = config.sketch || 'random';
  let showColor = config.showColor ?? false;
  let colorFont = config.colorFont || 'Serif 16';

  let { W, H } = getMonitorSize();
  let palette = new Palette();
  let font = Pango.FontDescription.from_string(fontName);
  if (fontSize) font.set_size(fontSize * Pango.SCALE);

  // Fetch motto
  let motto = Motto.fetch();

  // Create PNG surface
  let surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, W, H);
  let cr = new Cairo.Context(surface);

  // Host object (mimics the extension's host interface)
  let host = { W, H, dark, level, font, palette };

  // 1. Paint background
  Draw.paint(Draw.BG, cr, Draw.BG.gen(host));

  // 2. Layout motto (sets Motto.area for sketch avoidance)
  let mottoData = Motto.get(motto, level, dark);
  let mottoLayout = Draw.Motto.gen(cr, mottoData, host);

  // 3. Generate and draw sketch
  let sketchIdx = pickSketch(dark, sketchName);
  let skt = getSketchModule(sketchIdx, dark);
  let colors = skt.dye(host);
  let pts = skt.gen(colors, host);
  Draw.paint(skt, cr, pts, { showColor, colorFont, dark });

  // 4. Draw motto on top
  Draw.paint(Draw.Motto, cr, mottoLayout, host);

  // 5. Write PNG
  // Re-checked here (cheap) as well as up front, so the window between
  // validating and writing stays as small as it can be.
  assertSafeCacheDir(cacheDir);
  let prefix = `wallpaper-${dark ? 'dark' : 'light'}`;
  let pngPath = GLib.build_filenamev([cacheDir, `${prefix}-${Date.now()}.png`]);
  surface.writeToPNG(pngPath);
  cr.$dispose();

  // Each generation needs a distinct filename: the Omarchy background plugin dedupes "set"
  // requests by exact path, so reusing a path would make the switch silently no-op. Prune
  // unconditionally (not gated on setWallpaper): keep the newest file per theme prefix plus
  // whatever the live background resolves to, so the cache never grows one PNG per run.
  pruneCache(cacheDir, prefix, GLib.path_get_basename(pngPath));

  print(`Generated: ${pngPath} (${W}x${H})`);
  return {
    png: pngPath,
    w: W,
    h: H,
    theme: dark ? 'dark' : 'light',
    sketch: SKETCH_NAMES[sketchIdx],
    font: fontName,
  };
}

const MAX_CONFIG_BYTES = 64 * 1024;

// Shared gate so a value cannot reach the renderer without passing the same
// checks as its CLI flag.
function validateConfig(config, origin) {
  const enums = {
    theme: ['dark', 'light', 'random'],
    orientation: ['horizontal', 'vertical'],
    sketch: ['wave', 'blob', 'oval', 'tree', 'cloud', 'random'],
  };
  for (let key of Object.keys(enums)) {
    if (config[key] === undefined) continue;
    if (typeof config[key] !== 'string' || !enums[key].includes(config[key])) {
      die(`${origin}: ${key} must be one of ${enums[key].join(', ')} (got: ${JSON.stringify(config[key])})`);
    }
  }
  if (config.fontSize !== undefined) {
    let n = Number(config.fontSize);
    if (!Number.isInteger(n) || n < 8 || n > 512) {
      die(`${origin}: fontSize must be an integer in 8..512 (got: ${JSON.stringify(config.fontSize)})`);
    }
    config.fontSize = n;
  }
  if (config.font !== undefined) {
    let fonts = Array.isArray(config.font) ? config.font : [config.font];
    if (fonts.length === 0 || !fonts.every(f => typeof f === 'string' && f.length > 0 && f.length <= 200)) {
      die(`${origin}: font must be a non-empty string, or an array of them, each at most 200 chars`);
    }
  }
  for (let key of ['showColor', 'setWallpaper', 'level']) {
    if (config[key] !== undefined && typeof config[key] !== 'boolean') {
      die(`${origin}: ${key} must be true or false (got: ${JSON.stringify(config[key])})`);
    }
  }
  if (config.colorFont !== undefined
      && (typeof config.colorFont !== 'string' || config.colorFont.length > 200)) {
    die(`${origin}: colorFont must be a string of at most 200 chars`);
  }
}

function parseArgs() {
  let config = {
    theme: 'random',
    level: true,
    orientation: 'horizontal',
    sketch: 'random',
    font: ['Serif'],
    fontSize: 36,
    showColor: false,
    setWallpaper: true,
  };

  // Opt-in --config <path>. Parsed first so its values are a base that explicit CLI flags
  // always override, regardless of argument order.
  for (let i = 0; i < ARGV.length; i++) {
    if (ARGV[i] === '--config') {
      let path = ARGV[i + 1];
      if (path === undefined || path.startsWith('--')) die('--config requires a file path');
      // Must be a regular file of sane size: --config /dev/zero hung forever,
      // because file_get_contents is unbounded and a character device never
      // ends.
      let info;
      try {
        info = Gio.File.new_for_path(path)
          .query_info('standard::type,standard::size', Gio.FileQueryInfoFlags.NONE, null);
      } catch (e) {
        die(`cannot read config file ${path}: ${e.message ?? e}`);
      }
      if (info.get_file_type() !== Gio.FileType.REGULAR) die(`config file ${path} is not a regular file`);
      if (info.get_size() > MAX_CONFIG_BYTES) {
        die(`config file ${path} is ${info.get_size()} bytes; limit is ${MAX_CONFIG_BYTES}`);
      }
      let loaded;
      try {
        loaded = T.readJSON(path);
      } catch (e) {
        die(`failed to load config file ${path}: ${e.message ?? e}`);
      }
      if (!loaded || typeof loaded !== 'object' || Array.isArray(loaded)) {
        die(`config file ${path} must contain a JSON object`);
      }
      Object.assign(config, loaded);
      // File values used to go straight through, skipping every check the
      // equivalent --flag performs: an unknown theme silently rendered light,
      // fontSize 100000 produced a libfreetype error, a numeric font threw an
      // uncaught exception.
      validateConfig(config, `config file ${path}`);
      break;
    }
  }

  for (let i = 0; i < ARGV.length; i++) {
    let a = ARGV[i];
    // fetch the next token as this flag's value, dying if missing
    let take = () => {
      let v = ARGV[++i];
      if (v === undefined || v.startsWith('--')) die(`missing value for ${a}`);
      return v;
    };
    switch (a) {
      case '--theme': {
        let v = take();
        if (v !== 'dark' && v !== 'light' && v !== 'random') die(`--theme must be dark, light or random, got: ${v}`);
        config.theme = v;
        break;
      }
      case '--orientation': {
        let v = take();
        if (v !== 'horizontal' && v !== 'vertical') die(`--orientation must be horizontal or vertical, got: ${v}`);
        config.orientation = v;
        config.level = v !== 'vertical';
        break;
      }
      case '--sketch': {
        let v = take();
        if (!(v in SKETCH_MAP) && v !== 'random') die(`--sketch must be wave, blob, oval, tree, cloud or random, got: ${v}`);
        config.sketch = v;
        break;
      }
      case '--font': config.font = take(); break;
      case '--font-size': {
        let v = take();
        let n = parseInt(v, 10);
        if (!/^\d+$/.test(v) || Number.isNaN(n) || n < 8 || n > 512) die(`--font-size must be an integer in 8..512, got: ${v}`);
        config.fontSize = n;
        break;
      }
      case '--color-font': config.colorFont = take(); break;
      case '--config': take(); break; // already handled in the pre-scan
      case '--dark': config.theme = 'dark'; break;
      case '--light': config.theme = 'light'; break;
      case '--random': config.theme = 'random'; break;
      case '--horizontal': config.orientation = 'horizontal'; config.level = true; break;
      case '--vertical': config.orientation = 'vertical'; config.level = false; break;
      case '--show-color': config.showColor = true; break;
      case '--no-show-color': config.showColor = false; break;
      case '--no-set': config.setWallpaper = false; break;
      case '--set-wallpaper': config.setWallpaper = true; break;
      case '--help':
        print(`omashuzhi - Generate wallpapers with Chinese poetry

Usage: gjs -m worker/main.js [OPTIONS]

Options:
  --theme MODE       Dark, light or random (default: random)
  --orientation DIR  horizontal or vertical (default: horizontal)
  --sketch TYPE      Sketch type: wave, blob, oval, tree, cloud, random (default)
  --font FONT        Font family name (or a list via --config)
  --font-size N      Font size in points (default: 36)
  --color-font DESC  Font for the color watermark on the Wave sketch
  --show-color       Show color name on the Wave sketch
  --no-show-color    Do not show the color name (default)
  --no-set           Generate only, don't set the wallpaper
  --set-wallpaper    Generate and set the wallpaper (default)
  --config PATH      Load base settings from a JSON file (CLI flags override it)
  --help             Show this help`);
        imports.system.exit(0);
      default:
        die(`unknown argument: ${a}`);
    }
  }
  validateConfig(config, 'configuration');
  return config;
}

// Main
let config = parseArgs();
let result = generate(config);
if (config.setWallpaper) {
  setWallpaper(result.png);
  print('Wallpaper updated.');
}
print(`RESULT ${JSON.stringify(result)}`);
