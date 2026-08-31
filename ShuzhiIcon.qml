import QtQuick
import QtQuick.Shapes
import qs.Commons

// Omashuzhi's mark: a tapered calligraphic brush "C" (thick at the top-right
// entry, hairline at the tail) with a scroll banner and rod. Authored in a
// 24x24 coordinate space, scaled to iconSize; theme-tinted through `color`.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  // 24x24 artboard, scaled to the requested size.
  Item {
    id: canvas
    width: 24
    height: 24
    anchors.centerIn: parent
    scale: root.iconSize / 24

    Shape {
      anchors.fill: parent
      antialiasing: true
      layer.enabled: true
      layer.samples: 4

      // Tapered brush C — filled, not stroked.
      ShapePath {
        fillColor: root.color
        strokeColor: "transparent"
        strokeWidth: 0
        PathSvg {
          path: "M 16.93,4.67 L 16.43,4.31 L 15.90,3.98 L 15.36,3.68 L 14.80,3.42 L 14.22,3.20 L 13.63,3.02 L 13.02,2.88 L 12.41,2.78 L 11.80,2.72 L 11.18,2.70 L 10.56,2.72 L 9.95,2.78 L 9.34,2.89 L 8.73,3.03 L 8.14,3.22 L 7.57,3.44 L 7.01,3.70 L 6.46,4.00 L 5.94,4.33 L 5.44,4.70 L 4.97,5.10 L 4.52,5.53 L 4.11,5.98 L 3.72,6.47 L 3.37,6.98 L 3.06,7.51 L 2.78,8.06 L 2.53,8.63 L 2.33,9.21 L 2.16,9.81 L 2.04,10.42 L 1.95,11.03 L 1.91,11.65 L 1.90,12.26 L 1.94,12.88 L 2.02,13.49 L 2.14,14.10 L 2.30,14.70 L 2.50,15.29 L 2.74,15.86 L 3.01,16.41 L 3.32,16.95 L 3.67,17.46 L 4.05,17.95 L 4.46,18.41 L 4.90,18.84 L 5.37,19.25 L 5.87,19.62 L 6.38,19.96 L 6.92,20.26 L 7.48,20.52 L 8.06,20.75 L 8.65,20.94 L 9.25,21.09 L 9.86,21.20 L 10.47,21.27 L 11.09,21.30 L 11.71,21.29 L 12.32,21.23 L 12.93,21.14 L 13.54,21.00 L 14.13,20.83 L 14.71,20.61 L 15.28,20.36 L 14.97,19.73 L 14.45,19.96 L 13.91,20.15 L 13.36,20.30 L 12.80,20.41 L 12.23,20.47 L 11.66,20.49 L 11.10,20.47 L 10.54,20.41 L 9.99,20.30 L 9.45,20.16 L 8.92,19.98 L 8.42,19.76 L 7.93,19.50 L 7.47,19.21 L 7.03,18.89 L 6.62,18.55 L 6.24,18.17 L 5.89,17.77 L 5.57,17.36 L 5.28,16.92 L 5.03,16.47 L 4.82,16.01 L 4.64,15.53 L 4.50,15.05 L 4.39,14.57 L 4.32,14.09 L 4.28,13.61 L 4.28,13.13 L 4.31,12.66 L 4.37,12.19 L 4.46,11.74 L 4.59,11.30 L 4.74,10.88 L 4.91,10.48 L 5.12,10.09 L 5.34,9.72 L 5.59,9.38 L 5.85,9.05 L 6.13,8.75 L 6.43,8.47 L 6.74,8.22 L 7.06,7.99 L 7.39,7.78 L 7.73,7.60 L 8.07,7.44 L 8.42,7.31 L 8.77,7.20 L 9.13,7.11 L 9.48,7.05 L 9.83,7.01 L 10.17,6.99 L 10.52,6.99 L 10.86,7.01 L 11.19,7.04 L 11.52,7.10 L 11.84,7.17 L 12.15,7.26 L 12.45,7.37 L 12.75,7.49 L 13.03,7.63 L 13.31,7.77 L 13.58,7.94 L 13.84,8.11 L 14.09,8.30 Z"
        }
      }

      // Scroll banner.
      ShapePath {
        fillColor: root.color
        strokeColor: "transparent"
        strokeWidth: 0
        PathSvg {
          path: "M 8.6,12.4 q 3.4,-1.5 6.9,-0.5 l 0,4.6 q -3.5,-1.0 -6.9,0.5 z"
        }
      }
    }

    // Scroll rod — rounded rect in the same 24x24 space.
    Rectangle {
      x: 15.1
      y: 11.0
      width: 2.0
      height: 6.4
      radius: 1.0
      color: root.color
    }
  }
}
