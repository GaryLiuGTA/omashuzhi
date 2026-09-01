import QtQuick
import qs.Commons

// Theme-tinted vertical scrollbar, shared by the panel body and the font
// picker. Plain Rectangles (a stock QtQuick.Controls ScrollBar does not
// render inside this shell's layer surfaces), AsNeeded visibility, click and
// drag to scroll. Overlays the right edge of `target` (any Flickable);
// callers reserve its width so it never covers content.
Item {
  id: root

  required property Flickable target
  readonly property real trackWidth: Style.space(4)
  width: trackWidth + Style.space(2)
  visible: target && target.contentHeight > target.height
  z: 3

  Rectangle {
    anchors.left: parent.left
    anchors.leftMargin: Style.space(1)
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: parent.trackWidth
    radius: Style.space(2)
    color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.10)
  }

  Rectangle {
    id: handle
    anchors.left: parent.left
    anchors.leftMargin: Style.space(1)
    width: parent.trackWidth
    radius: Style.space(2)
    color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.5)
    y: parent.target.contentY / Math.max(1, parent.target.contentHeight) * (parent.height - height)
    height: Math.max(Style.space(8), parent.target.height / Math.max(1, parent.target.contentHeight) * parent.height)
  }

  MouseArea {
    anchors.fill: parent
    onPressed: function(mouse) { parent.scrollTo(mouse.y) }
    onPositionChanged: function(mouse) { if (pressed) parent.scrollTo(mouse.y) }
  }

  function scrollTo(my) {
    var t = target
    var range = t.contentHeight - t.height
    if (range <= 0) return
    var frac = (my - handle.height / 2) / Math.max(1, parent.height - handle.height)
    t.contentY = Math.max(0, Math.min(range, frac * range))
  }
}
