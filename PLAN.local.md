# omashuzhi — hypr-shuzhi as a native Omarchy 4.0 plugin

## Context

`hypr-shuzhi` is a GJS/Cairo app that renders a Chinese-poetry wallpaper and sets it as the Omarchy
background. It is entirely headless: settings live in a `config.json` that nothing ever writes, refresh
is a systemd timer templated at install time, and changing anything means hand-editing JSON and
re-running `install.sh`.

`omashuzhi` is a fork that becomes a **native Omarchy 4.0 plugin**: an icon on the right of the top bar
opening a popup where every setting is editable live, with a manual `Refresh Now` action and a localized
interface (简体 / 繁體 / English).

*This plan has been through one adversarial review round; findings are folded in and marked ⌂ where they
changed a decision.*

## Decisions confirmed with the user

| Question | Decision |
|---|---|
| Repo creation | GitHub **cannot** fork a repo into the account that owns it, and there are no orgs — `gh repo fork` is out. Clone with **full history**, push to a new `GaryLiuGTA/omashuzhi`. |
| Omarchy support | **4.0+ only.** Delete the swaybg fallback and the state-dir probe. |
| Bar icon | **Faithful vector redraw** — filled QML `Shape` closely tracing the source art's brush-C + scroll, including the stroke taper. Lettering dropped (illegible at 16px). |
| Language dropdown | **Popup UI only**; wallpaper poetry untouched. |
| Setting names | **Renamed for clarity**: `orientation`, `fonts`, `updateIntervalMin`. |
| Font removal | **Show all installed families**; Remove applies only to hand-typed entries. UI must say so. |
| Scheduling | **Shell timer only**, no systemd. |

## Architecture

| Question | Decision |
|---|---|
| Settings store | `~/.config/omarchy/shell.json`, inline on the widget entry — **single source**. Written via `bar.shell.updateEntryInline(...)`, which **merges then replaces**, so always patch a full copy. `fonts` is a real JSON array. `config.json` deleted. |
| Plugin kinds | ⌂ **`["service","bar-widget"]`.** The scheduler, worker `Process`, last-run probe and `IpcHandler` live in `Service.qml`; `Panel.qml` is pure UI reading `bar.shell.serviceFor("garyliu.omashuzhi-wallpaper")`. |
| ⌂ Service settings | **`Service.qml` reads its own entry out of `shell.shellConfig`** (`shell.qml:56`), it does **not** receive them by injection. |
| Worker invocation | `Process` (not `execDetached` — we need the exit code and stdout), argv `["flock","-n","-E","75",<lock>,"gjs","-m",<pluginDir>/worker/main.js, …flags]`, argv-exec'd with no shell. |
| Update interval | ⌂ **A 60s tick comparing `Date.now()` against the last-run epoch**, not a 30-minute `Timer`. |
| Repo layout | `manifest.json`, `Panel.qml`, `Service.qml`, `ShuzhiIcon.qml`, `Model.js` at the **root**; GJS sources `git mv src worker`. |

### ⌂ Why a `service` kind (replaces the per-monitor election)

Bar widgets are instantiated **once per monitor** (`Bar.qml:952-960`), so a widget-hosted timer would
fire N times. The shell already provides a singleton per plugin id — `shell.qml:275` `serviceFor()`,
`shell.qml:283` `ensureService()` — and the widget→service lookup pattern is already on this machine:

```qml
// ~/.config/omarchy/plugins/io.github.calebhat.weather/BarWidget.qml:9
readonly property var radar: bar && bar.shell ? bar.shell.serviceFor("io.github.calebhat.weather") : null
```

This deletes the primary-instance election, deletes the duplicate-`IpcHandler` wart, and gives one
`RESULT` parse instead of N. `flock` is kept anyway — two argv words, and it also covers the CLI path.

⌂ **But services are never injected with `settings`.** The shell injects only `omarchyPath`, `shell`,
`manifest`, `barWidgetRegistry`, `pluginRegistry` (`shell.qml:300-309`). The weather plugin works around
this by having its widget push settings into the service — which introduces a creation-order race the
plugin's own source warns about (`weather/Service.qml:33-40`: *"A widget is created before its settings
are injected, so `settings` is an empty object for the first moments of a session. That state is 'not
known yet', not 'alerts are off'."*). Firing the worker in that window would render a wallpaper with the
wrong theme and fonts.

