import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.ylaung-uod.omarchy-rdp"

  property var rdpStatus: ({
    installed: false,
    configured: false,
    armed: false,
    active: false,
    serviceKnown: false,
    listening: false,
    endpoint: "unknown"
  })
  property string statusError: ""

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property string stateLabel: {
    if (!rdpStatus.installed || !rdpStatus.configured) return "Setup required"
    if (!rdpStatus.serviceKnown) return "Status unavailable"
    if (rdpStatus.active && rdpStatus.listening) return "Connected-ready"
    if (!rdpStatus.armed) return "Password required"
    return "Stopped"
  }
  readonly property string tooltipText: "Remote Desktop: " + stateLabel

  function pathFromUrl(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0)
      return decodeURIComponent(value.substring(7))
    return value
  }

  function pluginRoot() {
    var panel = pathFromUrl(Qt.resolvedUrl("Panel.qml"))
    return panel.substring(0, panel.lastIndexOf("/"))
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function openInstaller() {
    detail.open = false
    Quickshell.execDetached(["omarchy-launch-terminal", "bash", pluginRoot() + "/install.sh"])
  }

  function openPasswordPrompt() {
    detail.open = false
    if (!rdpStatus.installed || !rdpStatus.configured) {
      openInstaller()
      return
    }
    Quickshell.execDetached(["omarchy-launch-terminal", "omarchy-rdp-password"])
  }

  function openLogs() {
    detail.open = false
    Quickshell.execDetached([
      "omarchy-launch-terminal", "journalctl", "--user", "-u",
      "hypr-rdp.service", "-b", "--no-hostname"
    ])
  }

  function stopAndDisarm() {
    if (!stopProc.running) stopProc.running = true
  }

  Component.onCompleted: refresh()

  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: statusProc
    command: [root.pathFromUrl(Qt.resolvedUrl("scripts/omarchy-rdp-status"))]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.rdpStatus = JSON.parse(text)
          root.statusError = ""
        } catch (error) {
          root.statusError = "Status unavailable"
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.statusError = "Status check failed"
    }
  }

  Process {
    id: stopProc
    command: [root.pathFromUrl(Qt.resolvedUrl("scripts/omarchy-rdp-stop"))]
    onExited: function() { root.refresh() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍹"
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    tooltipText: root.tooltipText
    active: root.rdpStatus.active
    activeColor: root.rdpStatus.active ? Color.accent : root.dim
    onPressed: {
      detail.open = !detail.open
      if (detail.open) root.refresh()
    }
  }

  PopupCard {
    id: detail
    anchorItem: button
    bar: root.bar
    owner: root
    contentWidth: Style.space(330)
    contentHeight: content.implicitHeight + padding * 2

    ColumnLayout {
      id: content
      width: detail.contentWidth - detail.padding * 2
      spacing: Style.space(10)

      RowLayout {
        Layout.fillWidth: true

        Text {
          text: "Remote Desktop"
          color: root.fg
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
          Layout.fillWidth: true
        }

        Text {
          text: root.stateLabel
          color: root.rdpStatus.active ? Color.accent : root.dim
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      PanelSeparator {
        Layout.fillWidth: true
        foreground: root.fg
      }

      GridLayout {
        Layout.fillWidth: true
        columns: 2
        columnSpacing: Style.space(12)
        rowSpacing: Style.space(6)

        Text { text: "Package"; color: root.dim; font.family: Style.font.family; font.pixelSize: Style.font.caption }
        Text { text: root.rdpStatus.installed ? "Installed" : "Missing"; color: root.fg; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
        Text { text: "Password"; color: root.dim; font.family: Style.font.family; font.pixelSize: Style.font.caption }
        Text { text: root.rdpStatus.armed ? "Held in RAM" : "Not armed"; color: root.fg; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
        Text { text: "Service"; color: root.dim; font.family: Style.font.family; font.pixelSize: Style.font.caption }
        Text { text: root.rdpStatus.active ? "Running" : "Stopped"; color: root.fg; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
        Text { text: "Endpoint"; color: root.dim; font.family: Style.font.family; font.pixelSize: Style.font.caption }
        Text { text: root.rdpStatus.endpoint || "Unknown"; color: root.fg; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight; Layout.fillWidth: true }
      }

      Text {
        visible: root.statusError !== ""
        Layout.fillWidth: true
        text: root.statusError
        color: Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      PanelSeparator {
        Layout.fillWidth: true
        foreground: root.fg
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Button {
          text: root.rdpStatus.installed && root.rdpStatus.configured ? "Set password / start" : "Install runtime"
          foreground: root.fg
          active: true
          fontFamily: Style.font.family
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          Layout.fillWidth: true
          onClicked: root.openPasswordPrompt()
        }

        Button {
          text: "Stop"
          foreground: root.fg
          enabled: root.rdpStatus.active || root.rdpStatus.armed
          fontFamily: Style.font.family
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.stopAndDisarm()
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Button {
          text: "Refresh"
          foreground: root.fg
          fontFamily: Style.font.family
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          Layout.fillWidth: true
          onClicked: root.refresh()
        }

        Button {
          text: "Logs"
          foreground: root.fg
          fontFamily: Style.font.family
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          Layout.fillWidth: true
          onClicked: root.openLogs()
        }
      }

      Text {
        Layout.fillWidth: true
        text: "The separate RDP password is forgotten after every reboot."
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }
}
