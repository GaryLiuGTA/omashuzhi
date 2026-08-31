// Pure helpers for the Omashuzhi popup. English strings only — the zh-Hans /
// zh-Hant dictionaries land in step 12. No QML types here, so this stays
// node-testable, and worker JS (which pollutes Object.prototype) is never
// imported into QML.

// Sketch options per wallpaper theme. `tree` and `cloud` are the same worker
// code path under two names (main.js maps both to `dark ? Cloud : Tree`), so
// each theme offers exactly the four it can draw: dark -> Cloud, light ->
// Tree, random -> a single theme-dependent "Tree / Cloud" entry.
var SKETCH_OPTIONS = {
  dark: [
    { value: "wave", label: "Wave" },
    { value: "blob", label: "Blob" },
    { value: "oval", label: "Oval" },
    { value: "cloud", label: "Cloud" },
    { value: "random", label: "Random" }
  ],
  light: [
    { value: "wave", label: "Wave" },
    { value: "blob", label: "Blob" },
    { value: "oval", label: "Oval" },
    { value: "tree", label: "Tree" },
    { value: "random", label: "Random" }
  ],
  random: [
    { value: "wave", label: "Wave" },
    { value: "blob", label: "Blob" },
    { value: "oval", label: "Oval" },
    { value: "tree", label: "Tree / Cloud" },
    { value: "random", label: "Random" }
  ]
}

function sketchOptions(theme) {
  return SKETCH_OPTIONS[theme] || SKETCH_OPTIONS.dark
}

// Normalize a stored sketch for the given wallpaper theme so the dropdown
// never offers an option the theme cannot draw. cloud <-> tree render
// identically (the worker maps both to `dark ? Cloud : Tree`), so migrating
// the stored name never changes the wallpaper.
function migrateSketch(sketch, theme) {
  if (sketch === "random") return "random"
  if (sketch !== "tree" && sketch !== "cloud") return sketch
  if (theme === "dark") return "cloud"
  if (theme === "light") return "tree"
  return "tree" // random theme: the "Tree / Cloud" option's value
}

// `fonts` can arrive as a real array, a single family name (the omarchy-bar
// --json CLI unboxes one-element arrays into a string), or nothing.
function asArray(value) {
  if (Array.isArray(value)) return value.slice()
  if (value === undefined || value === null || value === "") return []
  return [String(value)]
}

function isFontInstalled(font, resolvedOptions) {
  var arr = Array.isArray(resolvedOptions) ? resolvedOptions : []
  for (var i = 0; i < arr.length; i++) {
    if (String(arr[i].value) === String(font)) return true
  }
  return false
}

function clockHm(epochMs) {
  var d = new Date(Number(epochMs) || 0)
  var h = d.getHours()
  var m = d.getMinutes()
  return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
}

function metaLine(result, lastRunAt) {
  if (!result) return ""
  return "Last refresh " + clockHm(lastRunAt) + " · "
    + String(result.theme || "") + " · "
    + String(result.sketch || "") + " · "
    + String(result.w || 0) + "x" + String(result.h || 0)
}