**So `Service.qml` reads its own entry directly from `shell.shellConfig`** — walking `bar.layout.{left,
center,right}` for `id === "garyliu.omashuzhi-wallpaper"`. The service is given `shell`, and `shellConfig` is a plain
readable property that updates when the file reloads, so this is self-sufficient, race-free, and needs no
push from the Panel. It also makes step 7 verifiable on its own, before any UI exists.

⌂ Two rules make that safe:
- **The lookup must be a binding**, never a one-shot `Component.onCompleted` read. Services are created
  from `pluginsChanged` (`shell.qml:355-358`) while `shellConfig` is assigned from the `FileView` load
  (`shell.qml:136`), and the two are unordered — at construction `shellConfig` is still
  `builtinShellConfig`, which has no plugin entry. A latched "not found" would never arm the scheduler.
  Use a `readonly property` binding on `shell.shellConfig`.
- **The guard is "entry found" = not-known-yet.** `shellConfig` is never half-populated: it is replaced
  wholesale or falls back wholesale (`shell.qml:72-87`, "we do not deep-merge"), so a parse failure yields
  defaults, not a fragment. ⌂ But note `plugin enable` writes a **bare** `{ id }` entry
  (`PluginRegistry.qml:503`), so the guard passes immediately with no settings in it. That is intended:
  a wallpaper appears on first enable, rendered with the plugin's own defaults, before the popup is ever
  opened.

## Verified constraints

Checked in source. The ones that changed the design are marked ⌂.

1. **The shell is Quickshell/QML** — GJS cannot be a plugin; it stays a worker process.
2. **A plugin is a git repo with `manifest.json` at its root**; `omarchy plugin add` clones it to
   `~/.config/omarchy/plugins/<id>/` and **hard-fails if that dir already exists**. **No symlinks**
   anywhere (except under `.git`). Id must not start with `omarchy.` → `garyliu.omashuzhi-wallpaper`.
3. **`manifest.barWidget.defaults`/`schema` are inert** — the only reference in the whole tree is
   `shell.qml:694-696` copying them into meta. **The QML must supply every default itself.**
4. **Inline-settings writes do not rebuild the widget** — `Bar.qml:376-387` patches `item.settings` in
   place, so persisting will not restart timers.
5. ⌂ **`omarchy-shell -q` exits 0 on every failure path** (`/usr/bin/omarchy-shell:13-18`:
   `fail() { (( QUIET )) && exit 0; … }`). The current worker call at `src/main.js:83` passes `-q`, so a
   failed background-set is invisible. **Drop `-q`.** Even then `background set` is `void` and accepts a
   nonexistent path, so a non-zero exit only ever means "shell down / not ready" — never "the image
   didn't apply". Document that limit rather than implying end-to-end verification.
6. **`Background.qml` dedupes by resolved path** and re-reads the symlink only on IPC or startup — no
   polling. Timestamped filenames are load-bearing.
7. **Hot reload is Omarchy's own** (`inotifywait`, debounced); `.git/` is ignored, so developing in place
   with git inside the plugin dir is safe.
8. **`omarchy bar set <id> <key> <value> --json` exists** and stores a real JSON array (`omarchy-bar:344-358`).
9. ⌂ **`Dropdown`/`MultiSelect` have no production precedent inside a bar popup.** Their only consumer is
   `plugins/dev-gallery/GalleryPanel.qml`, which is a `FloatingWindow`, not layer-shell. Both open a
   QtQuick.Controls `Popup` that reparents to the window `Overlay` (`Dropdown.qml:145`,
   `MultiSelect.qml:334`), while `KeyboardPanel`'s `dismissArea` fills the screen and closes on any click
   it receives (`KeyboardPanel.qml:104-127,280-334`). A leaked press would close the whole panel.
   **Mitigated by a spike before the UI is built** (step 6 below), with inline controls as the fallback.
