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

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity when the user clicks straight from one bar panel to another.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
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
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
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
    // The mark never stops turning, panel open or closed -- it is the one
    // thing in the bar that says this widget is watching what you launch.
    //
    // It used to speed up while the orbit was on screen. That is gone: `speed`
    // feeds the glyph's animator durations, and changing a running animator's
    // duration restarts it, so animating the speed restarted the rotation on
    // every frame of the transition and the mark visibly stalled. A flourish
    // that costs the one animation that is supposed to be perpetual is not
    // worth it -- and the bar sits under the panel's scrim while open, so
    // almost nobody ever saw it.
    iconComponent: Component {
      Item {
        OrbitGlyph {
          anchors.centerIn: parent
          width: parent.width
          height: parent.height
          coreColor: Color.accent
          satelliteColor: button.foreground
        }
      }
    }

    onPressed: function(b) { root.togglePanel() }
  }
}
