import QtQuick
import qs.Commons
import qs.Ui

// Omashuzhi's bar-widget entry point. The icon is the whole widget for now;
// the popup and live controls land in later steps. The root is a qs.Ui Panel
// so the bar's summon/close contract (open/close/opened) is satisfied, and
// so the service can be reached through bar.shell.serviceFor() from here.
// ipcTarget stays empty on purpose: the service owns the IPC target, and a
// per-monitor copy of this Panel must not also handle it.
Panel {
  id: root
  moduleName: "garyliu.omashuzhi-wallpaper"

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
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
}
