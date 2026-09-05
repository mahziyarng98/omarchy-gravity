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

// A fixed clock, so "three days ago" means the same thing on every run.
var NOW = 1800000000
var HOUR = 3600
var DAY = 24 * HOUR
function ago(hours) { return NOW - Math.round(hours * HOUR) }
function rank(apps, opts) {
  opts = opts || {}
  if (opts.now === undefined) opts.now = NOW
  if (opts.describe === undefined) opts.describe = describeAll
  if (opts.slots === undefined) opts.slots = 6
  return O.rankApps(apps, opts)
}

console.log("Config lists")
check("comma separated", O.parseList("v2rayn, kitty ,firefox"), ["v2rayn", "kitty", "firefox"])
check("newlines and semicolons", O.parseList("a\nb; c"), ["a", "b", "c"])
check("empty", O.parseList(""), [])
check("array passes through", O.parseList(["a", " ", "b"]), ["a", "b"])

console.log("Store parsing")
check("empty text", O.parseStore(""), { version: 2, apps: {}, suggestions: [] })
check("not json", O.parseStore("{oops"), { version: 2, apps: {}, suggestions: [] })
check("array instead of object", O.parseStore("[1,2]"), { version: 2, apps: {}, suggestions: [] })
check("missing fields are filled", O.parseStore('{"apps":{"kitty":{}}}').apps.kitty,
  { launches: [], desktopId: "", name: "", icon: "" })
check("launch times are sorted", O.parseStore('{"apps":{"k":{"launches":[30,10,20]}}}').apps.k.launches, [10, 20, 30])
check("junk timestamps are dropped", O.parseStore('{"apps":{"k":{"launches":[10,"x",-4,0,null,20]}}}').apps.k.launches, [10, 20])
check("a version 1 record migrates to an empty window",
  O.parseStore('{"version":1,"apps":{"kitty":{"count":97,"last":123,"name":"kitty"}}}').apps.kitty,
  { launches: [], desktopId: "", name: "kitty", icon: "" })
check("round trip", O.parseStore(O.serializeStore({ kitty: { launches: [10, 20] } })).apps.kitty.launches, [10, 20])
check("serialized store declares version 2", JSON.parse(O.serializeStore({})).version, 2)

console.log("Counting launches")
var apps = O.recordLaunch({}, "kitty", ago(1), { desktopId: "kitty", name: "kitty" })
check("first launch", apps.kitty.launches, [ago(1)])
apps = O.recordLaunch(apps, "kitty", NOW, {})
check("second launch appends", apps.kitty.launches, [ago(1), NOW])
check("metadata survives a launch that could not resolve one", apps.kitty.desktopId, "kitty")
apps = O.recordLaunch(apps, "KITTY", NOW, {})
check("case folds onto the first spelling seen", Object.keys(apps), ["kitty"])
check("case-folded launch still lands in the same list", apps.kitty.launches.length, 3)
check("two launches in one second are two launches", apps.kitty.launches, [ago(1), NOW, NOW])
check("blank class is ignored", Object.keys(O.recordLaunch({}, "   ", NOW, {})), [])
var before = O.recordLaunch({}, "kitty", NOW, {})
O.recordLaunch(before, "kitty", NOW, {})
check("recordLaunch does not mutate its input", before.kitty.launches.length, 1)
check("writing prunes past the retention horizon",
  O.recordLaunch({ kitty: { launches: [ago(24 * 9), ago(24 * 5), ago(10)] } }, "kitty", NOW, {}).kitty.launches,
  [ago(10), NOW])

console.log("Merging a store read off disk")
var merged = O.mergeApps(
  { kitty: { launches: [ago(5), ago(9)], desktopId: "kitty", name: "kitty", icon: "" } },
  { Kitty: { launches: [ago(1)], desktopId: "", name: "", icon: "kitty" } })