10. ⌂ **`MultiSelect` ignores `options` changes while `optionsCommand` is set** —
    `MultiSelect.qml:212`: `onOptionsChanged: if (arrayFrom(optionsCommand).length === 0) rebuildFromStatic()`.
    Adding a font therefore requires an explicit `fontSelect.refresh()`. `refresh()` re-runs `fc-list`, so
    batch it and gate it on first popup open (it otherwise fires at shell startup, once per monitor).
11. ⌂ **`NumberField.modified(int)` fires on every click** (`NumberField.qml:56`), and each persist is an
    atomic `shell.json` write that the watching `FileView` reloads. Holding a spin arrow would rewrite the
    file at key-repeat rate. **Debounce 300–500ms between control signal and persist.**
12. ⌂ **The worker's flag surface is incomplete**: no `--theme`, no `--color-font`, and `--show-color` /
    `--no-set` are one-way (`main.js:213,223`) — they cannot express `false` against a true default.
    Worker defaults (`theme:'random'`, `level:true`, `fontSize:36`) also differ from the plugin's.
    **Fix: the QML passes every setting explicitly on every run, and the worker gains the missing flags
    plus their negative forms**, so worker defaults never apply in plugin use.
13. **`ShuzhiIcon` must use a *filled* `ShapePath`, not a stroked arc.** ⌂ The source stroke is a tapered
    calligraphic brush — thick at entry, hairline at the tail. A stroked `PathAngleArc` has uniform
    `strokeWidth` and would render a generic "C". `DropboxIcon.qml:36-43` shows the technique: filled
    `ShapePath` with `strokeWidth: 0`. `QtQuick.Shapes` is importable in plugins (`Background.qml:6`).
14. **`garyliu.lunar-calendar` is the template** for persistence (`Panel.qml:129-138`) and for the
    `zh-Hans`/`zh-Hant`/`en` i18n map + `Qt.locale()` detection.
15. **`Panel` supplies no geometry** — it is a bare `Item`, and `ModuleSlot` reads `implicitWidth`
    (`Bar.qml:1560-1561`). Set `implicitWidth/Height` from the button or the widget is 0×0.
16. Current machine: `hypr-shuzhi.timer` not-found, service disabled, `current/background` → a live
    `~/.cache/hypr-shuzhi/…png`. All 10 configured families are installed.

## Settings keys

| key | type | values | default |
|---|---|---|---|
| `theme` | string | `dark`\|`light`\|`random` — ⌂ **the wallpaper's palette**, not the popup's | `dark` |
| `orientation` | string | `horizontal`\|`vertical` (was `level` bool) | `vertical` |
| `sketch` | string | `wave`\|`blob`\|`oval`\|`tree`\|`cloud`\|`random` — **offered per theme**, see below | `random` |
| `fonts` | array of strings | Pango family names | ⌂ `["Serif"]` |
| `fontSize` | integer, pt | 8–512 | 96 |
| `showColor` | bool | Wave sketch only | `false` |
| ~~`colorFont`~~ | — | ⌂ **Not exposed.** See below. | — |
| `setWallpaper` | bool | false = render PNG only | `true` |
| `updateIntervalMin` | integer, min | 0 = off, else 1–1440 | 30 |
| `language` | string | `zh-Hans`\|`zh-Hant`\|`en`\|`""` (auto) | `""` |

⌂ The `fonts` default is `["Serif"]`, **not** this machine's ten families — a public plugin must not ship
a font set only one machine has, or every other user silently gets Pango fallback. The ten go in the
README's migration block instead, ready to paste.

No `lastRunAt` key — it is *discovered* from the newest PNG's embedded epoch in `~/.cache/omashuzhi/`
(`main.js` already stamps `Date.now()` into the filename). Self-healing, survives reinstall, and feeds
the popup's "Last: 14:32" line. ⌂ On a fresh install the cache dir does not exist: absent or unparseable
⇒ **treat as due**, firing once after the startup grace.

### ⌂ Naming and the meaning of `theme`

⌂ The romanization is **omashuzhi** (omarchy + shuzhi) — not "omazhuzhi". Every identifier below uses it.
The Chinese name is **数枝** (traditional **數枝**); use it as the popup title in the zh dictionaries —
do not invent a descriptive name.

