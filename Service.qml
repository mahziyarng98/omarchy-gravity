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

  // class -> { launches: [...], desktopId, name, icon }
  property var apps: ({})

  // Desktop ids held in reserve to fill a ring that real usage has not filled
  // yet. Rolled once and persisted, so a cold-start ring is the same shelf
  // every time you open it.
  property var suggestions: []
  property bool storeLoaded: false
  property bool dirReady: false
  property bool writePending: false

  function nowSeconds() {
    return Math.floor(Date.now() / 1000)
  }

  // The widget's own `ignored` list, read from the same shell.json entry the
  // panel reads. A service is not handed the widget's settings -- it is not a
  // widget -- so it finds its own entry by manifest id. Reading it here is
  // what lets an ignored app be kept out of the reserve entirely instead of
  // occupying a slot and being skipped later when the ring is drawn.
  readonly property var ignoredClasses: {
    var config = root.shell && root.shell.shellConfig ? root.shell.shellConfig : null
    var id = root.manifest && root.manifest.id ? String(root.manifest.id) : ""
    if (!config || !id) return []

    var entry = null
    var layout = config.bar && config.bar.layout ? config.bar.layout : {}
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length && !entry; s++) {
      var list = layout[sections[s]]
      if (!list || !Array.isArray(list)) continue
      for (var i = 0; i < list.length; i++) {
        if (list[i] && String(list[i].id) === id) { entry = list[i]; break }
      }
    }
    // A non-bar placement is possible for any plugin, so look there too rather
    // than silently ignoring the setting when the widget is not on the bar.
    if (!entry && Array.isArray(config.plugins)) {
      for (var j = 0; j < config.plugins.length; j++) {
        if (config.plugins[j] && String(config.plugins[j].id) === id) { entry = config.plugins[j]; break }
      }
    }
    return entry ? Orbit.parseList(entry.ignored) : []
  }

  readonly property var ignoredIndex: {
    var index = ({})
    for (var i = 0; i < root.ignoredClasses.length; i++) index[Orbit.classKey(root.ignoredClasses[i])] = true
    return index
  }

  // Editing the list should take effect now, not at the next reroll: anything
  // it newly covers falls out of the pool below, so the refresh drops it from
  // the reserve and pulls a fresh candidate up in its place.
  onIgnoredIndexChanged: root.refreshSuggestions()

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

  function ageText(seconds) {
    var n = Math.max(0, Math.floor(Number(seconds) || 0))
    if (n < 90) return n + "s ago"
    if (n < 5400) return Math.round(n / 60) + "m ago"
    if (n < 172800) return Math.round(n / 3600) + "h ago"
    return (n / 86400).toFixed(1) + "d ago"
  }

  // Sweep the retention horizon on a timer as well as on every write. Nothing
  // needs to happen for launches to age out of the *ranking* -- that is
  // computed from the timestamps against the clock, so it is always current --
  // but the file should not carry a week-old launch around forever, and
  // rewriting it when the sweep bites is also what nudges every open panel's
  // file watcher into re-reading.
  function sweep() {
    if (!root.storeLoaded) return
    var swept = Orbit.pruneApps(root.apps, root.nowSeconds())
    if (!swept.changed) return
    root.apps = swept.apps
    writeDebounce.restart()
  }

  // The pool is Omarchy's own launcher list -- DesktopEntries minus NoDisplay,
  // minus Hidden/OnlyShowIn/NotShowIn, minus the launcher.hides list -- rather
  // than a second set of rules invented here. On top of that a suggestion has
  // to be something a user could actually click: an icon to draw and a command
  // to run. Anything without both is a service or a MIME shim, whatever its
  // desktop file claims.
  function suggestionPool() {
    var library = root.shell ? root.shell.appLibrary : null
    if (!library || typeof library.sortedEntries !== "function") return []
    var rows = []
    try {
      rows = library.sortedEntries("") || []
    } catch (e) {
      return []
    }
    var out = []
    for (var i = 0; i < rows.length; i++) {
      var entry = rows[i] && rows[i].entry
      if (!entry || entry.noDisplay === true) continue
      var id = String(entry.id || "")
      if (!id) continue
      if (!String(entry.icon || "")) continue
      if (!String(entry.execString || entry.command || "")) continue
      // Matched on the same class the ring would draw this candidate under --
      // StartupWMClass when the entry declares one, the desktop id otherwise --
      // so `ignored` means the same thing here as it does everywhere else.
      if (root.ignoredIndex[Orbit.classKey(String(entry.startupClass || id))]) continue
      out.push(id)
    }
    return out
  }

  function shuffled(values) {
    var out = values.slice()
    for (var i = out.length - 1; i > 0; i--) {
      var j = Math.floor(Math.random() * (i + 1))
      var swap = out[i]
      out[i] = out[j]
      out[j] = swap
    }
    return out
  }

  // Keep the reserve honest without disturbing it: entries that no longer
  // resolve are dropped, the rest keep their order and therefore their place
  // in the ring, and the list is topped back up from what is installed. The
  // only two things that change a suggestion are the two that should -- it was
  // uninstalled, or a real app took its slot.
  function refreshSuggestions() {
    if (!root.storeLoaded) return
    var pool = suggestionPool()
    if (!pool.length) return

    var installed = {}
    for (var i = 0; i < pool.length; i++) installed[pool[i]] = true

    var kept = []
    var seen = {}
    for (var j = 0; j < root.suggestions.length; j++) {
      var id = String(root.suggestions[j])
      if (!installed[id] || seen[id]) continue
      seen[id] = true
      kept.push(id)
    }
    var changed = kept.length !== root.suggestions.length

    // Anything above the cap goes now, not at the next reroll, so the reserve
    // is never observably longer than it claims to be -- a hand-edited file is
    // normalised on the load that follows it.
    if (kept.length > Orbit.SUGGESTION_POOL) {
      kept = kept.slice(0, Orbit.SUGGESTION_POOL)
      changed = true
    }

    if (kept.length < Orbit.SUGGESTION_POOL) {
      var candidates = []
      for (var k = 0; k < pool.length; k++) if (!seen[pool[k]]) candidates.push(pool[k])
      candidates = root.shuffled(candidates)
      for (var m = 0; m < candidates.length && kept.length < Orbit.SUGGESTION_POOL; m++) {
        kept.push(candidates[m])
        changed = true
      }
    }

    if (!changed) return
    root.suggestions = kept
    writeDebounce.restart()
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
    var stored = Orbit.parseStore(raw)
    root.apps = Orbit.mergeApps(stored.apps, root.apps)
    root.suggestions = stored.suggestions
    root.storeLoaded = true
    // A machine that was off for a week comes back with a store full of
    // launches that expired while it slept. Sweep once on load rather than
    // waiting up to ten minutes for the timer to notice.
    root.sweep()
    root.refreshSuggestions()
    // Normalise the file itself on every load: a store written by an older
    // version, or edited by hand, is rewritten in the current shape rather
    // than left on disk disagreeing with what is held in memory.
    writeDebounce.restart()
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
    usageFile.setText(Orbit.serializeStore(root.apps, root.suggestions))
  }

  // ---- IPC. `omarchy-shell gravity-usage ...` is a maintenance surface for
  //      the store itself; the panel's own open/close/toggle live on the
  //      `gravity` target in BarWidget.qml.
  IpcHandler {
    target: "gravity-usage"

    // The ranking as it stands right now: launches inside the three-day
    // window, most first. The parenthetical is what is still on disk but no
    // longer counting, which is what makes an app ageing out visible instead
    // of just silently vanishing from the ring.
    function list(): string {
      var now = root.nowSeconds()
      var entries = []
      for (var cls in root.apps) {
        var record = root.apps[cls]
        var kept = record.launches ? record.launches.length : 0
        entries.push({
          cls: cls,
          counted: Orbit.launchesWithin(record.launches || [], now),
          kept: kept,
          last: Orbit.lastLaunchOf(record.launches || [])
        })
      }
      entries.sort(function(a, b) {
        if (b.counted !== a.counted) return b.counted - a.counted
        return b.last - a.last
      })
      var lines = []
      for (var i = 0; i < entries.length; i++) {
        var e = entries[i]
        var aged = e.kept - e.counted
        lines.push(e.counted + "\t" + e.cls
          + "\t(last " + root.ageText(now - e.last) + (aged > 0 ? ", " + aged + " aged out" : "") + ")")
      }
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

    // The reserve, in the order the ring will draw from it.
    function suggestions(): string {
      if (!root.suggestions.length) return "no suggestions held"
      return root.suggestions.join("\n")
    }

    // Throw the shelf away and roll a new one.
    function reroll(): string {
      root.suggestions = []
      root.refreshSuggestions()
      return root.suggestions.length
        ? "rerolled " + root.suggestions.length + " suggestions"
        : "no installed apps to suggest"
    }
  }

  Connections {
    target: root.shell ? root.shell.appLibrary : null
    ignoreUnknownSignals: true
    function onAppsChanged() { root.refreshSuggestions() }
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.refreshSuggestions() }
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
  // Kept short: everything between the last launch and this firing is what a
  // sudden shutdown would cost, and the file is small enough that writing it
  // more often is free.
  Timer {
    id: writeDebounce
    interval: 400
    onTriggered: root.writeStore()
  }

  Timer {
    id: sweepTimer
    interval: 10 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: root.sweep()
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
  //
  // blockWrites makes setText return only once the bytes are down, so a
  // launch recorded before a shutdown is on disk rather than queued behind an
  // event loop that is about to stop. The file is a few KB; the cost is
  // nothing next to losing the day's history.
  FileView {
    id: usageFile
    path: root.usagePath
    watchChanges: false
    atomicWrites: true
    blockWrites: true
    printErrors: false
    onLoaded: root.adoptStore(usageFile.text())
    onLoadFailed: root.adoptStore("")
  }

  Component.onCompleted: mkdirProcess.running = true

  // A clean shutdown (logout, omarchy-restart-shell, a plugin reload) tears
  // this object down while a debounced write may still be pending. Flush it.
  Component.onDestruction: {
    if (!writeDebounce.running) return
    writeDebounce.stop()
    root.writeStore()
  }
}
