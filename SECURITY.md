# Security Policy

## Supported versions

Only the latest release gets security fixes.

| Version | Supported |
|---|---|
| 1.2.x (latest) | ✅ |
| < 1.2 | ❌ |

## Reporting a vulnerability

Please report vulnerabilities privately, not in a public issue:

1. Open the **Security** tab of this repository and click **Report a vulnerability** (GitHub private vulnerability reporting).
2. Include the affected version, steps to reproduce, the impact, and a proof of concept if you have one.

This project is maintained by one person. I will acknowledge your report and work on a fix as soon as I can, but I can't promise a fixed response time. Unless you'd rather stay anonymous, you'll be credited in the release notes.

## Scope

- **In scope:** the plugin code in this repository, including how it stores app-launch history.
- **What the plugin runs and reads:** after the user first opens Gravity, it creates the state directory, listens to Hyprland's `openwindow` stream, and uses `hyprctl clients -j`, `hyprctl dispatch focuswindow`, and `uwsm-app -- gtk-launch` as needed. It also runs a read-only `find` (no shell) to list icon file names, not contents, under `~/.local/share/icons`, `/usr/share/icons`, `/usr/share/pixmaps`, `/opt` and `/usr/share`; the output stays in memory. Before first use, only the small usage state file is read to check whether tracking was previously enabled. It makes no network connections, uses no `sudo`, and writes only to `~/.local/state/omarchy/gravity/`.
- **Out of scope:** bugs in Omarchy, Quickshell, or Hyprland. Please report those to their own projects.