check("launch lists combine, in order", merged.kitty.launches, [ago(9), ago(5), ago(1)])
check("metadata fills the gaps", merged.kitty.icon, "kitty")
check("unseen app is carried over", O.mergeApps({}, { foot: { launches: [ago(2)] } }).foot.launches, [ago(2)])
check("nothing is lost when both sides know an app",
  O.mergeApps({ a: { launches: [1, 2] } }, { a: { launches: [3] } }).a.launches.length, 3)

console.log("Ranking")
var store = {
  firefox:  { launches: [ago(2), ago(6), ago(30), ago(50)] },   // 4 in window
  kitty:    { launches: [ago(1), ago(12), ago(60)] },           // 3, most recent
  foot:     { launches: [ago(20), ago(40), ago(65)] },          // 3, staler
  v2rayN:   { launches: [ago(3)] },                             // 1, recent
  obsidian: { launches: [ago(71)] }                             // 1, nearly aged out
}
check("most launched first, ties broken by recency",
  names(rank(store)),
  ["firefox", "kitty", "foot", "v2rayN", "obsidian"])
check("counts are the windowed counts", rank(store).map(function(e) { return e.count }), [4, 3, 3, 1, 1])
check("slot cap", names(rank(store, { slots: 3 })), ["firefox", "kitty", "foot"])
check("six is the ceiling", O.clampSlots(99), 6)
check("three is the floor", O.clampSlots(1), 3)
check("garbage slot count falls back to six", O.clampSlots("banana"), 6)

console.log("Pinning")
check("pins lead, in configured order, and are not repeated below",
  names(rank(store, { slots: 4, pinned: "v2rayN, obsidian" })),
  ["v2rayN", "obsidian", "firefox", "kitty"])
check("a pin the store has never seen still gets a slot",
  names(rank(store, { slots: 3, pinned: "steam" })),
  ["steam", "firefox", "kitty"])
check("a pin with no desktop entry is still shown, because it was asked for",
  names(rank({}, { slots: 6, pinned: "weird-thing", describe: function() { return null } })),
  ["weird-thing"])
check("pins are flagged", rank(store, { slots: 3, pinned: "kitty" })[0].pinned, true)
check("pins outnumbering the slots are truncated",
  names(rank(store, { slots: 3, pinned: "a,b,c,d" })), ["a", "b", "c"])
check("case-insensitive pin does not duplicate its app",
  names(rank(store, { slots: 3, pinned: "FIREFOX" })),
  ["FIREFOX", "kitty", "foot"])
check("a pin nobody has launched lately still shows, with a zero count",
  rank({ steam: { launches: [ago(24 * 6)] } }, { slots: 3, pinned: "steam" })[0].count, 0)

console.log("Exclusions")
check("ignored apps never rank",
  names(rank(store, { ignored: "firefox, kitty" })),
  ["foot", "v2rayN", "obsidian"])
check("ignoring beats pinning", names(rank(store, { pinned: "firefox", ignored: "firefox" })),
  ["kitty", "foot", "v2rayN", "obsidian"])
check("an app with no desktop entry cannot earn a slot on its own",
  names(rank({ ghost: { launches: [ago(1)] } }, { describe: function() { return null } })), [])
var portal = { "xdg-desktop-portal-gtk": { launches: [ago(1), ago(2), ago(3)] } }
var hidden = function() { return { desktopId: "xdg-desktop-portal-gtk", name: "Portal", hidden: true } }
check("a NoDisplay entry cannot earn a slot", names(rank(portal, { describe: hidden })), [])
check("but it can still be pinned into one",
  names(rank(portal, { pinned: "xdg-desktop-portal-gtk", describe: hidden })), ["xdg-desktop-portal-gtk"])
check("a cached desktop id does not resurrect a hidden entry",
  names(rank({ "xdg-desktop-portal-gtk": { launches: [ago(1)], desktopId: "xdg-desktop-portal-gtk" } },
    { describe: function() { return { desktopId: "", name: "", hidden: true } } })), [])
