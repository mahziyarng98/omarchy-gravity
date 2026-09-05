// Checks Orbit.js -- the store, the ranking, the geometry, and the two bits of
// Hyprland output parsing -- against cases that are awkward to reproduce by
// hand on a live desktop: a corrupt store, a window title with commas in it,
// two windows of one class, a pin for an app that has never been launched.
//
//   node test/orbit-test.js

var path = require("path")
var O = require(path.join(__dirname, "..", "Orbit.js"))

var failures = 0
function check(label, got, want) {
  var g = JSON.stringify(got), w = JSON.stringify(want)
  if (g === w) { console.log("  ok   " + label) }
  else { failures++; console.log("  FAIL " + label + "\n         got  " + g + "\n         want " + w) }
}

function names(entries) {
  return entries.map(function(e) { return e.cls })
}

// Every app in these fixtures resolves to a desktop entry unless a test says
// otherwise, which is what the real DesktopEntries lookup does for anything
// installed.
function describeAll(cls) {
  return { desktopId: String(cls).toLowerCase(), name: String(cls), icon: String(cls).toLowerCase() }
}

console.log("Config lists")
check("comma separated", O.parseList("v2rayn, kitty ,firefox"), ["v2rayn", "kitty", "firefox"])
check("newlines and semicolons", O.parseList("a\nb; c"), ["a", "b", "c"])
check("empty", O.parseList(""), [])
check("array passes through", O.parseList(["a", " ", "b"]), ["a", "b"])

console.log("Store parsing")
check("empty text", O.parseStore(""), { version: 1, apps: {} })
check("not json", O.parseStore("{oops"), { version: 1, apps: {} })
check("array instead of object", O.parseStore("[1,2]"), { version: 1, apps: {} })
check("missing fields are filled", O.parseStore('{"apps":{"kitty":{}}}').apps.kitty,
  { count: 0, last: 0, desktopId: "", name: "", icon: "" })
check("negative count floors at zero", O.parseStore('{"apps":{"kitty":{"count":-4}}}').apps.kitty.count, 0)
check("round trip", O.parseStore(O.serializeStore({ kitty: { count: 3, last: 10, desktopId: "kitty", name: "kitty", icon: "kitty" } })).apps.kitty.count, 3)

console.log("Counting launches")
var apps = O.recordLaunch({}, "kitty", 100, { desktopId: "kitty", name: "kitty" })
check("first launch", apps.kitty.count, 1)
apps = O.recordLaunch(apps, "kitty", 200, {})
check("second launch", apps.kitty.count, 2)
check("timestamp follows the launch", apps.kitty.last, 200)
check("metadata survives a launch that could not resolve one", apps.kitty.desktopId, "kitty")
apps = O.recordLaunch(apps, "KITTY", 300, {})
check("case folds onto the first spelling seen", Object.keys(apps), ["kitty"])
check("case-folded launch still counts", apps.kitty.count, 3)
check("blank class is ignored", Object.keys(O.recordLaunch({}, "   ", 100, {})), [])
var before = O.recordLaunch({}, "kitty", 100, {})
O.recordLaunch(before, "kitty", 200, {})
check("recordLaunch does not mutate its input", before.kitty.count, 1)

console.log("Merging a store read off disk")
var merged = O.mergeApps(
  { kitty: { count: 5, last: 10, desktopId: "kitty", name: "kitty", icon: "" } },
  { Kitty: { count: 2, last: 40, desktopId: "", name: "", icon: "kitty" } })
check("counts add", merged.kitty.count, 7)
check("newest timestamp wins", merged.kitty.last, 40)
check("metadata fills the gaps", merged.kitty.icon, "kitty")
check("unseen app is carried over", O.mergeApps({}, { foot: { count: 1 } }).foot.count, 1)

console.log("Ranking")
var store = {
  firefox: { count: 40, last: 500 },
  kitty: { count: 12, last: 900 },
  foot: { count: 12, last: 100 },
  v2rayN: { count: 3, last: 20 },
  obsidian: { count: 1, last: 5 }
}
check("most launched first, ties broken by recency",
  names(O.rankApps(store, { slots: 6, describe: describeAll })),
  ["firefox", "kitty", "foot", "v2rayN", "obsidian"])
check("slot cap", names(O.rankApps(store, { slots: 3, describe: describeAll })), ["firefox", "kitty", "foot"])
check("six is the ceiling", O.clampSlots(99), 6)
check("three is the floor", O.clampSlots(1), 3)
check("garbage slot count falls back to six", O.clampSlots("banana"), 6)

console.log("Pinning")
check("pins lead, in configured order, and are not repeated below",
  names(O.rankApps(store, { slots: 4, pinned: "v2rayN, obsidian", describe: describeAll })),
  ["v2rayN", "obsidian", "firefox", "kitty"])
check("a pin the store has never seen still gets a slot",
  names(O.rankApps(store, { slots: 3, pinned: "steam", describe: describeAll })),
  ["steam", "firefox", "kitty"])
check("a pin with no desktop entry is still shown, because it was asked for",
  names(O.rankApps({}, { slots: 6, pinned: "weird-thing", describe: function() { return null } })),
  ["weird-thing"])
