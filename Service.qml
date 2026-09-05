import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Orbit.js" as Orbit

// Gravity's usage tracker. One instance, mounted by the shell for as long as
// the plugin is enabled -- not per monitor, and not tied to the panel being
// open, which is the whole point: the orbit can only rank what was counted
// while nobody was looking.
//
// It listens to Hyprland's event socket (Quickshell keeps the connection and
// re-establishes it across a compositor restart) and counts one launch per
// `openwindow`, whatever opened the window: the orbit, a keybinding, a
// terminal, an autostart, a link handler. Clicking an icon in the panel is
// not special-cased anywhere -- it opens a window like everything else, and
// that window is what gets counted.
//
// The store is a plain JSON file with one writer (this) and any number of
// readers (a Panel per bar surface), so nothing here needs a lock: the panel
// watches the file and re-reads it.
Item {
  id: root

  // Injected by the shell when it mounts a `service` plugin.
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string home: Quickshell.env("HOME")
  // Same convention as the first-party agents plugin: mutable per-machine
  // state lives under the XDG state dir, never in the config tree.
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/omarchy/gravity"
  readonly property string usagePath: stateDir + "/usage.json"

  // class -> { count, last, desktopId, name, icon }
  property var apps: ({})
  property bool storeLoaded: false
  property bool dirReady: false
  property bool writePending: false

  function nowSeconds() {
    return Math.floor(Date.now() / 1000)
  }

  // Whatever we can learn about a class at the moment it opens, cached into
  // the record. The panel re-resolves this live, but a cached name and icon
  // keep an app readable in the orbit even when its .desktop file is gone
  // (uninstalled, renamed, or a Flatpak mid-update).
  function describe(cls) {
    var entry = null
    try {
      entry = DesktopEntries.heuristicLookup(cls)
    } catch (e) {
      entry = null
    }
    if (!entry) return {}
    return {
      desktopId: String(entry.id || ""),
      name: String(entry.name || ""),
      icon: String(entry.icon || "")
    }
  }

  function recordClass(cls) {
    var name = Orbit.normalizeClass(cls)
    if (!name) return
    root.apps = Orbit.recordLaunch(root.apps, name, root.nowSeconds(), root.describe(name))
    writeDebounce.restart()
  }

  // The file is authoritative for everything counted before this process
  // started; anything counted since is added on top rather than replaced,
  // because a window can open in the gap between the Hyprland connection
  // coming up and the first read finishing.
  function adoptStore(raw) {
    if (root.storeLoaded) return
    root.apps = Orbit.mergeApps(Orbit.parseStore(raw).apps, root.apps)
    root.storeLoaded = true
    if (root.writePending) writeDebounce.restart()
  }

  function writeStore() {
    if (!root.storeLoaded) {
      // Writing before the read lands would truncate the history.
      writeDebounce.restart()
      return
    }
    if (!root.dirReady) {
      root.writePending = true
      mkdirProcess.running = true
      return
    }
    root.writePending = false
    usageFile.setText(Orbit.serializeStore(root.apps))
  }

  // ---- IPC. `omarchy-shell gravity-usage ...` is a maintenance surface for
  //      the store itself; the panel's own open/close/toggle live on the
  //      `gravity` target in BarWidget.qml.
  IpcHandler {
    target: "gravity-usage"

    // Print the ranking exactly as the store has it, most-launched first.
    function list(): string {
      var lines = []
      var entries = []
      for (var cls in root.apps) entries.push({ cls: cls, record: root.apps[cls] })
      entries.sort(function(a, b) { return b.record.count - a.record.count })
      for (var i = 0; i < entries.length; i++)
        lines.push(entries[i].record.count + "\t" + entries[i].cls)
      return lines.length ? lines.join("\n") : "no launches recorded yet"
    }

    // Count a launch by hand. Useful for testing the ranking without waiting
    // for real usage to accumulate.
    function record(windowClass: string): string {
      root.recordClass(windowClass)
      return "recorded " + Orbit.normalizeClass(windowClass)
    }

    // Forget one app, or everything. Both mark the store loaded even if the
    // first read has not landed yet: deleting is a statement about what the
    // store should now contain, and adoptStore would otherwise merge the file
    // back in a moment later and silently undo it.
    function forget(windowClass: string): string {
      var key = Orbit.findKey(root.apps, windowClass)
      if (!key) return "unknown: " + Orbit.normalizeClass(windowClass)
      var next = {}
      for (var cls in root.apps) if (cls !== key) next[cls] = root.apps[cls]
      root.apps = next
      root.storeLoaded = true
      writeDebounce.restart()
      return "forgot " + key
    }

    function reset(): string {
      root.apps = ({})
      root.storeLoaded = true
      writeDebounce.restart()
      return "usage cleared"
    }

    function path(): string {
      return root.usagePath
    }
  }

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (event.name !== "openwindow") return
      root.recordClass(Orbit.classFromOpenWindow(event.data))
    }
  }

  // Bursts are common -- a session restore opens a dozen windows at once --
  // so counting is immediate but the file is written once the burst settles.
  Timer {
    id: writeDebounce
    interval: 1500
    onTriggered: root.writeStore()
  }

  Process {
    id: mkdirProcess
    command: ["mkdir", "-p", root.stateDir]
    onExited: function(exitCode) {
      root.dirReady = exitCode === 0
      if (root.dirReady && root.writePending) root.writeStore()
    }
  }

  // watchChanges stays off: this is the only writer, and re-reading our own
  // atomic write would race the next increment against the file.
  FileView {
    id: usageFile
    path: root.usagePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.adoptStore(usageFile.text())
    onLoadFailed: root.adoptStore("")
  }

  Component.onCompleted: mkdirProcess.running = true
}