check("entries with no launches at all do not rank",
  names(rank({ ghost: { launches: [] } })), [])
check("name and icon come from the live lookup",
  rank({ kitty: { launches: [ago(1)], name: "stale", icon: "stale" } },
    { describe: function() { return { desktopId: "kitty", name: "Kitty", icon: "kitty-icon" } } })[0].icon,
  "kitty-icon")
check("cached name survives an uninstalled desktop entry",
  rank({ kitty: { launches: [ago(1)], desktopId: "kitty", name: "Kitty" } },
    { describe: function() { return null } })[0].name,
  "Kitty")

console.log("The rolling three-day window")
check("a launch exactly three days old still counts",
  O.launchesWithin([NOW - O.WINDOW_SECONDS], NOW), 1)
check("a second older than that does not",
  O.launchesWithin([NOW - O.WINDOW_SECONDS - 1], NOW), 0)
check("counts only what is inside the window",
  O.launchesWithin([ago(1), ago(20), ago(71), ago(73), ago(200)], NOW), 3)

// The point of the whole change: the same store, ranked at two different
// moments, gives different answers with no launch in between.
var aging = {
  steady: { launches: [ago(1), ago(20), ago(40)] },        // spread over two days
  burst:  { launches: [ago(60), ago(61), ago(62), ago(63)] } // four, all ~2.5 days back
}
check("today, the heavier burst leads", names(rank(aging)), ["burst", "steady"])
check("thirteen hours later the burst has aged out entirely, with nothing else happening",
  names(rank(aging, { now: NOW + 13 * HOUR })), ["steady"])
check("three days on, nothing is left in the ring",
  names(rank(aging, { now: NOW + 3 * DAY })), [])
check("a count decays as its launches fall off the back",
  [rank(aging)[0].count,
   rank(aging, { now: NOW + 13 * HOUR })[0].count,
   rank(aging, { now: NOW + 35 * HOUR })[0].count],
  [4, 3, 2])

check("retention keeps a launch on disk after it stops counting",
  O.prunedLaunches([ago(80)], NOW), [ago(80)])
check("but not past four days", O.prunedLaunches([ago(24 * 4 + 1)], NOW), [])
var swept = O.pruneApps({
  live: { launches: [ago(1), ago(24 * 5)] },
  dead: { launches: [ago(24 * 6)] }
}, NOW)
check("a sweep drops expired launches", swept.apps.live.launches, [ago(1)])
check("a sweep drops apps left with nothing", Object.keys(swept.apps), ["live"])
check("a sweep that removed something says so", swept.changed, true)
check("a sweep with nothing to do says so, so it writes no file",
  O.pruneApps({ live: { launches: [ago(1)] } }, NOW).changed, false)
check("a sweep preserves metadata",
  O.pruneApps({ live: { launches: [ago(1)], desktopId: "live", name: "Live", icon: "l" } }, NOW).apps.live.desktopId,
  "live")

console.log("Cold start suggestions")
var shelf = ["gimp", "inkscape", "vlc", "krita", "blender", "audacity", "libreoffice"]
function suggest(id) { return { desktopId: id, name: id, icon: id, cls: id } }
function marks(entries) {
  return entries.map(function(e) { return e.cls + (e.pinned ? "#" : e.suggested ? "*" : "") })
}

check("an empty store still fills the ring",
  marks(rank({}, { suggestions: shelf, suggest: suggest })),
  ["gimp*", "inkscape*", "vlc*", "krita*", "blender*", "audacity*"])
check("suggestions are flagged and carry no count",
  [rank({}, { suggestions: shelf, suggest: suggest })[0].suggested,
   rank({}, { suggestions: shelf, suggest: suggest })[0].count],
  [true, 0])
