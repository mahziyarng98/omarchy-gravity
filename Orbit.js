// Gravity's pure logic: the shape of the usage store, the ranking that decides
// which apps make the orbit, the geometry the panel draws with, and the two
// pieces of Hyprland output parsing (the `openwindow` event line and
// `hyprctl clients -j`).
//
// Deliberately Qt-free and side-effect-free so the same file runs under node
// for testing (test/orbit-test.js) and inside QML unchanged. Nothing here
// reads a file, spawns a process, or touches a QML object -- the callers own
// all of that, and hand in what they know through `options`.

var STORE_VERSION = 2

// The ranking is a rolling window, not a lifetime tally: what the orbit shows
// is what you have actually been reaching for lately. A launch counts for
// three days and then stops counting, whether or not anything new happens --
// so an app you hammered last week falls out on its own.
var WINDOW_SECONDS = 3 * 24 * 60 * 60      // 72h: what counts toward a rank

// Kept on disk a day longer than it counts. The extra day is slack for a
// clock that steps backwards (NTP correction, a timezone-confused RTC after a
// reboot) so a small negative jump cannot silently erase history that is still
// inside the window.
var RETENTION_SECONDS = 4 * 24 * 60 * 60

// The circle holds six comfortably. More than that and the icons crowd each
// other at any radius that still fits a 1080p screen, which is the whole
// reason the orbit is a fixed ring rather than a grid.
var MAX_SLOTS = 6
var MIN_SLOTS = 3

// ---------------------------------------------------------------- classes

function normalizeClass(value) {
  return String(value === undefined || value === null ? "" : value).trim()
}

// Hyprland is not consistent about the case of a window class between an
// `openwindow` event and `hyprctl clients` (Chromium apps in particular), so
// every comparison in this file goes through the folded key while the stored
// key keeps the casing we first saw, which is what the user recognises.
function classKey(value) {
  return normalizeClass(value).toLowerCase()
}

// Config lists are written by hand in shell.json, so accept the three
// separators someone might reach for and drop the empties.
function parseList(value) {
  if (Array.isArray(value)) {
    var fromArray = []
    for (var i = 0; i < value.length; i++) {
      var item = normalizeClass(value[i])
      if (item) fromArray.push(item)
    }
    return fromArray
  }
  var parts = String(value === undefined || value === null ? "" : value).split(/[,\n;]+/)
  var out = []
  for (var j = 0; j < parts.length; j++) {
    var part = parts[j].trim()
    if (part) out.push(part)
  }
  return out
}

function indexList(values) {
  var index = {}
  var list = parseList(values)
  for (var i = 0; i < list.length; i++) index[classKey(list[i])] = true
  return index
}

// ------------------------------------------------------------- the store

function emptyStore() {
  return { version: STORE_VERSION, apps: {} }
}

// A record is the launch times themselves, ascending, plus whatever we know
// about the app. Version 1 stored a single lifetime integer instead; such a
// record parses to an empty launch list, which is the migration -- the old
// total cannot be spread back over a window it never described, and a few
// days of use rebuilds a truthful one.
function sanitizeRecord(raw) {
  var record = raw && typeof raw === "object" ? raw : {}
  var launches = []
  if (Array.isArray(record.launches)) {
    for (var i = 0; i < record.launches.length; i++) {
      var stamp = Math.floor(Number(record.launches[i]))
      if (isFinite(stamp) && stamp > 0) launches.push(stamp)
    }
    launches.sort(function(a, b) { return a - b })
  }
  return {
    launches: launches,
    desktopId: String(record.desktopId || ""),
    name: String(record.name || ""),
    icon: String(record.icon || "")
  }
}

// How many of these launches still count, as of `now`. A launch exactly at
// the edge counts: three days old is not yet older than three days.
function launchesWithin(launches, now, windowSeconds) {
  var cutoff = Number(now) - (windowSeconds === undefined ? WINDOW_SECONDS : Number(windowSeconds))
  var total = 0
  for (var i = 0; i < launches.length; i++) if (launches[i] >= cutoff) total++
  return total
}

function lastLaunchOf(launches) {
  return launches.length ? launches[launches.length - 1] : 0
}

function prunedLaunches(launches, now) {
  var cutoff = Number(now) - RETENTION_SECONDS
  var kept = []
  for (var i = 0; i < launches.length; i++) if (launches[i] >= cutoff) kept.push(launches[i])
  return kept
}

// Drop everything past the retention horizon, and drop apps left with nothing.
// Returns `changed` so a periodic sweep only writes the file when the sweep
// actually removed something.
function pruneApps(apps, now) {
  var out = {}
  var changed = false
  for (var key in apps) {
    var record = sanitizeRecord(apps[key])
    var kept = prunedLaunches(record.launches, now)
    if (kept.length !== record.launches.length) changed = true
    if (kept.length === 0) { changed = true; continue }
    out[key] = {
      launches: kept,
      desktopId: record.desktopId,
      name: record.name,
      icon: record.icon
    }
  }
  return { apps: out, changed: changed }
}