| Where | Value | Read by |
|---|---|---|
| `manifest.id` | `garyliu.omashuzhi-wallpaper` | ⌂ the address: install dir, `shell.json` key, every CLI command, `serviceFor()`, IPC target. The `-wallpaper` suffix tells a browsing user what it does. |
| Repo | `GaryLiuGTA/omashuzhi` | what people paste into `omarchy plugin add` |
| `manifest.name` | ⌂ `Omashuzhi(数枝)` | `omarchy plugin list`; fallback for `displayName` |
| `barWidget.displayName` | ⌂ `Omashuzhi(数枝)` | the bar-widget picker — the name a user sees when adding it |
| popup title | `数枝` / `數枝` / `Omashuzhi` | inside the popup, per the language setting |

⌂ **The repo name and the plugin id deliberately differ.** `omarchy plugin add` names the install
directory from the **manifest id**, so cloning `omashuzhi` yields
`~/.config/omarchy/plugins/garyliu.omashuzhi-wallpaper/`. That is expected, not a mistake — but it means
the README's dev instructions must use the id path, never the repo name.

Other spellings that follow from the rename: cache dir `~/.cache/omashuzhi/`, lock file
`omashuzhi.lock`, and the QML file `ShuzhiIcon.qml` (unchanged — it names the mark, not the plugin).

⌂ The picker shows the bilingual form **`Omashuzhi(数枝)`** — exactly that string, no space before the
bracket. `manifest.name` carries the same value so `omarchy plugin list` and the picker agree. These are
static JSON and cannot follow the popup's language setting, which is why the bilingual form is used here
while the popup title alone localizes.

`theme` sets the **wallpaper's** colour scheme. It has nothing to do with the popup's own appearance,
which comes from the Omarchy shell theme via the `Color` singleton and changes only when the desktop
theme changes. The UI must not blur these: label the control **"Wallpaper theme" / 壁纸配色**, and group
it under a **Wallpaper / 壁纸** section header alongside layout, sketch, font size and fonts, so it reads
as "what gets drawn", not "how this window looks".

### ⌂ Sketch options are filtered to the wallpaper theme

Not every sketch exists in both themes. `main.js:21-22` defines
`DARK_SKETCHES = [WAVE, BLOB, OVAL, CLOUD]` and `LIGHT_SKETCHES = [WAVE, BLOB, OVAL, TREE]`, and
`main.js:53-54` maps **both** `TREE` and `CLOUD` to `dark ? Draw.Cloud : Draw.Tree`. So there are only
ever four distinct sketches per theme, and the fourth one *is* Tree in light and Cloud in dark — picking
"tree" under a dark theme silently renders Cloud.

The dropdown therefore offers exactly what the current theme can draw:

| wallpaper `theme` | offered |
|---|---|
| `dark` | Wave, Blob, Oval, **Cloud**, Random |
| `light` | Wave, Blob, Oval, **Tree**, Random |
| `random` | Wave, Blob, Oval, **Tree / Cloud** (one entry, labelled as theme-dependent), Random |

The list rebinds when `theme` changes. Because `tree` and `cloud` resolve to the same module, a stored
value is **migrated in place** on a theme switch (`cloud` ⇄ `tree`) so the dropdown never displays an
option the theme cannot draw, and the rendering never changes as a side effect. The worker's mapping is
upstream shuzhi's and stays untouched.

### ⌂ `colorFont` is not exposed

It sets the font for the Chinese colour *name* painted at 10% alpha in the top panel — Wave sketch only,
and only when `showColor` is on (`draw.js:261-266`). It is absent from `config.json` entirely (an
undocumented `'Serif 16'` default in code), and `draw.js:263` overrides its size with
`font.set_size(x * Pango.SCALE / 15)`, so only the family ever takes effect. A font picker for a
barely-visible watermark is clutter. The worker keeps its default and its `--color-font` flag for CLI
use; the popup does not show it. Restoring it later is a two-line change.

## Final repo tree

