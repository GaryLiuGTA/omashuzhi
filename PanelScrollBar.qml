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

  // Scroll travel is contentHeight MINUS the viewport height — contentY never
  // reaches contentHeight. The handle must be able to reach the track's
  // bottom, so the fraction is measured against the scroll range, not the
  // content height.
  readonly property real scrollRange: Math.max(0, target.contentHeight - target.height)
  readonly property real scrollFraction: scrollRange > 0 ? target.contentY / scrollRange : 0
  readonly property real handleY: handle.y
  readonly property real handleHeight: handle.height

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
    y: root.scrollFraction * (root.height - height)
    // A comfortable minimum so a huge list (634 families) still leaves a
    // grabbable handle.
    height: Math.max(Style.space(12), target.height / Math.max(1, target.contentHeight) * root.height)
  }

  MouseArea {
    anchors.fill: parent
    onPressed: function(mouse) { root.scrollTo(mouse.y) }
    onPositionChanged: function(mouse) { if (pressed) root.scrollTo(mouse.y) }
  }

  function scrollTo(my) {
    var range = root.scrollRange
    if (range <= 0) return
    var frac = (my - handle.height / 2) / Math.max(1, root.height - handle.height)
    target.contentY = Math.max(0, Math.min(range, frac * range))
  }
}