// Tolerant on purpose: a truncated or hand-edited usage.json costs the user
// their ranking, and that is recoverable by using the machine. Refusing to
// start because of it would not be.
function parseStore(raw) {
  var store = emptyStore()
  var text = String(raw === undefined || raw === null ? "" : raw).trim()
  if (!text) return store
  var parsed = null
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return store
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return store
  var apps = parsed.apps && typeof parsed.apps === "object" ? parsed.apps : {}
  for (var cls in apps) {
    var key = normalizeClass(cls)
    if (!key) continue
    store.apps[key] = sanitizeRecord(apps[cls])
  }
  return store
}

function serializeStore(apps) {
  return JSON.stringify({ version: STORE_VERSION, apps: apps || {} }, null, 2) + "\n"
}

// The stored key for a class, matched case-insensitively so "Chromium" and
// "chromium" stay one app. Returns "" when nothing matches yet.
function findKey(apps, cls) {
  var wanted = classKey(cls)
  if (!wanted) return ""
  if (apps && apps[normalizeClass(cls)]) return normalizeClass(cls)
  for (var key in apps) {
    if (classKey(key) === wanted) return key
  }
  return ""
}

function lookup(apps, cls) {
  var key = findKey(apps, cls)
  return key ? apps[key] : null
}

// One launch of `cls`, at `nowSeconds`. Returns a new apps object rather than
// mutating, so a QML property assignment sees a change and re-evaluates its
// bindings. `meta` carries whatever the caller managed to resolve about the
// app (desktop id, display name, icon name); it is merged in but never used to
// erase a value we already had.
//
// Pruning happens here as well as on the sweep, so the file cannot grow
// without bound between sweeps no matter how much the machine is used.
function recordLaunch(apps, cls, nowSeconds, meta) {
  var name = normalizeClass(cls)
  var next = {}
  for (var key in apps) next[key] = apps[key]
  if (!name) return next

  var existingKey = findKey(next, name) || name
  var record = sanitizeRecord(next[existingKey])
  var extra = meta && typeof meta === "object" ? meta : {}

  var stamp = Math.floor(Number(nowSeconds))
  if (!isFinite(stamp) || stamp <= 0) stamp = 0

  var launches = record.launches.slice()
  if (stamp > 0) launches.push(stamp)
  launches.sort(function(a, b) { return a - b })

  next[existingKey] = {
    launches: prunedLaunches(launches, stamp > 0 ? stamp : lastLaunchOf(launches)),
    desktopId: String(extra.desktopId || record.desktopId || ""),
    name: String(extra.name || record.name || ""),
    icon: String(extra.icon || record.icon || "")
  }
  return next
}

// Fold a store read off disk into launches already collected in memory. The
// service starts counting the moment the shell has a Hyprland connection,
// which can be before the file has finished loading, so the two sets are
// disjoint in time and concatenating them loses nothing. Identical timestamps
// are kept, not deduplicated: two windows of one app really can open in the
// same second, and that is two launches.
function mergeApps(base, incoming) {
  var out = {}
  var key
  for (key in base) out[key] = sanitizeRecord(base[key])
  for (key in incoming) {
    var target = findKey(out, key)
    var record = sanitizeRecord(incoming[key])
    if (!target) {
      out[key] = record
      continue
    }
    var current = out[target]
    var launches = current.launches.concat(record.launches)
    launches.sort(function(a, b) { return a - b })
    out[target] = {
      launches: launches,
      desktopId: current.desktopId || record.desktopId,
      name: current.name || record.name,
      icon: current.icon || record.icon
    }
  }
  return out
}

// ------------------------------------------------------------- the orbit

function clampSlots(value) {
  var n = Math.floor(Number(value))
  if (!isFinite(n)) return MAX_SLOTS
  return Math.max(MIN_SLOTS, Math.min(MAX_SLOTS, n))
}

function entryFor(apps, cls, describe, pinned, now) {
  var record = sanitizeRecord(lookup(apps, cls))
  var described = null
  try {
    described = typeof describe === "function" ? describe(cls) : null
  } catch (e) {
    described = null
  }
  var desktopId = String((described && described.desktopId) || record.desktopId || "")
  return {
    cls: normalizeClass(cls),
    // `count` is the windowed count -- launches in the last three days -- and
    // it is what the ranking, the hub readout and the tests all mean by it.
    count: launchesWithin(record.launches, now),
    // Ties break on the most recent launch. Any app with a non-zero windowed
    // count has its last launch inside the window too, so this never lets a
    // stale app win a tie against a current one.
    last: lastLaunchOf(record.launches),
    desktopId: desktopId,
    name: String((described && described.name) || record.name || normalizeClass(cls)),
    icon: String((described && described.icon) || record.icon || ""),
    pinned: pinned === true,
    // A class with no desktop entry on either side can still be focused if a
    // window of it exists, but it can never be launched -- so it is only
    // worth a slot when the user asked for it by name. `hidden` is the same
    // verdict arrived at from the other direction: an entry the desktop
    // itself marks NoDisplay is not something anyone launches.
    launchable: desktopId !== "" && !(described && described.hidden === true)
  }
}