```
omashuzhi/                     (= ~/.config/omarchy/plugins/garyliu.omashuzhi-wallpaper)
├── manifest.json      NEW   kinds: ["service","bar-widget"], defaultSection: "right"
├── Panel.qml          NEW   barWidget entry point: icon + popup (pure UI)
├── Service.qml        NEW   scheduler, worker Process, last-run probe, IpcHandler
├── ShuzhiIcon.qml     NEW   filled-Shape monochrome mark, theme-tinted
├── Model.js           NEW   i18n dictionary + pure helpers (no QML types)
├── worker/
│   ├── main.js        MOVED from src/ (git mv) + edited
│   ├── draw.js  motto.js  color.js  colors.js  util.js   MOVED, unchanged
│   └── list-fonts.sh  NEW   installed families as JSON, CJK first
├── screenshots/       KEPT
├── LICENSE            NEW   GPL-3.0-or-later
├── README.md          REWRITTEN
└── .gitignore         NEW

DELETED: install.sh, systemd/, config.json, src/
```

`defaultSection: "right"` is required — without it every end-user install lands in `center`
(`omarchy-plugin-add:47-52`).

## Implementation order

Each step is verifiable before the next.

1. **Commit the pending fixes to hypr-shuzhi and push.** `src/{draw,main,motto}.js` are complete and
   working; leaving them uncommitted would leave upstream broken (its committed `main.js` writes a fixed
   filename, which the 4.0 background dedupe silently ignores).
2. **Create the fork.** `gh repo create GaryLiuGTA/omashuzhi --public`, then
   `git clone https://github.com/GaryLiuGTA/hypr-shuzhi.git ~/.config/omarchy/plugins/garyliu.omashuzhi-wallpaper`,
   repoint origin, `git push -u origin main`. Cloning straight into the plugins dir is deliberate: it is
   the documented dev location and hot-reload works immediately. ⌂ Consequence to state in the README:
   because `omarchy plugin add` refuses a pre-existing dir, the documented install path can never be
   self-tested on this machine — verify it by validating the manifest and reading the clone logic.
   `/home/garyliu/hypr-shuzhi` receives the step-1 commit and is then **retired**, not kept in sync.
3. `git mv src worker`; `git rm install.sh systemd/* config.json`; add `LICENSE`, `.gitignore`, and a
   ⌂ **stub `Service.qml` (`Item {}`)** — `omarchy-plugin-validate` fails a declared kind whose entry-point
   file is missing, so the stub must exist before step 5 validates.
4. **Edit `worker/main.js`**, then verify standalone before any QML exists:
   - delete `getOmarchyStateDir()` and the swaybg fallback; hardcode `~/.local/state/omarchy/current/background`
   - ⌂ drop `-q` from the `omarchy-shell background set` call; `imports.system.exit(3)` on failure
     (valid under `gjs -m`; verified)
   - remove the implicit config load; add opt-in `--config <path>` (CLI flags still win)
   - ⌂ add `--theme`, `--orientation`, `--color-font`, and negative forms `--no-show-color`,
     `--set-wallpaper`, so every setting is expressible in both directions
   - harden arg parsing: die on unknown args **and on missing values**
   - cache dir → `~/.cache/omashuzhi`; keep timestamped filenames (load-bearing). ⌂ **Make pruning
     unconditional** — keep the newest file per theme prefix **plus** whatever `current/background`
     resolves to. Today it is gated on `setWallpaper` (`main.js:168`) because deleting the live target
     blacks the desktop; skipping the resolved target addresses that directly, and stops the cache
     growing one PNG per run now that the popup exposes a `setWallpaper` toggle. ⌂ Note the steady state
     is **≤2 files per prefix, not 1**: pruning runs before the symlink is repointed (`main.js:168` then
     `:251`), so the live file and the new one both survive that pass; the stale one goes next run.
   - emit a final machine-readable `RESULT {json}` line after the existing human `print()`s
   - verify: `gjs -m worker/main.js --no-set --theme dark --sketch wave --font "霞鹜文楷等宽" --font-size 96`
5. `manifest.json` + stub `Panel.qml` (icon only, `implicitWidth/Height` from the button). Validate,
   rescan, enable. **Get the icon right here**: trace the filled outline against a reference crop
   (`magick <src> -crop 460x430+480+165 +repage -fuzz 45% -fill none -floodfill +0+0 "#2b2b2b" -resize 256x256`
   into a scratch dir, **not** the repo), check with `OMARCHY_DEBUG_BAR_ICONS=1` and against neighbouring
   bar glyphs, and confirm it retints on theme switch.
