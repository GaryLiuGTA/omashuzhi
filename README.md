# Omashuzhi(数枝) — Chinese-poetry wallpapers for Omarchy

Omashuzhi is a native Omarchy 4.0 plugin that renders a Chinese-poetry wallpaper
(fetched from the jinrishici API) and sets it as your desktop background. A
popup on the bar icon edits every setting live — theme, layout, sketch, fonts,
refresh interval — and a `Refresh now` button re-renders on demand. The
interface is available in 简体中文 / 繁體中文 / English.

This is a fork of [hypr-shuzhi](https://github.com/GaryLiuGTA/hypr-shuzhi),
itself a port of the GNOME Shell extension
[tuberry/shuzhi](https://github.com/tuberry/shuzhi) to Hyprland. Unlike its
parent, it is a first-class Omarchy plugin: no install script, no systemd timer,
no hand-edited JSON.

![shuzhi](screenshots/hypr-shuzhi-3.png)

## Install

```bash
omarchy plugin add https://github.com/GaryLiuGTA/omashuzhi.git
omarchy bar move garyliu.omashuzhi-wallpaper --section right --before omarchy.bluetooth
```

Note that the repo is named `omashuzhi`, but `omarchy plugin add` names the
install directory from the manifest **id**, so the plugin lands in:

```
~/.config/omarchy/plugins/garyliu.omashuzhi-wallpaper/
```

Use that id path in any dev instructions — never the repo name.

## Removing

```bash
omarchy plugin remove garyliu.omashuzhi-wallpaper
```

That removes the widget from the bar and deletes the plugin directory. The
plugin keeps no state outside its own directory except two things you may want
to clean up yourself:

```bash
rm -rf ~/.cache/omashuzhi          # generated wallpapers
```

and, if the desktop background is still pointing at a generated image, pick a
new one with `omarchy-theme-bg-next` (or set any wallpaper) so the
`current/background` symlink stops referencing the deleted cache.

The plugin installs no systemd units and never writes outside
`~/.config/omarchy/shell.json` (its own settings entry), `~/.cache/omashuzhi`,
and the `current/background` symlink it is designed to set.

## Requirements

- **Omarchy 4.0 or newer. Only.** Pre-4.0 support (swaybg fallback, the old
  state-dir probe) was removed when this became a plugin.
- `gjs`, `fontconfig` (`fc-list`), and CJK fonts (e.g. `noto-fonts-cjk`).
- `jq` is used by `worker/list-fonts.sh` for the font picker.

## Settings

All settings live inline on the widget's `shell.json` entry and are edited from
the popup (or scalars from the CLI — see the note below).

| key | type | values | default |
|---|---|---|---|
| `theme` | string | `dark` \| `light` \| `random` — the **wallpaper's** palette | `dark` |
| `orientation` | string | `horizontal` \| `vertical` | `vertical` |
| `sketch` | string | `wave` \| `blob` \| `oval` \| `tree` \| `cloud` \| `random` | `random` |
| `fonts` | array of strings | Pango family names; one is picked at random each refresh | `["Serif"]` |
| `fontSize` | integer, pt | 8–512 | 96 |
| `showColor` | boolean | Wave sketch only — paints the colour's Chinese name | `false` |
| `setWallpaper` | boolean | `false` = render the PNG only, leave the background alone | `true` |
| `updateIntervalMin` | integer | `0` = off, otherwise 1–1440 | `30` |
| `language` | string | `zh-Hans` \| `zh-Hant` \| `en` \| `""` (auto) — popup UI only | `""` |

`sketch` is filtered by `theme`: dark offers Wave/Blob/Oval/**Cloud**, light
offers Wave/Blob/Oval/**Tree**, and random offers a single theme-dependent
"Tree / Cloud" entry. The stored value migrates in place on a theme switch
(`cloud` ⇄ `tree`); the two render identically, so the wallpaper never changes
as a side effect.

### Editing `fonts`

> **`omarchy bar set … --json` cannot store an array.** A single-element JSON
> array is unboxed to a string by the IPC layer, and a multi-element one errors
> out. The **popup is the only supported way to edit `fonts`** — do not rely on
> the `--json` path for it.

Scalar keys are fine from the CLI:

```bash
omarchy bar set garyliu.omashuzhi-wallpaper theme light
omarchy bar set garyliu.omashuzhi-wallpaper fontSize 120
omarchy bar set garyliu.omashuzhi-wallpaper updateIntervalMin 0
```

## Scheduling

Refreshes are driven by a timer inside the shell, not systemd. A 60-second tick
compares the current time against the last run (parsed from the newest PNG's
timestamped filename in `~/.cache/omashuzhi/`), firing when
`now − lastRun ≥ updateIntervalMin` minutes. `updateIntervalMin: 0` disables it.
Because the tick re-derives the delta every pass, it survives suspend/resume
without drift. There is no `.timer` unit — if you migrated from hypr-shuzhi,
disable and remove the old ones.

Manual refresh for a keybind:

```bash
omarchy-shell garyliu.omashuzhi-wallpaper refresh
```

## Migration from hypr-shuzhi

1. Stop and remove the old scheduler:
   ```bash
   systemctl --user disable --now hypr-shuzhi.timer
   systemctl --user disable --now hypr-shuzhi.service
   systemctl --user daemon-reload
   ```
2. Remove the old state, then the cache — **in that order**. The live
   `current/background` symlink still points into the cache, so deleting the
   cache first dangles the link and blacks the desktop:
   ```bash
   rm -rf ~/.local/share/hypr-shuzhi
   rm -rf ~/.cache/hypr-shuzhi   # delete this LAST
   ```
3. Install the plugin and pick your fonts. The shipped default is
   `["Serif"]`; this machine's ten families, ready to paste into the popup's
   font picker:
   ```json
   ["文道小纂体", "汉仪篆书繁", "汉仪中隶书繁", "Aa宋徽宗瘦金加粗版 (非商业使用)", "站酷庆科黄油体", "余繁新语", "演示佛系体", "钟齐志莽行书", "霞鹜文楷等宽", "得意黑"]
   ```

## Standalone worker usage

The rendering engine is a headless GJS process, runnable without the shell:

```bash
gjs -m worker/main.js --help          # all options
gjs -m worker/main.js --no-set --theme dark --sketch wave --font "霞鹜文楷等宽" --font-size 96
gjs -m worker/main.js --config /path/to/settings.json   # base settings from a JSON file (CLI flags override)
```

It writes timestamped PNGs to `~/.cache/omashuzhi/` and prints a
machine-readable `RESULT {…}` line after its human output. When the shell is
running, the service runs it under `flock` so a scheduler tick and a manual
refresh never render twice.

## Known limitations

- **A theme switch replaces the wallpaper.** `omarchy-theme-set` owns the same
  `current/background` symlink, so changing the desktop theme overwrites the
  Omashuzhi wallpaper until the next refresh.
- **An uninstalled font family falls back silently** in Pango. The popup flags
  configured-but-missing families as *not installed* (urgent colour) — that
  flag is the only way to find out.
- **`fc-list` emits one row per alias**, so one physical font can appear under
  both its CJK and Latin names in the picker.

## Credits

This project is a port of
[**tuberry/shuzhi**](https://github.com/tuberry/shuzhi) — the original GNOME
Shell extension by Tuberry — and depends on
[**xenv/gushici**](https://github.com/xenv/gushici), which powers the
`v1.jinrishici.com` API that `worker/motto.js` uses. Thank you both.

## Developing

Clone into `~/.config/omarchy/plugins/garyliu.omashuzhi-wallpaper/` and edit in
place. Note that saving a file triggers Omarchy's plugin watcher, but the bar
widget can keep running **stale compiled QML** — a save is not always enough.
After changing any `.qml`, run:

```bash
omarchy-restart-shell
omarchy plugin validate ~/.config/omarchy/plugins/garyliu.omashuzhi-wallpaper
journalctl --user -t omarchy-shell -f     # QML warnings and errors land here
```

The renderer is a plain GJS program and can be run on its own, without the
shell, which is the fastest way to iterate on drawing changes:

```bash
gjs -m worker/main.js --no-set --theme dark --sketch wave --font-size 96
```