function compareEntries(a, b) {
  if (b.count !== a.count) return b.count - a.count
  if (b.last !== a.last) return b.last - a.last
  var an = a.name.toLowerCase(), bn = b.name.toLowerCase()
  if (an !== bn) return an < bn ? -1 : 1
  return a.cls < b.cls ? -1 : (a.cls > b.cls ? 1 : 0)
}

// Who gets a slot: pinned apps first, in the order they were configured,
// then the most-launched apps that are not pinned or ignored, ranked by
// count and broken by recency. `describe(cls)` is the caller's window
// class -> desktop entry lookup and may return null.
//
// `options.now` (epoch seconds) is the instant the window is measured from.
// Callers pass it so the answer is a pure function of its inputs -- and so
// that re-ranking on a timer, with nothing else changed, still drops apps
// whose launches have aged out.
function rankApps(apps, options) {
  var opts = options || {}
  var slots = clampSlots(opts.slots)
  var ignored = indexList(opts.ignored)
  var pinned = parseList(opts.pinned)
  var now = Math.floor(Number(opts.now))
  if (!isFinite(now) || now <= 0) now = Math.floor(Date.now() / 1000)
  var taken = {}
  var out = []
  var i

  for (i = 0; i < pinned.length && out.length < slots; i++) {
    var key = classKey(pinned[i])
    if (taken[key] || ignored[key]) continue
    taken[key] = true
    out.push(entryFor(apps, pinned[i], opts.describe, true, now))
  }

  var auto = []
  for (var cls in apps) {
    var k = classKey(cls)
    if (!k || taken[k] || ignored[k]) continue
    var entry = entryFor(apps, cls, opts.describe, false, now)
    // A zero windowed count is the whole mechanism: nothing launched in the
    // last three days has any claim on a slot.
    if (!entry.launchable || entry.count <= 0) continue
    auto.push(entry)
  }
  auto.sort(compareEntries)

  for (i = 0; i < auto.length && out.length < slots; i++) out.push(auto[i])
  return out
}

// Where a slot sits on the ring. Index 0 is at twelve o'clock and the rest
// run clockwise, so the numbering the panel prints on each icon matches the
// order the eye reads them in.
function angleFor(index, count, rotationDegrees) {
  var n = Math.max(1, Math.floor(Number(count) || 1))
  var i = Math.floor(Number(index) || 0)
  return -90 + (Number(rotationDegrees) || 0) + (i % n) * (360 / n)
}

function pointOn(centerX, centerY, radius, angleDegrees) {
  var radians = (Number(angleDegrees) || 0) * Math.PI / 180
  return {
    x: centerX + radius * Math.cos(radians),
    y: centerY + radius * Math.sin(radians)
  }
}

// ------------------------------------------------- Hyprland output parsing

// `openwindow` carries "address,workspacename,class,title". The title is the
// only field that reliably contains commas, so the class is everything
// between the second and third one.
function classFromOpenWindow(data) {
  var text = String(data === undefined || data === null ? "" : data)
  var first = text.indexOf(",")
  if (first < 0) return ""
  var second = text.indexOf(",", first + 1)
  if (second < 0) return ""
  var third = text.indexOf(",", second + 1)
  return normalizeClass(third < 0 ? text.slice(second + 1) : text.slice(second + 1, third))
}

// The window a click should focus: the first entry `hyprctl clients -j`
// reports for that class. Deliberately not the most recently focused one and
// deliberately not a cycle -- clicking an app in the orbit twice has to land
// on the same window both times, or the orbit stops being a place.
function pickWindowAddress(clients, cls) {
  var wanted = classKey(cls)
  if (!wanted || !Array.isArray(clients)) return ""
  for (var i = 0; i < clients.length; i++) {
    var client = clients[i]
    if (!client || typeof client !== "object") continue
    var address = String(client.address || "")
    if (!address) continue
    if (classKey(client.class) === wanted || classKey(client.initialClass) === wanted) return address
  }
  return ""
}

function parseClients(raw) {
  try {
    var parsed = JSON.parse(String(raw || "[]"))
    return Array.isArray(parsed) ? parsed : []
  } catch (e) {
    return []
  }
}

// node-only export; harmless inside QML, which ignores the guard.
if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    STORE_VERSION: STORE_VERSION, MAX_SLOTS: MAX_SLOTS, MIN_SLOTS: MIN_SLOTS,
    WINDOW_SECONDS: WINDOW_SECONDS, RETENTION_SECONDS: RETENTION_SECONDS,
    normalizeClass: normalizeClass, classKey: classKey, parseList: parseList,
    emptyStore: emptyStore, parseStore: parseStore, serializeStore: serializeStore,
    launchesWithin: launchesWithin, lastLaunchOf: lastLaunchOf,
    prunedLaunches: prunedLaunches, pruneApps: pruneApps,
    findKey: findKey, recordLaunch: recordLaunch, mergeApps: mergeApps,
    clampSlots: clampSlots, rankApps: rankApps,
    angleFor: angleFor, pointOn: pointOn,
    classFromOpenWindow: classFromOpenWindow, pickWindowAddress: pickWindowAddress,
    parseClients: parseClients
  }
}