check("real apps and pins come first, suggestions take what is left",
  marks(rank({ firefox: { launches: [ago(1), ago(2)] }, kitty: { launches: [ago(3)] } },
    { pinned: "obsidian", suggestions: shelf, suggest: suggest })),
  ["obsidian#", "firefox", "kitty", "gimp*", "inkscape*", "vlc*"])

// The shrink: one more real app each time, one fewer suggestion.
var growing = {}
var shrinking = []
var classes = ["firefox", "kitty", "code", "chromium", "obsidian", "mpv"]
for (var g = 0; g < classes.length; g++) {
  growing[classes[g]] = { launches: [ago(1 + g)] }
  shrinking.push(rank(growing, { suggestions: shelf, suggest: suggest })
    .filter(function(e) { return e.suggested }).length)
}
check("suggestions give way one by one as real usage grows", shrinking, [5, 4, 3, 2, 1, 0])
check("a full ring of real apps has no suggestions at all",
  marks(rank(growing, { suggestions: shelf, suggest: suggest })).join(" ").indexOf("*"), -1)

console.log("Suggestions never duplicate what is already there")
check("not an app already ranked by its window class",
  marks(rank({ gimp: { launches: [ago(1)] } }, { slots: 3, suggestions: shelf, suggest: suggest })),
  ["gimp", "inkscape*", "vlc*"])
check("not an app already pinned",
  marks(rank({}, { slots: 3, pinned: "vlc", suggestions: shelf, suggest: suggest })),
  ["vlc#", "gimp*", "inkscape*"])
check("not by desktop id either, when the window class differs",
  marks(rank({ Gimp: { launches: [ago(1)] } },
    { slots: 3,
      describe: function() { return { desktopId: "gimp", name: "GIMP", icon: "gimp" } },
      suggestions: shelf,
      suggest: suggest })),
  ["Gimp", "inkscape*", "vlc*"])
check("an ignored app is not suggested either",
  marks(rank({}, { slots: 3, ignored: "gimp, inkscape", suggestions: shelf, suggest: suggest })),
  ["vlc*", "krita*", "blender*"])
check("the same inputs give the same ring, every time",
  marks(rank({}, { suggestions: shelf, suggest: suggest })),
  marks(rank({}, { suggestions: shelf, suggest: suggest })))

console.log("Suggestions that no longer resolve")
check("an uninstalled pick is skipped and the next one takes the slot",
  marks(rank({}, { slots: 3, suggestions: shelf,
    suggest: function(id) { return id === "gimp" || id === "inkscape" ? null : suggest(id) } })),
  ["vlc*", "krita*", "blender*"])
check("nothing resolvable leaves a short ring rather than a broken one",
  rank({}, { suggestions: shelf, suggest: function() { return null } }).length, 0)
check("no suggest callback at all is simply the old behaviour",
  rank({}, { suggestions: shelf }).length, 0)
check("a resolved entry missing its id is refused",
  rank({}, { suggestions: ["x"], suggest: function() { return { name: "x", icon: "x" } } }).length, 0)
check("suggestions survive a store round trip",
  O.parseStore(O.serializeStore({}, ["gimp", "vlc"])).suggestions, ["gimp", "vlc"])

console.log("The reserve is capped by the format itself")
var overlong = []
for (var v = 0; v < 20; v++) overlong.push("app" + v)
check("parsing caps at the pool size", O.parseStore(JSON.stringify({ apps: {}, suggestions: overlong })).suggestions.length,
  O.SUGGESTION_POOL)
check("serializing caps too, so an over-long list cannot be written back",
  JSON.parse(O.serializeStore({}, overlong)).suggestions.length, O.SUGGESTION_POOL)
check("the cap keeps the front of the list, which is what the ring draws from",
  O.parseStore(JSON.stringify({ apps: {}, suggestions: overlong })).suggestions[0], "app0")
check("duplicates do not consume cap slots",
  O.parseStore(JSON.stringify({ apps: {}, suggestions: ["a", "a", "a", "b"] })).suggestions, ["a", "b"])

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
