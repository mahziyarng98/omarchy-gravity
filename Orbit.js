// Gravity's pure logic: the shape of the usage store, the ranking that decides
// which apps make the orbit, the geometry the panel draws with, and the two
// pieces of Hyprland output parsing (the `openwindow` event line and
// `hyprctl clients -j`).
//
// Deliberately Qt-free and side-effect-free so the same file runs under node
// for testing (test/orbit-test.js) and inside QML unchanged. Nothing here
// reads a file, spawns a process, or touches a QML object -- the callers own
// all of that, and hand in what they know through `options`.

var STORE_VERSION = 1

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

function sanitizeRecord(raw) {
  var record = raw && typeof raw === "object" ? raw : {}
  var count = Number(record.count)
  var last = Number(record.last)
  return {
    count: isFinite(count) && count > 0 ? Math.floor(count) : 0,
    last: isFinite(last) && last > 0 ? Math.floor(last) : 0,
    desktopId: String(record.desktopId || ""),
    name: String(record.name || ""),
    icon: String(record.icon || "")
  }
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

// One launch of `cls`. Returns a new apps object rather than mutating, so a
// QML property assignment sees a change and re-evaluates its bindings.
// `meta` carries whatever the caller managed to resolve about the app
// (desktop id, display name, icon name); it is merged in but never used to
// erase a value we already had.
function recordLaunch(apps, cls, nowSeconds, meta) {
  var name = normalizeClass(cls)
  var next = {}
  for (var key in apps) next[key] = apps[key]
  if (!name) return next

  var existingKey = findKey(next, name) || name
  var record = sanitizeRecord(next[existingKey])
  var extra = meta && typeof meta === "object" ? meta : {}
  var stamp = Number(nowSeconds)

  next[existingKey] = {
    count: record.count + 1,
    last: isFinite(stamp) && stamp > 0 ? Math.floor(stamp) : record.last,
    desktopId: String(extra.desktopId || record.desktopId || ""),
    name: String(extra.name || record.name || ""),
    icon: String(extra.icon || record.icon || "")
  }
  return next
}

// Fold a store read off disk into counters already collected in memory. The
// service starts counting the moment the shell has a Hyprland connection,
// which can be before the file has finished loading; adding the two is the
// only merge that loses nothing.
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
    out[target] = {
      count: current.count + record.count,
      last: Math.max(current.last, record.last),
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

function entryFor(apps, cls, describe, pinned) {
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
    count: record.count,
    last: record.last,
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
function rankApps(apps, options) {
  var opts = options || {}
  var slots = clampSlots(opts.slots)
  var ignored = indexList(opts.ignored)
  var pinned = parseList(opts.pinned)
  var taken = {}
  var out = []
  var i

  for (i = 0; i < pinned.length && out.length < slots; i++) {
    var key = classKey(pinned[i])
    if (taken[key] || ignored[key]) continue
    taken[key] = true
    out.push(entryFor(apps, pinned[i], opts.describe, true))
  }

  var auto = []
  for (var cls in apps) {
    var k = classKey(cls)
    if (!k || taken[k] || ignored[k]) continue
    var entry = entryFor(apps, cls, opts.describe, false)
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
    normalizeClass: normalizeClass, classKey: classKey, parseList: parseList,
    emptyStore: emptyStore, parseStore: parseStore, serializeStore: serializeStore,
    findKey: findKey, recordLaunch: recordLaunch, mergeApps: mergeApps,
    clampSlots: clampSlots, rankApps: rankApps,
    angleFor: angleFor, pointOn: pointOn,
    classFromOpenWindow: classFromOpenWindow, pickWindowAddress: pickWindowAddress,
    parseClients: parseClients
  }
}
