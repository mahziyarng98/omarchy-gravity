# Changelog

## 1.3.0 — 2026-11-21

### Fixed

- **Avoid a reproducible panel-open crash on Qt 6.12.** The shared orbit's
  render-thread `RotationAnimator` crashed Qt's scene-graph batcher
  (`QSGBatchRenderer::prepareRenderPass`, SIGSEGV) on the first open after a
  shell restart. Use a GUI-thread `NumberAnimation` instead, retaining one
  shared transform and keeping the chips upright. Rotation starts only after
  the surface maps and respects Omarchy's animation setting.
- Removed the unnecessary shell-wide `appLibrary.refreshIcons()` call on
  panel open. Gravity already resolves icons from its own index and
  `Quickshell.iconPath`. Removing the rescan alone did not fix the crash;
  fresh-shell testing identified the shared render-thread animator instead.

### Changed

- **Lazy activation.** The bar widget no longer instantiates the panel at shell
  startup. The service stays dormant too: it reads the usage file once to check
  whether tracking was previously enabled, then creates no state directory,
  opens no Hyprland listener, starts no timers, and scans no icons until the
  first user-initiated open. That first open persists the opt-in, so tracking
  resumes on later shell starts.
- **Lighter motion.** The bar mark is static, and the six orbit icons share one
  rotation transform instead of recalculating six positions per frame. The
  usage file is watched only while the panel is open.
- **More robust suggestions.** Suggestion reconciliation moved into the pure
  `Orbit.reconcileSuggestions()` helper. A temporarily unavailable app library
  keeps the reserve; a ready but empty library clears stale picks.
- **Better icon coverage.** Added a plugin-bundled-icon fallback alongside
  the existing StartupWMClass matching and on-disk icon lookup.
- **OpenCode's real logo.** The plugin now bundles the official OpenCode dark
  square logo (`assets/icons/ai.opencode.png`, rasterized from the official
  brand SVG), so its slot no longer falls back to a letter tile when the
  AppImage has not installed an icon in the theme.

### Verification

- `node test/orbit-test.js` passes all 148 checks, including source-contract
  guardrails for the shared animation. These are not a runtime render test.
- `qmlformat Panel.qml` parses cleanly.
- Nine open/close cycles across three fresh shell processes produced no new
  Quickshell coredumps on Qt 6.12 / Quickshell 0.3.2. Check the first open after
  a full shell restart: rescanning plugins alone can retain cached components.
- Visually verified upright chips and the OpenCode logo in the live panel.

Earlier releases are listed on the
[GitHub releases page](https://github.com/mahziyarng98/omarchy-gravity/releases).
