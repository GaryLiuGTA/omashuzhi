// Pure helpers for the Omashuzhi popup. Three UI languages (zh-Hans / zh-Hant /
// en); the language setting switches only the popup's own text — the poem on
// the wallpaper is untouched and the worker never receives it. No QML types
// here, so this stays node-testable, and worker JS (which pollutes
// Object.prototype) is never imported into QML.

// Sketch options per wallpaper theme. `tree` and `cloud` are the same worker
// code path under two names (main.js maps both to `dark ? Cloud : Tree`), so
// each theme offers exactly the four it can draw: dark -> Cloud, light ->
// Tree, random -> a single theme-dependent "Tree / Cloud" entry. Labels are
// localized through LANG_DATA.
var SKETCH_VALUES = {
  dark: ["wave", "blob", "oval", "cloud", "random"],
  light: ["wave", "blob", "oval", "tree", "random"],
  random: ["wave", "blob", "oval", "tree", "random"]
}

function sketchOptions(theme, lang) {
  var cfg = langConfig(lang)
  var values = SKETCH_VALUES[theme] || SKETCH_VALUES.dark
  var labelFor = {
    wave: cfg.sketchWave,
    blob: cfg.sketchBlob,
    oval: cfg.sketchOval,
    tree: cfg.sketchTree,
    cloud: cfg.sketchCloud,
    random: cfg.sketchRandom
  }
  var out = []
  for (var i = 0; i < values.length; i++) {
    var v = values[i]
    out.push({ value: v, label: v === "tree" && theme === "random" ? cfg.sketchTreeCloud : labelFor[v] })
  }
  return out
}

