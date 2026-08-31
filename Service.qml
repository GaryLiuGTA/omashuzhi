import QtQuick
import Quickshell
import Quickshell.Io

// Headless singleton behind Omashuzhi(数枝).
//
// The bar widget is instantiated once per monitor, so the worker scheduler,
// the last-run probe and the IPC surface live here: the shell mounts exactly
// one service per plugin, which keeps a multi-monitor setup from running the
// wallpaper worker N times. The worker itself stays a GJS process (the shell
// is Quickshell/QML, not GJS).
//
// Settings are read directly out of this plugin's own shell.json layout entry
// (walking bar.layout.{left,center,right} for our id) rather than by
// injection — the shell never injects `settings` into services, and reading
// shellConfig means the service stays race-free with the widget creation
// order and updates when the file reloads. The lookup is a binding, not a
// one-shot read, because services are created from pluginsChanged while
// shellConfig is assigned from the FileView load and the two are unordered.
Item {
  id: root

  // Injected by the shell (shell.qml: ensureService).
  property var shell: null

  readonly property string pluginId: "garyliu.omashuzhi-wallpaper"
  readonly property string lockPath: Quickshell.env("XDG_RUNTIME_DIR") + "/omashuzhi.lock"
  readonly property string workerMain: String(Qt.resolvedUrl("worker/main.js")).replace(/^file:\/\//, "")

  // The live shell.json layout entry for this plugin, or null until one
  // exists. A bare `{ id }` entry (what `plugin enable` writes) satisfies the
  // guard, so a wallpaper appears on first enable using the defaults below.
  readonly property var entry: {
    if (!shell || !shell.shellConfig || typeof shell.shellConfig !== "object") return null
    var config = shell.shellConfig
    if (!config.bar || !config.bar.layout) return null
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var arr = config.bar.layout[sections[s]]
      if (!arr || !Array.isArray(arr)) continue
      for (var i = 0; i < arr.length; i++) {
        var e = arr[i]
        if (e && String(e.id || "") === root.pluginId) return e
      }
    }
    return null
  }

  // Resolved settings, surfaced so the popup (step 8+) can read them through
  // bar.shell.serviceFor(). Defaults match the plugin's settings table.
  readonly property string theme: String(setting("theme", "dark"))
  readonly property string orientation: String(setting("orientation", "vertical"))
  readonly property string sketch: String(setting("sketch", "random"))
  readonly property var fonts: setting("fonts", ["Serif"])
  readonly property int fontSize: Math.max(8, Math.min(512, Math.round(Number(setting("fontSize", 96)) || 96)))
  readonly property bool showColor: setting("showColor", false) === true
  readonly property bool setWallpaper: setting("setWallpaper", true) !== false
  readonly property int updateIntervalMin: Math.max(0, Math.min(1440, Math.round(Number(setting("updateIntervalMin", 30)) || 0)))
  readonly property string language: String(setting("language", ""))

  function setting(name, fallback) {
    var e = root.entry
    if (!e) return fallback
    var v = e[name]
    return v === undefined || v === null ? fallback : v
  }

  // ---------------------------------------------------------------------------
  // Worker process
  // ---------------------------------------------------------------------------

  readonly property bool busy: workerProc.running

  property var lastResult: null
  property string lastError: ""
  property double lastRunAt: 0
  property string _stderrBuffer: ""

  // flock -n -E 75: a concurrent run (scheduler + manual refresh landing on
  // top of each other) makes the second one exit 75 rather than render twice.
  // Exit 75 is benign — "already running" — not an error.
  function workerArgv() {
    var args = ["flock", "-n", "-E", "75", root.lockPath, "gjs", "-m", root.workerMain]
    args.push("--theme", String(root.theme))
    args.push("--orientation", String(root.orientation))
    args.push("--sketch", String(root.sketch))
    var families = Array.isArray(root.fonts) ? root.fonts : [root.fonts]
    var font = families.length > 0 ? families[Math.floor(Math.random() * families.length)] : "Serif"
    args.push("--font", String(font))
    args.push("--font-size", String(root.fontSize))
    args.push(root.showColor ? "--show-color" : "--no-show-color")
    args.push(root.setWallpaper ? "--set-wallpaper" : "--no-set")
    return args
  }

  function refresh() {
    if (workerProc.running) return
    root._stderrBuffer = ""
    workerProc.command = root.workerArgv()
    workerProc.running = true
  }

  // The worker emits a machine-readable final line after its human output.
  function parseWorkerOutput(raw) {
    var text = String(raw || "")
    var idx = text.lastIndexOf("RESULT ")
    if (idx === -1) return
    var json = text.substring(idx + "RESULT ".length).trim()
    try {
      root.lastResult = JSON.parse(json)
      root.lastRunAt = Date.now()
      root.lastError = ""
    } catch (e) {
      // Malformed RESULT: keep the previous result rather than clobber it.
    }
  }

  function elideStderr(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 200 ? value.substring(0, 197) + "…" : value
  }

  Process {
    id: workerProc
    command: []
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseWorkerOutput(String(text || ""))
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._stderrBuffer += String(text || "")
    }

    onExited: function(exitCode) {
      if (exitCode === 75) {
        root.lastError = "already running"
        return
      }
      if (exitCode !== 0) {
        root.lastError = root.elideStderr(root._stderrBuffer) || "worker exited " + exitCode
      }
    }
  }

  function status() {
    return JSON.stringify({
      running: workerProc.running,
      theme: root.theme,
      orientation: root.orientation,
      sketch: root.sketch,
      fonts: root.fonts,
      fontSize: root.fontSize,
      showColor: root.showColor,
      setWallpaper: root.setWallpaper,
      updateIntervalMin: root.updateIntervalMin,
      language: root.language,
      lastResult: root.lastResult,
      lastError: root.lastError,
      lastRunAt: root.lastRunAt
    })
  }

  IpcHandler {
    target: "garyliu.omashuzhi-wallpaper"

    function refresh(): void { root.refresh() }
    function status(): string { return root.status() }
  }
}