check("pins are flagged", O.rankApps(store, { slots: 2, pinned: "kitty", describe: describeAll })[0].pinned, true)
check("pins outnumbering the slots are truncated",
  names(O.rankApps(store, { slots: 3, pinned: "a,b,c,d", describe: describeAll })), ["a", "b", "c"])
check("case-insensitive pin does not duplicate its app",
  names(O.rankApps(store, { slots: 3, pinned: "FIREFOX", describe: describeAll })),
  ["FIREFOX", "kitty", "foot"])

console.log("Exclusions")
check("ignored apps never rank",
  names(O.rankApps(store, { slots: 6, ignored: "firefox, kitty", describe: describeAll })),
  ["foot", "v2rayN", "obsidian"])
check("ignoring beats pinning", names(O.rankApps(store, { slots: 6, pinned: "firefox", ignored: "firefox", describe: describeAll })),
  ["kitty", "foot", "v2rayN", "obsidian"])
check("an app with no desktop entry cannot earn a slot on its own",
  names(O.rankApps({ ghost: { count: 99 } }, { slots: 6, describe: function() { return null } })), [])
check("a NoDisplay entry cannot earn a slot",
  names(O.rankApps({ "xdg-desktop-portal-gtk": { count: 50 } },
    { slots: 6, describe: function() { return { desktopId: "xdg-desktop-portal-gtk", name: "Portal", hidden: true } } })), [])
check("but it can still be pinned into one",
  names(O.rankApps({ "xdg-desktop-portal-gtk": { count: 50 } },
    { slots: 6, pinned: "xdg-desktop-portal-gtk", describe: function() { return { desktopId: "xdg-desktop-portal-gtk", name: "Portal", hidden: true } } })),
  ["xdg-desktop-portal-gtk"])
check("a cached desktop id does not resurrect a hidden entry",
  names(O.rankApps({ "xdg-desktop-portal-gtk": { count: 50, desktopId: "xdg-desktop-portal-gtk" } },
    { slots: 6, describe: function() { return { desktopId: "", name: "", hidden: true } } })), [])
check("zero-count entries do not rank",
  names(O.rankApps({ ghost: { count: 0 } }, { slots: 6, describe: describeAll })), [])
check("name and icon come from the live lookup",
  O.rankApps({ kitty: { count: 1, name: "stale", icon: "stale" } }, { slots: 6, describe: function() { return { desktopId: "kitty", name: "Kitty", icon: "kitty-icon" } } })[0].icon,
  "kitty-icon")
check("cached name survives an uninstalled desktop entry",
  O.rankApps({ kitty: { count: 1, desktopId: "kitty", name: "Kitty" } }, { slots: 6, describe: function() { return null } })[0].name,
  "Kitty")

console.log("Ring geometry")
check("first slot sits at twelve o'clock", O.angleFor(0, 6, 0), -90)
check("six slots are sixty degrees apart", O.angleFor(1, 6, 0), -30)
check("slots run clockwise", O.angleFor(3, 4, 0) - O.angleFor(2, 4, 0), 90)
check("rotation offsets the whole ring", O.angleFor(0, 6, 45), -45)
check("index wraps", O.angleFor(6, 6, 0), O.angleFor(0, 6, 0))
var top = O.pointOn(100, 100, 50, -90)
check("twelve o'clock is directly above the centre", [Math.round(top.x), Math.round(top.y)], [100, 50])
var right = O.pointOn(0, 0, 10, 0)
check("zero degrees points right", [Math.round(right.x), Math.round(right.y)], [10, 0])

console.log("Hyprland openwindow events")
check("plain event", O.classFromOpenWindow("0x5591,1,kitty,~/code"), "kitty")
check("commas in the title do not shift the class",
  O.classFromOpenWindow("0x5591,1,firefox,Buy milk, eggs, bread — Mozilla Firefox"), "firefox")
check("class with no title", O.classFromOpenWindow("0x5591,1,v2rayN"), "v2rayN")
check("truncated event", O.classFromOpenWindow("0x5591,1"), "")
check("empty event", O.classFromOpenWindow(""), "")

console.log("Choosing a window to focus")
var clients = [
  { address: "0xaaa", class: "firefox", title: "one" },
  { address: "0xbbb", class: "kitty", title: "two" },
  { address: "0xccc", class: "kitty", title: "three" }
]
check("first match in the list, every time", O.pickWindowAddress(clients, "kitty"), "0xbbb")
check("same answer on the second click", O.pickWindowAddress(clients, "kitty"), "0xbbb")
check("case-insensitive", O.pickWindowAddress(clients, "KITTY"), "0xbbb")
check("falls back to the initial class",
  O.pickWindowAddress([{ address: "0xddd", class: "", initialClass: "Spotify" }], "spotify"), "0xddd")
check("no window of that class", O.pickWindowAddress(clients, "obsidian"), "")
check("empty client list", O.pickWindowAddress([], "kitty"), "")
check("bad hyprctl output", O.pickWindowAddress(O.parseClients("not json"), "kitty"), "")
check("clients parse", O.parseClients('[{"address":"0x1"}]').length, 1)

console.log(failures === 0 ? "\nAll checks passed." : "\n" + failures + " check(s) failed.")
process.exit(failures === 0 ? 0 : 1)
