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
  readonly property string runBounded: String(Qt.resolvedUrl("worker/run-bounded.sh")).replace(/^file:\/\//, "")

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
  // Explicit, opt-in consent before we ever touch the desktop background.
  // Defaults FALSE: enabling the plugin must not silently replace the user's
  // wallpaper. Until the popup's consent prompt is accepted, the worker runs
  // with --no-set (render only) and the scheduler stays parked.
  readonly property bool wallpaperConsent: setting("wallpaperConsent", false) === true
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

  // Deadlines. The worker does an HTTP fetch plus a full-resolution Cairo
  // render, so it is legitimately slow; 120s is generous but finite. The QML
  // watchdogs are a backstop for the case where `timeout` itself never
  // reports back (process gone, pipe wedged) — they SIGKILL and clear state so
  // a stuck run can never wedge every future refresh.
  readonly property int workerTimeoutSec: 120
  readonly property int workerWatchdogMs: (workerTimeoutSec + 15) * 1000
  readonly property int probeWatchdogMs: 20000
  // StdioCollector has no length limit, so cap what we retain and parse.
  readonly property int maxWorkerOutputBytes: 64 * 1024
  readonly property int maxStatusChars: 200

  function clampText(raw, max) {
    var t = String(raw || "")
    return t.length > max ? t.slice(0, max) + "… (truncated)" : t
  }

  Timer {
    id: workerWatchdog
    interval: root.workerWatchdogMs
    repeat: false
    onTriggered: {
      if (!workerProc.running) return
      console.warn("omashuzhi: worker exceeded " + root.workerWatchdogMs + "ms; killing")
      try { workerProc.signal(9) } catch (e) { }
      workerProc.running = false   // `busy` is bound to this, so it clears too
      root.lastError = "timed out"
    }
  }

  Timer {
    id: probeWatchdog
    interval: root.probeWatchdogMs
    repeat: false
    onTriggered: {
      if (!probeProc.running) return
      try { probeProc.signal(9) } catch (e) { }
      probeProc.running = false
    }
  }

  // flock -n -E 75: a concurrent run (scheduler + manual refresh landing on
  // top of each other) makes the second one exit 75 rather than render twice.
  // Exit 75 is benign — "already running" — not an error.
  function workerArgv() {
    // run-bounded.sh enforces the deadline AND reaps the whole process group.
    // Plain `timeout` is not sufficient: measured on this machine, it signals
    // only the command it launched, leaving grandchildren (hyprctl, fc-list, a
    // wedged helper) running past the deadline. Exit 124 means "timed out".
    var args = ["flock", "-n", "-E", "75", root.lockPath,
                "bash", root.runBounded, String(root.workerTimeoutSec), "5",
                "gjs", "-m", root.workerMain]
    args.push("--theme", String(root.theme))
    args.push("--orientation", String(root.orientation))
    args.push("--sketch", String(root.sketch))
    var families = Array.isArray(root.fonts) ? root.fonts : (root.fonts && typeof root.fonts.length === "number" ? root.fonts : [root.fonts])
    var font = families.length > 0 ? families[Math.floor(Math.random() * families.length)] : "Serif"
    args.push("--font", String(font))
    args.push("--font-size", String(root.fontSize))
    args.push(root.showColor ? "--show-color" : "--no-show-color")
    // Consent gates the wallpaper write; setWallpaper is the ongoing toggle.
    // Either one off means render-only.
    args.push((root.wallpaperConsent && root.setWallpaper) ? "--set-wallpaper" : "--no-set")
    return args
  }

  function refresh() {
    if (workerProc.running) return
    root._stderrBuffer = ""
    workerProc.command = root.workerArgv()
    workerProc.running = true
    workerWatchdog.restart()
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
      root.lastRunEpoch = root.lastRunAt
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

    // StdioCollector has no size limit of its own, so cap what we retain and
    // parse. A noisy or hostile descendant must not be able to grow the shell's
    // heap through us.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseWorkerOutput(root.clampText(text, root.maxWorkerOutputBytes))
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._stderrBuffer = root.clampText(root._stderrBuffer + String(text || ""),
                                                            root.maxWorkerOutputBytes)
    }

    onExited: function(exitCode) {
      workerWatchdog.stop()
      if (exitCode === 75) {
        root.lastError = "already running"
        return
      }
      // timeout(1): 124 = deadline reached, 137 = had to SIGKILL the group.
      // Distinct, recoverable status — not a crash — and state is cleared
      // above so the next refresh runs normally.
      if (exitCode === 124 || exitCode === 137) {
        root.lastError = "timed out after " + root.workerTimeoutSec + "s"
        return
      }
      if (exitCode !== 0) {
        root.lastError = root.clampText(root.elideStderr(root._stderrBuffer) || "worker exited " + exitCode,
                                        root.maxStatusChars)
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Scheduling
  // ---------------------------------------------------------------------------
  //
  // A 60s tick compares now against the last-run epoch. It is not a single
  // long Timer of updateIntervalMin*60000: a QTimer does not compensate for
  // suspend/resume, so a laptop asleep for three hours would fire once on
  // resume and then drift. A steady tick re-derives the delta on every pass.
  //
  // The last-run epoch is discovered, not stored: parsed from the newest PNG
  // filename in the worker's cache (wallpaper-<theme>-<epoch>.png). On a
  // fresh install the cache does not exist — absent or unparseable means
  // "due", firing once after the startup grace.
  readonly property double serviceStart: Date.now()
  readonly property int startupGraceMs: 45000
  property double lastRunEpoch: 0

  readonly property string cacheDir: Quickshell.env("HOME") + "/.cache/omashuzhi"

  // The worker runs the scheduler after a successful run and parseWorkerOutput
  // sets lastRunEpoch itself; this probe only matters across a shell restart,
  // where the freshest PNG still carries its epoch.
  function discoverLastRunEpoch() {
    probeProc.command = [
      "bash", root.runBounded, "10", "2",
      "bash", "-c",
      "ls -1t \"" + root.cacheDir + "\"/wallpaper-*.png 2>/dev/null | head -1"
    ]
    probeProc.running = true
    probeWatchdog.restart()
  }

  function applyDiscovery(raw) {
    var text = String(raw || "").trim()
    var m = text.match(/wallpaper-(?:dark|light)-(\d+)\.png$/)
    if (m && m[1]) {
      var epoch = Number(m[1])
      if (epoch > 0) root.lastRunEpoch = epoch
    }
  }

  Process {
    id: probeProc
    command: []
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyDiscovery(root.clampText(text, 4096))
    }
    onExited: probeWatchdog.stop()
  }

  function checkScheduled() {
    if (!root.entry) return // not known yet, not "all defaults"
    // No scheduled work at all until the user has consented. Enabling the
    // plugin must not start rewriting the background on a timer.
    if (!root.wallpaperConsent) return
    var interval = root.updateIntervalMin
    if (interval <= 0) return // off
    if (Date.now() - root.serviceStart < root.startupGraceMs) return
    var due = root.lastRunEpoch <= 0 || Date.now() - root.lastRunEpoch >= interval * 60000
    if (due) root.refresh()
  }

  Timer {
    id: probeTimer
    interval: 2000
    repeat: false
    running: true
    onTriggered: root.discoverLastRunEpoch()
  }

  Timer {
    id: scheduleTimer
    interval: 60000
    repeat: true
    running: true
    onTriggered: root.checkScheduled()
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
      wallpaperConsent: root.wallpaperConsent,
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
