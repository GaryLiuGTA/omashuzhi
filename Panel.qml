import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Omashuzhi(数枝) — the bar widget and its popup.
//
// The root is a qs.Ui Panel (bar-widget entry point) whose only bar content
// is the icon; the popup is a KeyboardPanel mounted on the icon. The service
// owns the worker process and IPC; this Panel is pure UI, reading the service
// through bar.shell.serviceFor() and persisting every setting to shell.json
// through bar.shell.updateEntryInline().
Panel {
  id: root
  moduleName: "garyliu.omashuzhi-wallpaper"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("garyliu.omashuzhi-wallpaper") : null
  readonly property string listFontsPath: String(Qt.resolvedUrl("worker/list-fonts.sh")).replace(/^file:\/\//, "")

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(root.fg, 1.4)
  readonly property string fFamily: bar ? bar.fontFamily : Style.font.family

  // Effective UI language: an explicit choice, else Qt.locale()-based auto.
  // It switches only this popup's strings — the poem on the wallpaper is
  // untouched, and the worker never receives the language setting.
  readonly property string uiLanguage: Model.normalizedLanguage(root.setting("language", null), Model.defaultLanguage(Qt.locale().name))
  readonly property var langCfg: Model.langConfig(root.uiLanguage)

  // The selected-fonts list is capped at six rows so a long selection cannot
  // inflate the whole panel to full screen height.
  readonly property real fontRowHeight: Style.spacing.controlHeight
  readonly property real fontListSpacing: Style.space(4)
  readonly property real fontListMaxHeight: root.fontRowHeight * 6 + root.fontListSpacing * 5

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      ShuzhiIcon {
        iconSize: Style.space(14)
        color: root.barForeground
      }
    }
    tooltipText: "Omashuzhi(数枝)"
    onPressed: function(b) { if (b === Qt.LeftButton) root.toggle() }
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- persistence ------------------------------------------------------
  // Every persist replaces the layout entry, so always write a full copy of
  // the entry. Debounced 400ms: NumberField.modified fires on every click and
  // each write is an atomic shell.json rewrite the watching FileView reloads.
  property var _pendingPersist: ({})
  property bool _pendingDirty: false
  property bool _fontScanArmed: false

  function persistSettings(changes) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in changes) entry[key] = changes[key]
    root.settings = entry
    root._pendingPersist = entry
    root._pendingDirty = true
    persistTimer.restart()
  }

  Timer {
    id: persistTimer
    interval: 400
    repeat: false
    onTriggered: {
      if (!root._pendingDirty) return
      root._pendingDirty = false
      if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
        root.bar.shell.updateEntryInline(root.moduleName, root._pendingPersist)
    }
  }

  // ---- status line ------------------------------------------------------
  readonly property bool statusBusy: service ? service.busy === true : false
  readonly property bool statusFailed: service ? !!service.lastError && service.lastError !== "already running" : false
  readonly property string statusText: {
    if (statusBusy) return root.langCfg.statusGenerating
    if (statusFailed) return String(service.lastError || root.langCfg.statusGenerating)
    if (service && service.lastResult) return Model.metaLine(service.lastResult, service.lastRunAt, root.uiLanguage)
    return root.langCfg.statusNever
  }
  readonly property color statusColor: {
    if (statusBusy || (service && service.lastResult)) return Color.accent
    if (statusFailed) return Color.urgent
    return root.dim
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    centerOnBar: false
    // A taller bottom margin than Style.gapsOut so the panel never runs flush
    // to the screen edge and the last control is not jammed against it.
    margin: Style.space(12)
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(col.implicitHeight + Style.space(8))

    onOpenChanged: {
      if (!panel.open) return
      // FontPicker.toggleValue assigns values internally, so a declarative
      // binding would die after the first click; re-sync from settings here.
      fontPicker.values = Model.asArray(root.setting("fonts", ["Serif"]))
      // fc-list must not run at shell startup, once per monitor — arm it on
      // the first popup open instead.
      if (!root._fontScanArmed) {
        root._fontScanArmed = true
        fontPicker.optionsCommand = ["bash", root.listFontsPath]
      }
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: sketchDropdown.popupOpen
        || fontPicker.popupOpen
        || addFontField.activeFocus
        || fontSizeField.field.activeFocus
        || intervalField.field.activeFocus
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) {
        if (themeGroup.activeFocus && dx !== 0) {
          var ni = themeGroup._focusedIndex < 0 ? themeGroup.selectedOptionIndex() : themeGroup._focusedIndex
          themeGroup._focusedIndex = (ni + dx + themeGroup.options.length) % themeGroup.options.length
        } else if (orientationGroup.activeFocus && dx !== 0) {
          var no = orientationGroup._focusedIndex < 0 ? orientationGroup.selectedOptionIndex() : orientationGroup._focusedIndex
          orientationGroup._focusedIndex = (no + dx + orientationGroup.options.length) % orientationGroup.options.length
        }
      }
      onActivateRequested: {
        if (themeGroup.activeFocus) themeGroup.activateFocused()
        else if (orientationGroup.activeFocus) orientationGroup.activateFocused()
        else if (sketchDropdown.activeFocus) sketchDropdown.toggle()
        else if (showColorToggle.activeFocus) root.persistSettings({ showColor: !root.setting("showColor", false) })
        else if (setWallpaperToggle.activeFocus) root.persistSettings({ setWallpaper: root.setting("setWallpaper", true) === false })
        else if (languageGroup.activeFocus) languageGroup.activateFocused()
      }
      onTabRequested: function(dir) { root.moveTabFocus(dir) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        Column {
          id: col
          width: scroll.width - outerBar.width
          spacing: Style.space(14)

          // ---- Hero -------------------------------------------------------

          Row {
            width: parent.width
            spacing: Style.space(14)

            ShuzhiIcon {
              id: heroIcon
              iconSize: Style.font.display
              color: root.fg
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              width: parent.width - heroIcon.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: root.langCfg.title
                color: root.fg
                font.family: root.fFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Row {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  visible: root.statusBusy
                  text: "󰑐"
                  color: root.statusColor
                  font.family: root.fFamily
                  font.pixelSize: Style.font.caption
                  RotationAnimator on rotation {
                    running: root.statusBusy
                    from: 0
                    to: 360
                    duration: 800
                    loops: Animation.Infinite
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.statusText
                  color: root.statusColor
                  font.family: root.fFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width - (parent.children[0].visible ? parent.children[0].width + parent.spacing : 0)
                  wrapMode: Text.WordWrap
                }
              }
            }
          }

          // ---- Refresh now ------------------------------------------------
          Button {
            id: refreshButton
            width: parent.width
            text: root.langCfg.refreshNow
            iconText: "󰑐"
            iconSpinning: root.statusBusy
            bordered: true
            foreground: root.fg
            accent: Color.accent
            fontFamily: root.fFamily
            onClicked: { if (root.service) root.service.refresh() }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.fg
            strength: 0.2
          }

          PanelSectionHeader {
            text: root.langCfg.sectionWallpaper
            foreground: root.fg
            fontFamily: root.fFamily
          }

          // ---- Wallpaper theme --------------------------------------------
          Text {
            textFormat: Text.PlainText
            text: root.langCfg.themeLabel
            color: root.dim
            font.family: root.fFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          ButtonGroup {
            id: themeGroup
            width: parent.width
            options: [
              { value: "dark", label: root.langCfg.themeDark },
              { value: "light", label: root.langCfg.themeLight },
              { value: "random", label: root.langCfg.themeRandom }
            ]
            value: String(root.setting("theme", "dark"))
            foreground: root.fg
            accent: Color.accent
            fontFamily: root.fFamily
            onChanged: function(v) {
              if (v === String(root.setting("theme", "dark"))) return
              // The sketch migrates cloud <-> tree with the theme so the
              // dropdown never offers one the new theme cannot draw.
              root.persistSettings({
                theme: v,
                sketch: Model.migrateSketch(String(root.setting("sketch", "random")), v)
              })
            }
          }

          // ---- Text layout ------------------------------------------------
          Text {
            textFormat: Text.PlainText
            text: root.langCfg.layoutLabel
            color: root.dim
            font.family: root.fFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          ButtonGroup {
            id: orientationGroup
            width: parent.width
            options: [
              { value: "horizontal", label: root.langCfg.layoutHorizontal },
              { value: "vertical", label: root.langCfg.layoutVertical }
            ]
            value: String(root.setting("orientation", "vertical"))
            foreground: root.fg
            accent: Color.accent
            fontFamily: root.fFamily
            onChanged: function(v) { root.persistSettings({ orientation: v }) }
          }

          // ---- Sketch -----------------------------------------------------
          Dropdown {
            id: sketchDropdown
            width: parent.width
            label: root.langCfg.sketchLabel
            options: Model.sketchOptions(String(root.setting("theme", "dark")), root.uiLanguage)
            value: Model.migrateSketch(String(root.setting("sketch", "random")), String(root.setting("theme", "dark")))
            fontFamily: root.fFamily
            onChanged: function(v) { root.persistSettings({ sketch: v }) }
          }

          // ---- Font size + interval --------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(12)

            NumberField {
              id: fontSizeField
              width: (parent.width - parent.spacing) / 2
              fieldWidth: width
              label: root.langCfg.fontSizeLabel
              from: 8
              to: 512
              stepSize: 2
              value: Number(root.setting("fontSize", 96))
              foreground: root.fg
              accent: Color.accent
              fontFamily: root.fFamily
              onModified: function(v) { root.persistSettings({ fontSize: v }) }
            }

            NumberField {
              id: intervalField
              width: (parent.width - parent.spacing) / 2
              fieldWidth: width
              label: root.langCfg.intervalLabel
              from: 0
              to: 1440
              stepSize: 5
              value: Number(root.setting("updateIntervalMin", 30))
              foreground: root.fg
              accent: Color.accent
              fontFamily: root.fFamily
              onModified: function(v) { root.persistSettings({ updateIntervalMin: v }) }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.fg
            strength: 0.2
          }

          PanelSectionHeader {
            text: root.langCfg.sectionFonts
            foreground: root.fg
            fontFamily: root.fFamily
          }

          // ---- Installed families ------------------------------------------
          FontPicker {
            id: fontPicker
            width: parent.width
            label: root.langCfg.installedLabel
            placeholderText: root.langCfg.searchPlaceholder
            options: []
            values: []
            optionsCommand: []
            fontFamily: root.fFamily
            onChanged: function(v) { root.persistSettings({ fonts: Model.asArray(v) }) }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.langCfg.removalCaption
            color: root.dim
            font.family: root.fFamily
            font.pixelSize: Style.font.caption
          }

          // ---- Selected fonts ----------------------------------------------
          // Capped at six rows with its own scroll area, so a long selection
          // never inflates the whole panel. The wheel handler scrolls this
          // list only while it can move in that direction, and otherwise
          // scrolls the outer panel instead (a wheel that dead-ends here while
          // the outer still has content below is a bug).
          Item {
            width: parent.width
            height: fontListScroll.height

            Flickable {
              id: fontListScroll
              // Reserve the scrollbar's width unconditionally (a conditional
              // margin would feed back: width -> contentHeight -> bar.visible
              // -> width). interactive follows overflow so Flickable's own
              // wheel/drag handling works — a non-interactive Flickable
              // ignores wheel events entirely.
              width: parent.width - fontListBar.width
              height: Math.min(fontListColumn.implicitHeight, root.fontListMaxHeight)
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              contentWidth: width
              contentHeight: fontListColumn.implicitHeight
              interactive: fontListColumn.implicitHeight > height
              flickDeceleration: 1500
              maximumFlickVelocity: 2000

            Column {
              id: fontListColumn
              width: parent.width
              spacing: root.fontListSpacing

              Repeater {
                model: Model.asArray(root.setting("fonts", ["Serif"]))

                delegate: Row {
                  required property string modelData
                  readonly property bool scanned: fontPicker.resolvedOptions.length > 0
                  readonly property bool installed: root.fontInstalled(modelData)
                  width: parent.width
                  height: root.fontRowHeight
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData
                    color: root.fg
                    font.family: root.fFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    width: parent.width - missingTag.implicitWidth - removeX.implicitWidth - parent.spacing * 2
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    id: missingTag
                    textFormat: Text.PlainText
                    visible: parent.scanned && !parent.installed
                    text: root.langCfg.notInstalled
                    color: Color.urgent
                    font.family: root.fFamily
                    font.pixelSize: Style.font.caption
                    font.italic: true
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    id: removeX
                    textFormat: Text.PlainText
                    text: "✕"
                    color: Qt.darker(root.fg, 1.5)
                    font.family: root.fFamily
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                    MouseArea {
                      anchors.fill: parent
                      anchors.margins: -4
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeFont(modelData)
                    }
                  }
                }
              }
            }
          }

            PanelScrollBar {
              id: fontListBar
              target: fontListScroll
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.bottom: parent.bottom
            }
          }

          // ---- Add a font -------------------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: addFontField
              width: parent.width - addButton.implicitWidth - parent.spacing
              placeholderText: root.langCfg.addPlaceholder
              foreground: root.fg
              accent: Color.accent
              font.family: root.fFamily
              onAccepted: root.addFont()
            }

            Button {
              id: addButton
              text: root.langCfg.addButton
              bordered: true
              foreground: root.fg
              accent: Color.accent
              fontFamily: root.fFamily
              onClicked: root.addFont()
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.fg
            strength: 0.2
          }

          // ---- Toggles -----------------------------------------------------
          Toggle {
            id: showColorToggle
            width: parent.width
            label: root.langCfg.showColorLabel
            description: root.langCfg.showColorDesc
            checked: root.setting("showColor", false) === true
            foreground: root.fg
            accent: Color.accent
            fontFamily: root.fFamily
            onClicked: root.persistSettings({ showColor: !root.setting("showColor", false) })
          }

          Toggle {
            id: setWallpaperToggle
            width: parent.width
            label: root.langCfg.setWallpaperLabel
            description: root.langCfg.setWallpaperDesc
            checked: root.setting("setWallpaper", true) !== false
            foreground: root.fg
            accent: Color.accent
            fontFamily: root.fFamily
            onClicked: root.persistSettings({ setWallpaper: root.setting("setWallpaper", true) === false })
          }

          PanelSeparator {
            width: parent.width
            foreground: root.fg
            strength: 0.2
          }

          // ---- Language ----------------------------------------------------
          // A segmented control, not a Dropdown: the shared Dropdown opens its
          // popup downward with no clamp, and this is the last row of a panel
          // that can fill the screen — the popup would land off the bottom.
          Text {
            textFormat: Text.PlainText
            text: root.langCfg.languageLabel
            color: root.dim
            font.family: root.fFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          ButtonGroup {
            id: languageGroup
            width: parent.width
            options: [
              { value: "zh-Hans", label: "简体中文" },
              { value: "zh-Hant", label: "繁體中文" },
              { value: "en", label: "English" }
            ]
            value: root.uiLanguage
            foreground: root.fg
            accent: Color.accent
            fontFamily: root.fFamily
            onChanged: function(v) {
              if (v === String(root.setting("language", ""))) return
              root.persistSettings({ language: v })
            }
          }
        }
      }

      PanelScrollBar {
        id: outerBar
        target: scroll
        anchors.right: scroll.right
        anchors.top: scroll.top
        anchors.bottom: scroll.bottom
      }
    }
  }



  function fontInstalled(font) {
    return Model.isFontInstalled(font, fontPicker.resolvedOptions)
  }

  function addFont() {
    var name = addFontField.text.trim()
    if (!name) return
    var fonts = Model.asArray(root.setting("fonts", ["Serif"]))
    if (fonts.indexOf(name) === -1) fonts.push(name)
    addFontField.text = ""
    root.persistSettings({ fonts: fonts })
    fontPicker.values = fonts.slice()
    fontPicker.refresh()
  }

  function removeFont(name) {
    var fonts = Model.asArray(root.setting("fonts", ["Serif"]))
    var idx = fonts.indexOf(name)
    if (idx === -1) return
    fonts.splice(idx, 1)
    root.persistSettings({ fonts: fonts })
    fontPicker.values = fonts.slice()
  }

  function moveTabFocus(dir) {
    var targets = [
      themeGroup, orientationGroup, sketchDropdown,
      fontSizeField.field, intervalField.field,
      addFontField, showColorToggle, setWallpaperToggle,
      languageGroup
    ]
    var focused = -1
    for (var i = 0; i < targets.length; i++) {
      if (targets[i].activeFocus) { focused = i; break }
    }
    var next = focused < 0 ? (dir > 0 ? 0 : targets.length - 1) : focused + dir
    if (next < 0) next = targets.length - 1
    if (next >= targets.length) next = 0
    targets[next].forceActiveFocus()
  }
}
