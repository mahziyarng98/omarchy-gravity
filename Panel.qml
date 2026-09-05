import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Orbit.js" as Orbit

// The orbit: up to six apps on one ring, centred on the screen, turning.
//
// It is not a favourites bar. Nothing here was configured -- the ring is the
// top of the launch counts that Service.qml has been keeping all session, so
// the app you actually reach for first after a boot ends up in front of you
// without anyone having said so. Pinning exists for the one or two you want
// held in place regardless.
//
// Two decisions worth naming:
//
//   The whole orbit stops on hover, not just the icon under the pointer.
//   Freezing one icon while its neighbours keep sliding turns the ring into
//   six independent things; freezing all six keeps it one object, and the
//   only thing the user wanted -- a target that holds still while they aim --
//   is served either way.
//
//   Opening throws the icons out from the centre one after another rather
//   than fading a finished ring in. The stagger is what makes the ring read
//   as assembled from the middle, which is the same story the bar mark tells.
//
// Unlike the other bar panels this one is a full-screen layer-shell surface
// rather than a card anchored under its bar icon: a ring anchored to a corner
// of the screen would fight the geometry it is built on.
Panel {
  id: root
  moduleName: "io.github.mahziyarng98.gravity"
  ipcTarget: "gravity"
  // BarWidget.qml owns the `gravity` target so it can route a call to the
  // instance on the focused screen.
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget in its slot, not this nested panel, so the
  // popout coordinator has to be given that widget as this panel's identity.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Settings, read inline off this widget's shell.json entry.
  readonly property var pinnedClasses: Orbit.parseList(setting("pinned", ""))
  readonly property var ignoredClasses: Orbit.parseList(setting("ignored", ""))
  readonly property int slotCount: Orbit.clampSlots(setting("slots", Orbit.MAX_SLOTS))
  readonly property int orbitMs: Math.max(4000, Math.round(Number(setting("orbitSeconds", 45)) * 1000) || 45000)

  // ---- The store, mirrored read-only. Service.qml is the only writer; this
  //      panel watches the file so a launch that happens while the orbit is
  //      open re-ranks it live.
  readonly property string home: Quickshell.env("HOME")
  readonly property string usagePath: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/omarchy/gravity/usage.json"
  property var usageApps: ({})
  property int usageRevision: 0
  // Desktop entries land after the shell starts and change as packages come
  // and go; bumping this re-resolves every name and icon in the ring.
  property int entriesRevision: 0

  readonly property var appLibrary: bar && bar.shell ? bar.shell.appLibrary : null

  function describeClass(cls) {
    var entry = null
    try {
      entry = DesktopEntries.heuristicLookup(cls)
    } catch (e) {
      entry = null
    }
    if (!entry) return null
    return {
      desktopId: String(entry.id || ""),
      name: String(entry.name || ""),
      icon: String(entry.icon || ""),
      // NoDisplay is the desktop's own way of saying "not an app anyone
      // launches" -- portals, agents, MIME shims. Windows of these do open,
      // and counting them is harmless, but one has no business taking a slot
      // away from a real app. Pinning still overrides this: a name typed into
      // the config is a decision, not an accident.
      hidden: entry.noDisplay === true
    }
  }

  readonly property var apps: {
    root.usageRevision      // reactive dependencies: the store and the
    root.entriesRevision    // desktop-entry index both feed this
    return Orbit.rankApps(root.usageApps, {
      pinned: root.pinnedClasses,
      ignored: root.ignoredClasses,
      slots: root.slotCount,
      describe: function(cls) { return root.describeClass(cls) }
    })
  }
  readonly property int appCount: apps.length

  function applyUsage(raw) {
    root.usageApps = Orbit.parseStore(raw).apps
    root.usageRevision++
  }

  function iconUrl(app) {
    var name = String((app && app.icon) || "")
    if (root.appLibrary && typeof root.appLibrary.iconSource === "function") return root.appLibrary.iconSource(name)
    if (!name) return Quickshell.iconPath("application-x-executable", true)
    if (name.charAt(0) === "/") return Util.fileUrl(name)
    var themed = Quickshell.iconPath(name, true)
    return themed.length > 0 ? themed : Quickshell.iconPath("application-x-executable", true)
  }

  // ---- Colour roles. Nothing here is a hex: every value is the live Omarchy
  //      theme, so the orbit re-skins with `omarchy theme set`.
  readonly property color ink: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color muted: Util.alpha(ink, 0.62)
  readonly property color faint: Util.alpha(ink, 0.32)
  readonly property color accentInk: Style.selectedStateColor(ink, Color.accent, Color.urgent)

  // ---- Geometry. The ring wants to be as big as the screen comfortably
  //      allows, so the icons are far enough apart to aim at.
  readonly property int chipSize: Style.space(74)
  readonly property int iconSize: Style.space(44)
  readonly property int hubSize: Style.space(140)
  readonly property int orbitRadius: {
    var limit = Math.min(overlay.width, overlay.height)
    var wanted = Style.space(215)
    if (limit <= 0) return wanted
    var fit = Math.round(limit / 2 - root.chipSize * 0.85 - Style.space(26))
    return Math.max(Style.space(118), Math.min(wanted, fit))
  }
  readonly property int stageSize: Math.round(orbitRadius * 2 + chipSize * 1.7)

  // ---- Motion state.
  property real orbitAngle: 0
  // Set once the surface is actually on screen, which is what the burst
  // animation keys off: starting it before the window maps would spend the
  // stagger on a frame nobody sees.
  readonly property bool staged: root.opened && overlay.backingWindowVisible

  // ---- Selection. One cursor, shared by pointer and keyboard, so hovering
  //      and arrowing produce exactly the same state and the same halo.
  property int selectedIndex: -1
  property bool hoverActive: false
  property bool cursorActive: false
  readonly property var selectedApp: selectedIndex >= 0 && selectedIndex < appCount ? apps[selectedIndex] : null
  // Rotation stops whenever something is selected, whichever device selected
  // it: the point of the pause is a target that holds still.
  readonly property bool frozen: selectedApp !== null

  // ---- Panel lifecycle ----------------------------------------------------

  function open() {
    usageFile.reload()
    if (root.appLibrary && typeof root.appLibrary.refreshIcons === "function") root.appLibrary.refreshIcons()
    root.selectedIndex = -1
    root.cursorActive = false
    root.hoverActive = false
    root.controller.show()
    if (root.bar && typeof root.bar.requestPopout === "function") root.bar.requestPopout(root.barIdentity)
    // Summoning by hotkey moves no pointer, so a hover the bar was still
    // holding must not keep the centre indicators revealed behind the orbit.
    setCenterHoverRevealSuppressed(true)
    Qt.callLater(root.grabFocus)
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.selectedIndex = -1
    root.cursorActive = false
    root.hoverActive = false
    if (root.bar && typeof root.bar.releasePopout === "function") root.bar.releasePopout(root.barIdentity)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function grabFocus() {
    if (root.opened) keyCatcher.forceActiveFocus()
  }

  // ---- Selection ----------------------------------------------------------

  function moveSelection(delta) {
    if (root.appCount === 0) return
    root.cursorActive = true
    root.hoverActive = false
    if (root.selectedIndex < 0) {
      root.selectedIndex = delta >= 0 ? 0 : root.appCount - 1
      return
    }
    root.selectedIndex = (root.selectedIndex + delta + root.appCount) % root.appCount
  }

  function selectByPointer(index) {
    root.hoverActive = true
    root.cursorActive = false
    root.selectedIndex = index
  }

  function releasePointer(index) {
    if (root.cursorActive) return
    if (root.selectedIndex !== index) return
    root.hoverActive = false
    root.selectedIndex = -1
  }

  // ---- Launch or focus ----------------------------------------------------

  property var pendingApp: null

  function activate(index) {
    var app = index >= 0 && index < root.appCount ? root.apps[index] : null
    if (!app) return
    root.pendingApp = app
    root.close()
    // Ask the compositor what is already open before deciding. The answer
    // arrives a frame or two later, by which time the orbit is on its way
    // out, which is what makes the click feel immediate.
    clientsProcess.running = true
  }

  function activateSelection() {
    if (root.selectedIndex >= 0) root.activate(root.selectedIndex)
  }

  function applyClients(raw) {
    var app = root.pendingApp
    root.pendingApp = null
    if (!app) return
    var address = Orbit.pickWindowAddress(Orbit.parseClients(raw), app.cls)
    if (address) {
      root.focusWindow(address)
      return
    }
    root.launch(app)
  }

  // hyprctl's dispatcher grammar moved with Hyprland's Lua config: the
  // argument is now a Lua expression, and the positional form every older
  // script uses is a syntax error there. Omarchy's own launch-or-focus tries
  // the new form and falls back to the old one, so this does too rather than
  // picking a side. The address is matched against hyprctl's own hex format
  // before it reaches a shell.
  function focusWindow(address) {
    var addr = String(address || "")
    if (!/^0x[0-9a-fA-F]+$/.test(addr)) return
    Util.execDetached(
      "hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ window = \"address:" + addr + "\" })")
      + " >/dev/null 2>&1 || hyprctl dispatch focuswindow " + Util.shellQuote("address:" + addr) + " >/dev/null 2>&1")
  }

  function launch(app) {
    if (!app || !app.desktopId) return
    if (root.appLibrary && typeof root.appLibrary.launch === "function") {
      root.appLibrary.launch(app.desktopId, app.name)
      return
    }
    // Same invocation the shell's own app library uses: a scope under
    // app-graphical.slice, with gtk-launch resolving the desktop entry.
    Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(app.desktopId + ".desktop"))
  }

  Process {
    id: clientsProcess
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyClients(text)
    }
  }

  FileView {
    id: usageFile
    path: root.usagePath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyUsage(usageFile.text())
    // `text()` is stale inside the change signal, so route both paths through
    // reload -> onLoaded and always parse fresh content.
    onFileChanged: usageFile.reload()
    onLoadFailed: root.applyUsage("")
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.entriesRevision++ }
  }

  // The one long-running animation: the ring's own rotation. It pauses rather
  // than stops on hover, so letting go picks the sweep up where it left off.
  NumberAnimation on orbitAngle {
    running: root.opened
    paused: root.frozen
    loops: Animation.Infinite
    from: 0
    to: 360
    duration: root.orbitMs
  }

  PanelWindow {
    id: overlay

    readonly property var anchorWindow: root.anchorItem ? root.anchorItem.QsWindow.window : null

    screen: anchorWindow ? anchorWindow.screen : null
    // Outlives the logical close so the collapse has something to play on.
    visible: root.opened || scrim.opacity > 0.001
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore

    WlrLayershell.namespace: "omarchy-gravity"
    WlrLayershell.layer: WlrLayer.Overlay
    // Exclusive for as long as the panel is open, like the first-party
    // fullscreen overlays. The bar's popup panels prime Exclusive and then
    // settle on OnDemand so clicks can still reach other monitors, but
    // OnDemand only takes focus on map or on pointer entry -- which is a
    // coin flip for a panel summoned by a keybinding, with the pointer left
    // wherever the user last put it. A modal that swallows the keyboard is
    // the right trade here: every key it takes is one it has an answer for,
    // and Esc gives it back.
    //
    // Focus follows `opened`, never `visible`, so the keyboard is released
    // the moment the panel is logically closed rather than at the end of the
    // closing animation.
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }

    // Layer-shell hands the surface the keyboard, but Qt still needs an
    // active-focus target inside it before Keys handlers fire, and the item
    // tree is not laid out until the window maps.
    onBackingWindowVisibleChanged: if (backingWindowVisible && root.opened) Qt.callLater(root.grabFocus)

    Rectangle {
      id: scrim
      anchors.fill: parent
      // The theme's own menu scrim, but never less than enough to make the
      // desktop recede: this is a modal the user is aiming inside of, and a
      // readable browser page behind the ring competes with it.
      color: Util.alpha(Color.menu.scrim, Math.max(0.72, Color.menu.scrim.a))
      opacity: root.opened ? 1 : 0

      // The fade out is deliberately longer than the fade in: it has to hold
      // the surface open until the last icon has collapsed into the centre.
      Behavior on opacity {
        NumberAnimation {
          duration: root.opened ? 170 : 380
          easing.type: Easing.OutCubic
        }
      }
    }

    // Anywhere off the ring dismisses. The chips sit above this in the key
    // catcher, so their own handlers win.
    MouseArea {
      anchors.fill: parent
      enabled: root.opened
      acceptedButtons: Qt.AllButtons
      onClicked: root.close()
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // Arrows and hjkl both step one slot around the ring: on a circle
      // there is no second axis to spend up/down on.
      onMoveRequested: function(dx, dy) { root.moveSelection(dx !== 0 ? dx : dy) }
      onActivateRequested: root.activateSelection()
      onCloseRequested: root.close()
      // Tab belongs to the ring here rather than to the bar's panel cycle:
      // this panel is a centred overlay, not one of a row of bar popouts.
      onTabRequested: function(direction) { root.moveSelection(direction) }
      onTextKey: function(t) {
        var n = Number(t)
        if (!isFinite(n) || n < 1 || n > root.appCount) return
        root.cursorActive = true
        root.hoverActive = false
        root.selectedIndex = n - 1
        root.activateSelection()
      }

      Item {
        id: stage
        anchors.centerIn: parent
        width: root.stageSize
        height: root.stageSize
        opacity: root.opened ? 1 : 0
        scale: root.opened ? 1 : 0.92

        Behavior on opacity { NumberAnimation { duration: root.opened ? 140 : 260; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: root.opened ? 320 : 240; easing.type: Easing.OutCubic } }

        // The track the icons ride. Drawn, not implied: with the ring visible
        // an app that is mid-flight on the way out still reads as heading
        // somewhere specific.
        Rectangle {
          anchors.centerIn: parent
          width: root.orbitRadius * 2
          height: width
          radius: width / 2
          color: "transparent"
          border.width: Math.max(1, Style.space(1))
          border.color: Util.alpha(root.accentInk, 0.18)
        }

        Rectangle {
          anchors.centerIn: parent
          width: root.orbitRadius * 1.16
          height: width
          radius: width / 2
          color: "transparent"
          border.width: Math.max(1, Style.space(1))
          border.color: Util.alpha(root.ink, 0.07)
        }

        // ---- The hub. Idle, it is the same turning mark as the bar icon, so
        //      the thing you clicked and the thing you landed on are visibly
        //      one object. Selected, it names what you are pointing at, which
        //      is why the icons carry no labels of their own -- six captions
        //      sliding around a circle would be noise.
        Item {
          id: hub
          anchors.centerIn: parent
          width: root.hubSize
          height: width

          Rectangle {
            anchors.centerIn: parent
            width: hub.width * (root.selectedApp ? 1.22 : 1.08)
            height: width
            radius: width / 2
            color: Util.alpha(root.accentInk, root.selectedApp ? 0.12 : 0.06)

            Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Color.popups.background
            border.width: Math.max(1, Style.space(1))
            border.color: Util.alpha(root.accentInk, root.selectedApp ? 0.55 : 0.26)

            Behavior on border.color { ColorAnimation { duration: 180 } }
          }

          // Idle face.
          Item {
            anchors.fill: parent
            opacity: root.selectedApp ? 0 : 1
            visible: opacity > 0.01

            Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

            Column {
              anchors.centerIn: parent
              spacing: Style.space(6)

              OrbitGlyph {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.round(hub.width * 0.42)
                height: width
                // The core is the theme's accent in both places the mark
                // appears, so the bar icon and the hub read as one object
                // even under a theme whose selection role is not the accent.
                coreColor: Color.accent
                satelliteColor: root.ink
                spinning: root.opened
                speed: 0.75
              }

              Text {
                textFormat: Text.PlainText
                width: hub.width - Style.space(26)
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: root.appCount > 0 ? "Gravity" : "No apps yet"
                color: root.muted
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              // Only on a fresh install, and only for as long as it is true:
              // an empty ring is otherwise indistinguishable from a broken one.
              Text {
                textFormat: Text.PlainText
                width: hub.width - Style.space(26)
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                visible: root.appCount === 0
                text: "Open some apps"
                color: root.faint
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // Selected face.
          Column {
            anchors.centerIn: parent
            width: hub.width - Style.space(26)
            spacing: Style.space(4)
            opacity: root.selectedApp ? 1 : 0
            visible: opacity > 0.01

            Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              maximumLineCount: 2
              wrapMode: Text.WordWrap
              text: root.selectedApp ? root.selectedApp.name : ""
              color: root.ink
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: {
                if (!root.selectedApp) return ""
                var app = root.selectedApp
                var launches = app.count === 1 ? "1 launch" : app.count + " launches"
                if (app.pinned) return app.count > 0 ? "Pinned · " + launches : "Pinned"
                return launches
              }
              color: root.muted
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.features: ({ "tnum": 1 })
            }
          }
        }

        // ---- The apps.
        Repeater {
          model: root.apps

          Item {
            id: sat

            required property var modelData
            required property int index

            readonly property bool selected: root.selectedIndex === sat.index
            readonly property real angle: Orbit.angleFor(sat.index, root.appCount, root.orbitAngle)

            // 0 at the centre, 1 on the ring. Everything about the opening
            // and closing animation is this one number.
            property real burst: root.staged ? 1 : 0
            readonly property real distance: root.orbitRadius * sat.burst

            // Each icon leaves a beat after the one before it on the way out,
            // and the order reverses on the way back in, so the ring
            // assembles and disassembles from the same end.
            Behavior on burst {
              SequentialAnimation {
                PauseAnimation {
                  duration: root.staged ? sat.index * 55 : (root.appCount - 1 - sat.index) * 26
                }
                NumberAnimation {
                  duration: root.staged ? 520 : 240
                  easing.type: root.staged ? Easing.OutBack : Easing.InCubic
                  easing.overshoot: 1.25
                }
              }
            }

            width: root.chipSize
            height: root.chipSize
            x: stage.width / 2 + sat.distance * Math.cos(sat.angle * Math.PI / 180) - width / 2
            y: stage.height / 2 + sat.distance * Math.sin(sat.angle * Math.PI / 180) - height / 2
            opacity: Math.max(0, Math.min(1, sat.burst * 1.6))
            // Scale is driven straight off the burst here; the selection
            // scale lives on the child so the two never fight over one
            // property or damp each other's animation.
            scale: 0.35 + 0.65 * Math.min(1, sat.burst)

            Item {
              id: chip
              anchors.fill: parent
              scale: sat.selected ? 1.16 : 1.0

              Behavior on scale {
                NumberAnimation { duration: 240; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
              }

              // Halo. Two soft circles rather than a blur: cheap, and it
              // holds up against a bright wallpaper behind the scrim.
              Rectangle {
                anchors.centerIn: parent
                width: parent.width * (sat.selected ? 1.5 : 1.0)
                height: width
                radius: width / 2
                color: Util.alpha(root.accentInk, sat.selected ? 0.1 : 0)

                Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                Behavior on color { ColorAnimation { duration: 200 } }
              }

              Rectangle {
                anchors.centerIn: parent
                width: parent.width * (sat.selected ? 1.22 : 1.0)
                height: width
                radius: width / 2
                color: Util.alpha(root.accentInk, sat.selected ? 0.16 : 0)

                Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                Behavior on color { ColorAnimation { duration: 200 } }
              }

              Rectangle {
                id: chipFace
                anchors.fill: parent
                radius: Math.round(width * 0.3)
                color: Util.alpha(Color.popups.background, 0.86)
                border.width: sat.selected ? Math.max(1, Style.space(2)) : Math.max(1, Style.space(1))
                border.color: sat.selected ? root.accentInk : Util.alpha(root.ink, 0.16)

                Behavior on border.color { ColorAnimation { duration: 160 } }

                // Layered over the chip's own surface rather than replacing
                // it, so a selected icon does not end up sitting on the
                // wallpaper showing through the scrim.
                Rectangle {
                  anchors.fill: parent
                  radius: parent.radius
                  color: sat.selected ? Style.hoverFillFor(root.ink, Color.accent, Color.urgent) : "transparent"

                  Behavior on color { ColorAnimation { duration: 160 } }
                }
              }

              Image {
                anchors.centerIn: parent
                width: root.iconSize
                height: root.iconSize
                source: root.iconUrl(sat.modelData)
                sourceSize.width: Math.round(root.iconSize * Screen.devicePixelRatio)
                sourceSize.height: Math.round(root.iconSize * Screen.devicePixelRatio)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
                mipmap: true
              }

              // Pinned apps say so on the chip, not only in the hub: it is
              // the difference between "you use this most" and "you asked
              // for this", and the ranking is easier to trust when the two
              // are told apart at a glance.
              Rectangle {
                visible: sat.modelData.pinned
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.space(6)
                width: Style.space(4)
                height: width
                radius: width / 2
                color: root.accentInk
                opacity: 0.8
              }

              // The number key that activates this slot, shown once the
              // keyboard is in play and not before.
              Rectangle {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: Style.space(4)
                width: Style.space(16)
                height: width
                radius: width / 2
                color: Util.alpha(Color.popups.background, 0.9)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.accentInk, 0.5)
                opacity: root.cursorActive ? 1 : 0
                visible: opacity > 0.01 && sat.index < 9

                Behavior on opacity { NumberAnimation { duration: 160 } }

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: String(sat.index + 1)
                  color: root.accentInk
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.features: ({ "tnum": 1 })
                }
              }

              MouseArea {
                anchors.fill: parent
                enabled: root.opened
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selectByPointer(sat.index)
                onExited: root.releasePointer(sat.index)
                onClicked: root.activate(sat.index)
              }
            }
          }
        }
      }
    }
  }
}