function sketchNameLabel(value, lang) {
  var cfg = langConfig(lang)
  var labelFor = {
    wave: cfg.sketchWave,
    blob: cfg.sketchBlob,
    oval: cfg.sketchOval,
    tree: cfg.sketchTree,
    cloud: cfg.sketchCloud,
    random: cfg.sketchRandom
  }
  return labelFor[String(value)] || String(value)
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

function metaLine(result, lastRunAt, lang) {
  if (!result) return ""
  var cfg = langConfig(lang)
  var theme = result.theme === "light" ? cfg.themeLight : cfg.themeDark
  return cfg.statusLastPrefix + " " + clockHm(lastRunAt) + " · "
    + theme + " · "
    + sketchNameLabel(result.sketch, lang) + " · "
    + String(result.w || 0) + "x" + String(result.h || 0)
}

// ---- Language config. The vocabulary differs per script, the plugin's
//      behaviour is identical. Pattern follows garyliu.lunar-calendar.
var LANG_DATA = {
  "zh-Hans": {
    title: "数枝",
    statusGenerating: "正在生成…",
    statusNever: "尚未生成",
    statusLastPrefix: "上次刷新",
    refreshNow: "立即刷新",
    sectionWallpaper: "壁纸",
    sectionFonts: "字体 · 每次刷新随机选用一个",
    themeLabel: "壁纸配色",
    themeDark: "深色",
    themeLight: "浅色",
    themeRandom: "随机",
    layoutLabel: "文字排版",
    layoutHorizontal: "横排",
    layoutVertical: "竖排",
    sketchLabel: "图案",
    sketchWave: "波浪",
    sketchBlob: "墨迹",
    sketchOval: "椭圆",
    sketchTree: "树影",
    sketchCloud: "云影",
    sketchRandom: "随机",
    sketchTreeCloud: "树影 / 云影",
    fontSizeLabel: "字号（磅）",
    intervalLabel: "刷新间隔（分钟）",
    installedLabel: "已安装字体",
    searchPlaceholder: "搜索字体…",
    removalCaption: "仅对手动输入的名称生效——已安装字体每次扫描都会重新提供。",
    notInstalled: "未安装",
    addPlaceholder: "按名称添加字体…",
    addButton: "添加",
    showColorLabel: "显示颜色名称",
    showColorDesc: "仅波浪图案",
    setWallpaperLabel: "设为壁纸",
    setWallpaperDesc: "关闭：仅渲染 PNG",
    languageLabel: "语言"
  },
  "zh-Hant": {
    title: "數枝",
    statusGenerating: "正在生成中…",
    statusNever: "尚未生成",
    statusLastPrefix: "上次重新整理",
    refreshNow: "立即重新整理",
    sectionWallpaper: "壁紙",
    sectionFonts: "字體 · 每次重新整理隨機選用一個",
    themeLabel: "壁紙配色",
    themeDark: "深色",
    themeLight: "淺色",
    themeRandom: "隨機",
    layoutLabel: "文字排版",
    layoutHorizontal: "橫排",
    layoutVertical: "豎排",
    sketchLabel: "圖案",
    sketchWave: "波浪",
    sketchBlob: "墨跡",
    sketchOval: "橢圓",
    sketchTree: "樹影",
    sketchCloud: "雲影",
    sketchRandom: "隨機",
    sketchTreeCloud: "樹影 / 雲影",
    fontSizeLabel: "字號（磅）",
    intervalLabel: "重新整理間隔（分鐘）",
    installedLabel: "已安裝字體",
    searchPlaceholder: "搜尋字體…",
    removalCaption: "僅對手動輸入的名稱生效——已安裝字體每次掃描都會重新提供。",
    notInstalled: "未安裝",
    addPlaceholder: "按名稱新增字體…",
    addButton: "新增",
    showColorLabel: "顯示顏色名稱",
    showColorDesc: "僅波浪圖案",
    setWallpaperLabel: "設為壁紙",
    setWallpaperDesc: "關閉：僅渲染 PNG",
    languageLabel: "語言"
  },
  "en": {
    title: "Omashuzhi",
    statusGenerating: "Generating…",
    statusNever: "Never generated",
    statusLastPrefix: "Last refresh",
    refreshNow: "Refresh now",
    sectionWallpaper: "Wallpaper",
    sectionFonts: "Fonts · one is picked at random each refresh",
    themeLabel: "Wallpaper theme",
    themeDark: "Dark",
    themeLight: "Light",
    themeRandom: "Random",
    layoutLabel: "Text layout",
    layoutHorizontal: "Horizontal",
    layoutVertical: "Vertical",
    sketchLabel: "Sketch",
    sketchWave: "Wave",
    sketchBlob: "Blob",
    sketchOval: "Oval",
    sketchTree: "Tree",
    sketchCloud: "Cloud",
    sketchRandom: "Random",
    sketchTreeCloud: "Tree / Cloud",
    fontSizeLabel: "Font size",
    intervalLabel: "Refresh every (min)",
    installedLabel: "Installed families",
    searchPlaceholder: "Search fonts…",
    removalCaption: "Removal matters for hand-typed names — installed families are always re-offered on scan.",
    notInstalled: "not installed",
    addPlaceholder: "Add a font by name…",
    addButton: "Add",
    showColorLabel: "Show colour name",
    showColorDesc: "Wave sketch only",
    setWallpaperLabel: "Set as wallpaper",
    setWallpaperDesc: "Off: render the PNG only",
    languageLabel: "Language"
  }
}

function normalizedLanguage(value, fallback) {
  var v = String(value === undefined || value === null ? "" : value)
  if (v === "zh-Hans" || v === "zh-Hant" || v === "en") return v
  return (fallback === "zh-Hans" || fallback === "zh-Hant" || fallback === "en") ? fallback : "en"
}

// Default UI language from a Qt.locale().name()-style string (e.g. "zh_CN",
// "zh_TW", "en_US"). Simplified for mainland/Singapore, Traditional for
// Taiwan/Hong Kong/Macau, English otherwise.
function defaultLanguage(localeName) {
  var name = String(localeName || "")
  if (name.indexOf("zh") !== 0) return "en"
  if (name.indexOf("TW") !== -1 || name.indexOf("HK") !== -1 || name.indexOf("MO") !== -1 || name.indexOf("Hant") !== -1) return "zh-Hant"
  return "zh-Hans"
}

function langConfig(lang) {
  return LANG_DATA[lang] || LANG_DATA.en
}
