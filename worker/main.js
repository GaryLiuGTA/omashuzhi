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
  // Remove existing symlink/file and create new symlink
  let linkFile = Gio.File.new_for_path(STATE_BACKGROUND);
  try { linkFile.delete(null); } catch (e) { /* ok */ }
  linkFile.make_symbolic_link(pngPath, null);

  // Omarchy >= 4.0 renders the background via the omarchy-shell (Quickshell), not swaybg.
  // Invoked via absolute path since keybind-triggered execs run under Hyprland's own $PATH,
  // which doesn't include /usr/share/omarchy/bin. No -q: it masks failures (omarchy-shell -q
  // exits 0 on every failure path), so exit(3) here means "shell down / not ready".
  try {
    T.execute(`/usr/bin/omarchy-shell background set ${GLib.shell_quote(pngPath)}`);
  } catch (e) {
    imports.system.exit(3);
  }
}

function resolveTheme(config) {
  let theme = config.theme ?? (config.dark != null ? (config.dark ? 'dark' : 'light') : 'dark');
  if (theme === 'random') return Math.random() < 0.5;
  return theme === 'dark';
}

function pruneCache(cacheDir, prefix) {
  // Never delete whichever file the live background symlink currently resolves to —
  // deleting it out from under the link leaves a dangling link (black desktop).
  let livePath = null;
  try {
    livePath = T.execute(`readlink -f ${GLib.shell_quote(STATE_BACKGROUND)}`);
  } catch (e) { /* no live link yet — nothing to protect */ }

  let dir = Gio.File.new_for_path(cacheDir);
  let enumerator = dir.enumerate_children('standard::name', Gio.FileQueryInfoFlags.NONE, null);
  let info;
  let candidates = [];
  while ((info = enumerator.next_file(null))) {
    let name = info.get_name();
    if (name.startsWith(prefix)) candidates.push(name);
  }

  // Filenames are wallpaper-<theme>-<epoch>.png; the epoch is fixed-width, so lexical
  // ordering is chronological. Keep the newest, plus the live file, drop the rest.
  candidates.sort();
  let newest = candidates.length ? candidates[candidates.length - 1] : null;
  for (let name of candidates) {
    let path = GLib.build_filenamev([cacheDir, name]);
    if (name === newest) continue;
    if (livePath && path === livePath) continue;
    GLib.unlink(path);
  }
}

function generate(config) {
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
  let cacheDir = GLib.build_filenamev([GLib.get_home_dir(), '.cache', 'omashuzhi']);
  T.ensureDir(cacheDir);
  let prefix = `wallpaper-${dark ? 'dark' : 'light'}`;
  let pngPath = GLib.build_filenamev([cacheDir, `${prefix}-${Date.now()}.png`]);
  surface.writeToPNG(pngPath);
  cr.$dispose();

  // Each generation needs a distinct filename: the Omarchy background plugin dedupes "set"
  // requests by exact path, so reusing a path would make the switch silently no-op. Prune
  // unconditionally (not gated on setWallpaper): keep the newest file per theme prefix plus
  // whatever the live background resolves to, so the cache never grows one PNG per run.
  pruneCache(cacheDir, prefix);

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
      try {
        Object.assign(config, T.readJSON(path));
      } catch (e) {
        die(`failed to load config file ${path}: ${e.message ?? e}`);
      }
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
      case '--sketch': config.sketch = take(); break;
      case '--font': config.font = take(); break;
      case '--font-size': config.fontSize = parseInt(take(), 10); break;
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
