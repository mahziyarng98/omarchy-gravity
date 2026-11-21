# Changelog

## 1.3.0 — 2026-11-21

### Fixed

- **Opening the panel no longer crashes Quickshell on Qt 6.12.** The panel used
  to call the shell-wide `appLibrary.refreshIcons()` while its layer surface
  mapped, which crashed Qt's scene-graph batcher
  (`QSGBatchRenderer::prepareRenderPass`, SIGSEGV on the render thread). Gravity
  resolves icons from its own index and `Quickshell.iconPath`, so the
  shell-wide rescan was not needed and has been removed.

### Changed

- **Lazy activation.** The bar widget no longer instantiates the panel at shell
  startup. The service stays dormant too: it reads the usage file once to check
  whether tracking was previously enabled, then creates no state directory,
  opens no Hyprland listener, starts no timers, and scans no icons until the
  first user-initiated open. That first open persists the opt-in, so tracking
  resumes on later shell starts.
- **Lighter motion.** The bar mark is static, and the six orbit icons share one
  render-thread rotation transform instead of recalculating six positions per
  frame. The usage file is watched only while the panel is open.
- **More robust suggestions.** Suggestion reconciliation moved into the pure
  `Orbit.reconcileSuggestions()` helper. A temporarily unavailable app library
  keeps the reserve; a ready but empty library clears stale picks.
- **Better icon coverage.** Added a StartupWMClass to icon bridge and a
  plugin-bundled-icon fallback.
- **OpenCode's real logo.** The plugin now bundles the official OpenCode dark
  square logo (`assets/icons/ai.opencode.png`, rasterized from the official
  brand SVG), so its slot no longer falls back to a letter tile when the
  AppImage has not installed an icon in the theme.

### Verification

- `node test/orbit-test.js` passes.
- `qmlformat Panel.qml` parses cleanly.
- Three consecutive panel opens produced no new Quickshell coredumps on
  Qt 6.12 / Quickshell 0.3.2.

Earlier releases are listed on the
[GitHub releases page](https://github.com/mahziyarng98/omarchy-gravity/releases).
