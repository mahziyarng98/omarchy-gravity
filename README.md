# Gravity

An [Omarchy](https://omarchy.org/) shell plugin: an orbital launcher that
surfaces the apps you actually use. Six icons on one turning ring, centred on
the screen, ranked by how often you open them — not by a favourites list you
have to maintain.

![The Gravity orbit: six apps on a ring around a hub naming the app under the cursor](preview.png)

> [!IMPORTANT]
> **Gravity is an Omarchy plugin, not a standalone Quickshell widget.** It is
> loaded by `omarchy-shell`'s plugin loader, registers its IPC through it,
> imports the shell's `qs.Commons` / `qs.Ui` modules for layout and controls,
> and takes every colour from Omarchy's theme engine. It will **not** run on
> vanilla Hyprland + Quickshell without significant rework — see
> [Requirements](#requirements) for exactly what it leans on.

<!-- Still worth adding: orbit.gif — the staggered burst on open, then the
     rotation pausing as the cursor lands on an icon. A still cannot show it. -->

## What makes it different

Gravity counts **every** window that opens on your desktop, not just the ones
launched from its own panel. It listens to Hyprland's event socket for the
whole session, so opening v2rayN from a keybinding, a terminal, an autostart
or a link handler all count the same. If v2rayN is the first thing you reach
for after a boot, it climbs into the ring on its own, and nobody had to
configure anything.

## Features

- **Learned ranking.** The orbit is the top of your launch counts, live. A new
  habit shows up in the ring within a few launches; an abandoned one falls out.
- **System-wide tracking.** Counts come from Hyprland's `openwindow` stream, so
  they reflect how you use the machine, not how you use this widget.
- **Launch or focus.** Clicking an app focuses its window if one exists, and
  launches it if not. The window it focuses is deterministic — always the first
  one Hyprland lists for that class — so the same click lands in the same place
  every time, rather than cycling.
- **Pinning.** Apps you always want within reach hold their slot regardless of
  count, in the order you list them, with the ranking filling what is left.
- **A fixed ring, not a list.** At most six apps, always on one circle, always
  in the same places — so a slot becomes a position you can aim at from muscle
  memory rather than a row you have to read.
- **Icons burst out from the centre**, one after another with a beat between
  them, and collapse back the same way on close.
- **Keyboard driven.** Arrows, Tab, or `1`–`6` select; Enter activates; Esc
  closes. Focus is grabbed as the panel opens, so the keyboard works
  immediately.
- **Rotation that pauses when you aim.** The ring turns slowly and stops the
  moment an icon is hovered or selected, so you are never chasing a target.
- **Theme-adaptive.** Every colour comes from the active Omarchy theme, so the
  orbit re-skins on `omarchy theme set` with nothing to configure.

## Requirements

- **Omarchy 4 ("Quattro") or newer** — the Quickshell-based `omarchy-shell`.
- **Hyprland**, for the event socket the usage tracker reads and the
  `hyprctl` calls that focus a window.

Built and tested on Omarchy 4.0.2 (Quickshell 0.3.1, Qt 6.11). No network
access, no external fonts, no third-party dependencies.

### Why it is Omarchy-only

Four separate pieces of `omarchy-shell` hold this plugin up. None of them
exist in a bare Quickshell config:

| It uses | For |
|---|---|
| the plugin loader + `manifest.json` contract | mounting the bar widget once per monitor and the usage service once per session |
| the shell's IPC host | the `gravity` and `gravity-usage` targets that `omarchy-shell` forwards to |
| `qs.Commons` / `qs.Ui` | `Panel`, `BarWidget`, `BarIconButton`, `PanelKeyCatcher`, `Style`, `Color`, `Util` |
| the theme engine | every colour, read from the active theme's `colors.toml` and `shell.toml` |

Porting it to vanilla Hyprland + Quickshell means replacing all four: a host
that loads the QML, an IPC surface, the ~dozen UI components it imports, and a
palette. The logic that is genuinely portable is deliberately isolated in
`Orbit.js`, which is Qt-free.

## Install

```bash
omarchy plugin add https://github.com/mahziyarng98/omarchy-gravity.git --enable
```

Plugins land disabled by default so you can read the code first; `--enable`
skips that and puts the widget into the bar's left section. Move it with:

```bash
omarchy bar move io.github.mahziyarng98.gravity --section right
```

## Update

```bash
omarchy plugin update io.github.mahziyarng98.gravity
```

## Usage

Click the turning mark in the bar, or press the shortcut. The panel opens
centred on the screen and the icons burst out from the middle one after
another. Click an app to launch or focus it; click anywhere else, or press
Esc, to dismiss.

### The keyboard shortcut

Gravity ships no binding of its own — Omarchy owns your keymap. Add one line:

```lua
-- ~/.config/hypr/bindings.lua
o.bind("SUPER + CTRL + G", "Gravity", "omarchy-shell gravity toggle")
```

`SUPER + CTRL + G` is the suggested default: `SUPER + CTRL` is the row Omarchy
already uses for shell panels (`A` audio, `B` bluetooth, `D` display, `W`
network, `P` power), and `G` is free in it on a stock install. Check before
you commit to it, since your own bindings may differ:

```bash
omarchy menu keybindings --print | grep -iE "\+ G( |$)"
```

To use a different combination, change the keys in that same line — the
command never changes. If the one you want is already spoken for, unbind it
first:

```lua
hl.unbind("SUPER + SHIFT + SPACE")   -- stock: toggle the top bar
o.bind("SUPER + SHIFT + SPACE", "Gravity", "omarchy-shell gravity toggle")
```

Reload with `hyprctl reload`; no shell restart is needed.

### Inside the panel

The panel takes keyboard focus when it opens.

| Key | Action |
|---|---|
| `→` `↓` / `l` `j` / `Tab` | select the next app, clockwise |
| `←` `↑` / `h` `k` / `Shift-Tab` | select the previous app |
| `1`–`6` | activate that slot directly |
| `Enter` / `Space` | launch or focus the selected app |
| `Esc` | close without selecting |

Selecting with the keyboard stops the rotation and highlights the icon exactly
as hovering does, so what is selected is never ambiguous.

### IPC

For a keybinding, a script, or just to check that the plugin is live:

```bash
omarchy-shell gravity toggle    # what the keybinding runs
omarchy-shell gravity open
omarchy-shell gravity close
```

The IPC target is `gravity` — deliberately shorter than the plugin id, so a
keybinding stays readable. The usage store has a second target of its own,
`gravity-usage`; see [The usage store](#the-usage-store).

## Configuration

Settings live inline on the widget's entry in `~/.config/omarchy/shell.json`
and hot-reload on save:

```json
{
  "id": "io.github.mahziyarng98.gravity",
  "pinned": "v2rayN, org.gnome.Nautilus",
  "ignored": "xdg-desktop-portal-gtk",
  "slots": 6,
  "orbitSeconds": 45
}
```

| Key | Default | Effect |
|---|---|---|
| `pinned` | `""` | window classes that always hold a slot, in orbit order |
| `ignored` | `""` | window classes that never earn a slot, however often they open |
| `slots` | `6` | how many icons sit on the ring (3–6; six is the maximum the circle holds) |
| `orbitSeconds` | `45` | seconds per revolution |

Both lists are comma-separated **window classes**, not app names. To read the
class of a running window:

```bash
hyprctl clients -j | jq -r '.[].class' | sort -u
```

A pinned app is shown even if it has never been launched and even if it has no
`.desktop` entry — you asked for it by name. An app that is neither pinned nor
resolvable to a `.desktop` entry never takes a slot, because there would be
nothing to launch when you clicked it. Neither do entries the desktop marks
`NoDisplay` — portal dialogs, agents, MIME shims — which open real windows but
are not things anyone launches. Pinning overrides that too.

## How the ranking works

One counter per window class, incremented once per top-level window created.
Ties break on which was launched most recently. Pinned apps are placed first,
in configured order; the ranking fills the remaining slots.

Focusing an existing window does **not** count — no window was created — so
using Gravity to switch to an app you already have open never inflates its
position.

## The usage store

```
~/.local/state/omarchy/gravity/usage.json
```

Same convention as Omarchy's other stateful plugins: mutable per-machine state
lives under the XDG state directory, never in the config tree. It is plain
JSON, written by the plugin's background service and safe to read, edit, or
delete — a missing or corrupt file costs you the ranking, and using the machine
rebuilds it.

```json
{
  "version": 1,
  "apps": {
    "v2rayN": { "count": 37, "last": 1788618278, "desktopId": "v2rayn", "name": "v2rayN", "icon": "v2rayn" }
  }
}
```

A maintenance IPC target sits on top of it:

```bash
omarchy-shell gravity-usage list             # the ranking, most launched first
omarchy-shell gravity-usage forget chromium  # drop one app
omarchy-shell gravity-usage reset            # start over
omarchy-shell gravity-usage record v2rayN    # count a launch by hand
omarchy-shell gravity-usage path             # where the store lives
```

`record` exists so you can test the ranking without waiting for real usage to
accumulate.

## Architecture

| File | Role |
|---|---|
| `manifest.json` | plugin manifest: one `bar-widget` kind and one `service` kind |
| `BarWidget.qml` | the bar mark, the `gravity` IPC target, and the panel host |
| `Panel.qml` | the orbit: a full-screen layer-shell surface, centred |
| `Service.qml` | the Hyprland event listener and the only writer of the store |
| `OrbitGlyph.qml` | the turning mark, shared by the bar icon and the panel's hub |
| `Orbit.js` | the store format, the ranking, the geometry, the output parsing |

The counter lives in a `service` plugin rather than in the bar widget on
purpose: the shell mounts a service once per session, while a bar widget exists
once per monitor. Counting in the widget would double every launch on a
two-screen setup. One writer, any number of readers — the panel watches the
file.

## Development

The logic that can be tested without a compositor is in `Orbit.js`, which is
Qt-free and runs under node:

```bash
node test/orbit-test.js
```

To hack on the QML, put the plugin in
`~/.config/omarchy/plugins/io.github.mahziyarng98.gravity/`. A real directory
there is watched, and saving a file reloads the plugin on its own.

A **symlink** to a checkout elsewhere is the more comfortable setup, but the
shell's watcher does not follow it, and `omarchy-shell shell rescanPlugins`
does not pick up edited QML through one either (measured, not assumed: a
changed string only took effect after a restart). So with a symlinked
checkout, reload with:

```bash
omarchy-restart-shell
```

Shell logs, including QML warnings, land in the session journal:

```bash
journalctl --user -f _PID=$(pgrep -f 'quickshell -n -p /usr/share/omarchy/shell')
```

## License

MIT. See [LICENSE](LICENSE).