6. ⌂ **Spike the popup controls (30 min, before any real UI)** — and it must come *after* step 5, because
   `KeyboardPanel.anchorItem` and `bar` are `required property` (`KeyboardPanel.qml:40-41`) and only exist
   once a bar widget is mounted. One `Dropdown` + one `MultiSelect` in a throwaway panel on the stub
   widget: open, pick, dismiss. If their `Popup` fights the panel's `dismissArea`, fall back to inline
   controls (`ButtonGroup` + a checkbox `Repeater`) — arguably closer to "a list of checkboxes" anyway.
   Gate `PanelKeyCatcher.blocked` on `popupOpen` either way.
7. `Service.qml`: reads its entry from `shell.shellConfig`; worker `Process` + `StdioCollector` +
   `onExited`; `flock` at ⌂ `Quickshell.env("XDG_RUNTIME_DIR") + "/omashuzhi.lock"` (argv is exec'd with
   no shell, so `$VAR` would not expand),
   ⌂ plugin dir resolved as `String(Qt.resolvedUrl("worker/main.js")).replace(/^file:\/\//, "")` — nothing
   injects a path, and `Quickshell.env("OMARCHY_PATH")` is useless for third-party plugins. `IpcHandler`
   for `omarchy-shell garyliu.omashuzhi-wallpaper refresh`. Exit **75** = flock conflict → "already running",
   benign. ⌂ Because the service reads `shellConfig` itself, this step is **independently verifiable**:
   set values with `omarchy bar set …`, trigger over IPC, confirm an end-to-end wallpaper change — all
   before any popup exists. ⌂ `Panel.ipcTarget` stays **empty** so `Ui/Panel.qml`'s own handler
   (`manageIpc: true` by default, live whenever `ipcTarget !== ""`) does not collide per-monitor with the
   service's. Popup-by-keybind remains `omarchy-shell shell toggle garyliu.omashuzhi-wallpaper`.
8. `Model.js` (helpers, English only) + popup: hero, Refresh button, status line.
9. Controls, in order, each persisting through a debounced full-copy patch: ButtonGroups (theme,
   orientation) → sketch (⌂ theme-filtered, with the `tree` ⇄ `cloud` migration on theme change) →
   NumberFields (fontSize, interval) → Toggles (showColor, setWallpaper) → font list.
