import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Gravity's bar presence: the turning mark, and the host for the orbital
// panel behind it.
//
// Structure follows the first-party popup widgets -- the bar mounts this
// item, this item owns a Loader holding Panel.qml, and the panel's open/close
// contract is forwarded from here so the bar's single-popout coordinator sees
// one identity per slot.
//
// The counting half of the plugin is not here. It lives in Service.qml, which
// the shell mounts once for the whole session rather than once per monitor,
// so a two-screen setup cannot double-count a launch.
BarWidget {
  id: root
  moduleName: "io.github.mahziyarng98.gravity"

  // ---- Panel contract. Bar.findPanelWidget requires open/close/opened on
  //      the bar-widget root, so these forward rather than living on Panel.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  // Keep the widget cheap on a fresh shell start. Panel.qml owns the icon
  // index, file watcher and overlay window, so do not instantiate it until a
  // user action actually opens Gravity.
  property bool panelLoaded: false
  property bool panelOpenRequested: false

  function open() {
    if (!panelLoader.item) {
      root.panelOpenRequested = true
      root.panelLoaded = true
      return
    }
    root.panelOpenRequested = false
    panelLoader.item.open()
  }

  function close() {
    root.panelOpenRequested = false
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (root.opened || root.panelOpenRequested) root.close()
    else root.open()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity when the user clicks straight from one bar panel to another.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    root.panelOpenRequested = false
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // ---- IPC routing. An IPC target resolves to exactly one handler, but a
  //      bar surface exists per monitor, so route through the bar's panel
  //      lookup (which picks the instance on the focused screen) and only
  //      fall back to this instance when there is no bar to ask.
  function routeOpen() {
    if (root.bar && typeof root.bar.summonBarWidget === "function" && root.bar.summonBarWidget(root.moduleName)) return
    root.open()
  }

  function routeClose() {
    if (root.bar && typeof root.bar.hideBarWidget === "function" && root.bar.hideBarWidget(root.moduleName)) return
    root.close()
  }

  function routeToggle() {
    if (root.bar && typeof root.bar.isBarWidgetOpen === "function") {
      if (root.bar.isBarWidgetOpen(root.moduleName)) routeClose()
      else routeOpen()
      return
    }
    root.togglePanel()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: root.panelLoaded
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(function() {
        root.injectPanel()
        var shouldOpen = root.panelOpenRequested
        root.panelOpenRequested = false
        if (shouldOpen && panelLoader.item) panelLoader.item.open()
      })
    }
  }

  IpcHandler {
    target: "gravity"

    function open(): void { root.routeOpen() }
    function close(): void { root.routeClose() }
    function show(): void { root.routeOpen() }
    function hide(): void { root.routeClose() }
    function toggle(): void { root.routeToggle() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "Gravity"
    // Keep the mark static. A tiny always-running orbital animation in every
    // monitor's bar adds background render work without helping the launcher.
    iconComponent: Component {
      Item {
        OrbitGlyph {
          anchors.centerIn: parent
          width: parent.width
          height: parent.height
          coreColor: Color.accent
          satelliteColor: button.foreground
          spinning: false
        }
      }
    }

    onPressed: function(b) { root.togglePanel() }
  }
}