10. ⌂ Font list: `MultiSelect` populated by `worker/list-fonts.sh` via `optionsCommand`
    (`["bash", <pluginDir>/worker/list-fonts.sh]` — explicit interpreter, don't rely on the exec bit),
    gated on first open. A `TextField` + Add for hand-typed families, each followed by
    `fontSelect.refresh()`. **Remove applies only to hand-typed entries** — installed families reappear on
    rescan by design — and the UI says so. Configured-but-missing families are flagged in the urgent
    color, since Pango falls back silently and that flag is the only way the user finds out.
11. Scheduler in `Service.qml`: 60s tick vs. the last-run epoch, `updateIntervalMin: 0` = off, ~45s
    startup grace (the worker's `hyprctl` retry loop can block 10s after login).
12. zh-Hans / zh-Hant dictionaries + language `Dropdown`; check the panel width fits the longest CJK labels.
13. README, screenshots, push.

## Key implementation notes

- ⌂ **Persist from the control's own signal**, not via `Connections` — `changed(values)` already hands you
  the new array. Re-assign `values` from `settings` on open. `MultiSelect.toggleValue` assigns
  `root.values` internally (`MultiSelect.qml:111-119`), so a declarative binding would die after the first
  click either way.
- **Always patch a full copy** before `updateEntryInline` — it replaces the entry, so a partial patch
  wipes every unlisted key.
- ⌂ **`worker/util.js` pollutes `Object.prototype`** with getters. **No worker JS may ever be imported into
  QML** — it would leak across the whole shell process. `Model.js` duplicates a few trivial helpers
  deliberately; do not "DRY" them together.
- **Migration** (README + a one-time run): disable/remove the old units, `rm -rf ~/.local/share/hypr-shuzhi`,
  then **delete `~/.cache/hypr-shuzhi` last** — the live `current/background` symlink still points into it,
  so deleting it earlier dangles the link and blacks the desktop.

## README

Rewritten around the plugin: install via `omarchy plugin add`, requirements (Omarchy 4.0+ only, `gjs`,
`jq`, `fontconfig`, CJK fonts), the settings table, the `fonts`-is-an-array note (editable in the popup or
via `omarchy bar set … --json`; absent from `manifest.schema` because schema v1 has no array type),
shell-timer scheduling, the migration block (⌂ including this machine's ten CJK families, ready to paste,
since the shipped default is `["Serif"]`), `omarchy-shell -q garyliu.omashuzhi-wallpaper refresh` for keybinds,
standalone worker usage, and known limitations (a theme switch replaces the wallpaper until the next
refresh; uninstalled families fall back silently; `fc-list` emits one row per alias so one font can appear
under both its CJK and Latin names).

**Credits, made prominent**: [tuberry/shuzhi](https://github.com/tuberry/shuzhi) — the original GNOME Shell
extension this is ported from — and [xenv/gushici](https://github.com/xenv/gushici), which powers the
`v1.jinrishici.com` API that `worker/motto.js` uses.

## Verification

```bash
omarchy plugin validate ~/.config/omarchy/plugins/garyliu.omashuzhi-wallpaper   # exit 0
omarchy-shell shell rescanPlugins
omarchy plugin enable garyliu.omashuzhi-wallpaper --section right
omarchy bar move garyliu.omashuzhi-wallpaper --section right --before omarchy.bluetooth

journalctl --user -t omarchy-shell -f        # QML warnings/errors land here

# settings round-trip
omarchy bar set garyliu.omashuzhi-wallpaper fonts '["得意黑","霞鹜文楷等宽"]' --json
jq '.bar.layout.right[] | select(.id=="garyliu.omashuzhi-wallpaper")' ~/.config/omarchy/shell.json
# toggle a checkbox in the popup, re-read: the array must reflect it, and no other key may vanish

# did the wallpaper ACTUALLY change
readlink -f ~/.local/state/omarchy/current/background    # note it
# click Refresh Now (or, WITHOUT -q so failures are visible: omarchy-shell garyliu.omashuzhi-wallpaper refresh)
readlink -f ~/.local/state/omarchy/current/background    # must be a NEW …-<epoch>.png
ls -lt ~/.cache/omashuzhi/                               # newest matches; ≤2 per prefix (live + new)
# and look at the desktop: a new poem in one of the selected families

# concurrency guard: second run exits 75 -> "already running", not an error
omarchy-shell garyliu.omashuzhi-wallpaper refresh & omarchy-shell garyliu.omashuzhi-wallpaper refresh

omarchy-restart-shell                        # icon returns, timer re-arms from the PNG timestamp
```

`omarchy dev ui-preview` is the live component gallery; `OMARCHY_DEBUG_BAR_ICONS=1` draws icon optical bounds.

## Risks

1. ⌂ **Control popups inside a layer-shell panel are unproven** (constraint 9). Retired by the step-6 spike
   before any UI is committed; inline controls are the fallback.
2. **The icon still needs iteration** — a filled outline traced by eye against the reference crop. Budget
   2–3 rounds. It is a redraw, not the bitmap: faithful to the silhouette, not pixel-identical.
3. **Multi-monitor is untestable here** (one screen). The `service` kind removes the duplication problem
   by construction; `flock` covers the rest.
4. **Worker latency** — an HTTP POST plus a full-resolution Cairo render takes seconds, up to 10s more if
   `hyprctl monitors -j` needs its retry loop after login. Hence the spinner and the startup grace. No
   process watchdog in v1 (a kill would leave a half-written PNG); a ~90s watchdog is a fair follow-up.
5. **A background-set failure is only partially detectable** (constraint 5) — "shell not ready" is caught,
   "image didn't apply" is not.
6. **Theme switches clobber the wallpaper** (`omarchy-theme-set` owns the same symlink). Documented, not solved.
