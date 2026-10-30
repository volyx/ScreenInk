# ScreenInk — plan

## 1. Product scope
A menu-bar app for drawing over the screen live during presentations, demos and screen recordings.

**v1 includes:** an overlay on every display, a pressure-sensitive pen, highlighter, line, arrow, rectangle, ellipse, text and numbered badges, an eraser, selection, undo/redo, ghost (click-through) mode, spotlight, magnifier, freeze screen, whiteboard, cursor halo and click highlights, snapshots, and PNG/PDF export.

**Out of scope:** remote control, meaning no companion phone app, no UDP/Bonjour listener, no air-mouse pointing and no Keynote/PowerPoint slide control. Also out: the Mac App Store, Intel Macs, the Touch Bar and localization in v1.

**Backlog (after v1):** timers/countdown, lower-third titles, scissors (cut a region), layer grouping, a circle menu, split whiteboard layouts (halves/quarters), layered PSD export, rainbow (hue-cycling) brush, click/keyboard sounds, and import/export of shortcut presets.

## 2. Decisions
| Topic | Decision | Why |
|---|---|---|
| Platform | macOS 14+, **arm64 only** (`ARCHS = arm64`, `LSMinimumSystemVersion = 14.0`) | User requirement. macOS 14 gives `NSView.displayLink`, `SMAppService`, a mature ScreenCaptureKit and `CGPath` boolean ops. |
| Language/UI | Swift 6 (strict concurrency), AppKit for the overlay, palette and gallery, SwiftUI only inside the Settings window | The overlay needs precise window and event control, which SwiftUI can't provide. |
| Distribution | Developer ID + notarization, **not sandboxed**, Sparkle 2 for updates | Event taps and the screen-capture prompts are much simpler outside the sandbox. |
| Entitlements | Hardened runtime only, with no network-server or Apple Events entitlements | Remote control and slide control are out of scope. Sparkle only needs outbound network, which isn't sandboxed. |
| Global hotkeys | Carbon `RegisterEventHotKey` via a small wrapper (`HotKey.swift`) | Needs no permission. The recorder UI comes with Settings (Phase 6). |
| Mouse side buttons | An active `CGEventTap` (`MouseButtonTap.swift`) for `otherMouseDown`/`otherMouseUp` only, off until enabled in the menu | A global `NSEvent` monitor needs no permission but can't stop the press reaching the app below, so a browser would navigate away as drawing starts. Blocking needs Accessibility. |
| Live stroke rendering | An offscreen bitmap cache per screen, at the screen's backing scale, used as the contents of a `CALayer` and invalidated by dirty rect: each new segment is stroked into the cache and only its bounds are redrawn | The cost per update is constant regardless of stroke length, whereas a growing `CAShapeLayer` path redraws the whole path every frame. |
| Committed annotations | One `CALayer` per annotation, rebuilt from the vector model | Selection, recolor, eraser-by-type, z-order and vector PDF export all need objects, not pixels. |
| Smoothing | A 5-point midpoint cubic Bézier (when an FPS cap drops samples, the ones at 25/50/75% are re-inserted), plus an exponential moving average (EMA) over pressure (α≈0.3), kept separate from position | Consecutive segments share a tangent at their joint, so strokes have no corners and need no extra filter stage. |
| Screen capture | ScreenCaptureKit, excluding our own app via `SCContentFilter` | `CGDisplayCreateImage` and `CGWindowListCreateImage` are deprecated or blocked. |
| Persistence | Plain files in `~/Library/Application Support/<app>/Snapshots/<uuid>/` containing `annotations.json`, `background.png` and `thumb.png` | Easy to inspect, diff and migrate. No Core Data or SwiftData. |
| Settings | `~/.ScreenInk/config.yml`, read through a small built-in YAML subset (`SimpleYAML`) and watched for edits | Editable by hand, easy to copy between Macs. No dependency. Unsupported syntax, unknown options and bad values are errors with a line number, and a bad file is never overwritten. Launch at login isn't included, because macOS owns that state. |

## 3. Architecture
```
App/        AppDelegate · StatusItemController · HotKeys · Permissions · AppState (@MainActor, single source of truth)
Overlay/    ScreensController ── OverlayPanel (1 per NSScreen) ── CanvasView
                                                                   ├─ backgroundLayer (freeze image / whiteboard)
                                                                   ├─ annotationsLayer (1 sublayer per Annotation)
                                                                   ├─ liveLayer (bitmap cache of the stroke in progress)
                                                                   └─ effectsLayer (spotlight, magnifier, halo, selection UI)
Model/      Annotation · Style · Document (per screen) · DocumentStore · UndoCoordinator
Drawing/    Tool protocol + tools · StrokeBuilder (5-pt Bézier) · PressureFilter · LayerFactory · HitTester
Effects/    Spotlight · Magnifier · Freeze · Whiteboard · CursorHalo · ClickPulse
Input/      ShortcutMap (single-key, while active) · GhostModeController · GlobalMouseMonitor · FnHoldTap (optional)
Capture/    ScreenCapturer (SCK wrapper, async)
Persistence/ SnapshotStore · PNGExporter · PDFExporter
UI/         ToolPalette (NSPanel) · SettingsView (SwiftUI) · SnapshotGallery · Onboarding
```
The data flow runs one way. Input → Tool → `Document` mutation (registered with `UndoManager`) → `CanvasView` diffs the annotation IDs and adds, removes or updates sublayers. Tools never touch layers directly, apart from the live bitmap cache.

## 4. Data model
```swift
struct Style: Codable, Hashable { var color: RGBA; var width: CGFloat; var opacity: CGFloat; var blend: Blend /* normal | multiply */ }

enum Geometry: Codable {
    case stroke(points: [CGPoint], widths: [CGFloat])      // pen & highlighter; widths come from pressure
    case line(from: CGPoint, to: CGPoint)
    case arrow(from: CGPoint, to: CGPoint, control: CGPoint?, head: ArrowHead)
    case rect(CGRect, cornerRadius: CGFloat)
    case ellipse(CGRect)
    case text(origin: CGPoint, string: String, fontSize: CGFloat, background: RGBA?)
    case badge(center: CGPoint, number: Int, format: BadgeFormat /* 1 | A | I */)
}

struct Annotation: Codable, Identifiable { let id: UUID; var geometry: Geometry; var style: Style; var createdAt: Date }

@MainActor final class Document {          // one per screen, keyed by CGDirectDisplayID
    private(set) var annotations: [Annotation]   // array order = z-order
    func insert(_:), remove(ids:), update(id:transform:) // each registers its inverse with UndoManager
}
```
- Coordinates are in each screen's local point space with a top-left origin (`CanvasView.isFlipped = true`). Snapshots also store the screen size and scale so they can be restored on a different display.
- Committed pen strokes turn into a **filled outline**: each Bézier segment is stroked with its own width (`copy(strokingWithWidth:)`), and the pieces are merged with `CGPath.union`, then simplified. This keeps variable-width strokes vector-exact for PDF.
- Hit-testing uses `outlinePath.contains(point)` for filled shapes and an 8-pt tolerance via `copy(strokingWithWidth:)` for thin shapes.

## 5. Interaction model
- **Activate** with a global hotkey (default ⌃⌥⌘A) or the menu-bar click. The app remembers the frontmost app, calls `NSApp.activate()` and makes the overlay panel under the cursor the key window. Single-key tool shortcuts only work while active.
- **Deactivate** with Esc or the hotkey again. Annotations either stay visible (pinned, click-through) or clear with a fade, as set in Settings. Focus returns to the remembered app.
- **Ghost mode** (G, or a global hotkey) keeps annotations visible, sets `ignoresMouseEvents = true` and hands focus back to the previous app. The global hotkey exits it. Optionally, **holding Fn** passes input through temporarily, using a listen-only `CGEventTap` on `flagsChanged`. That needs **Input Monitoring** (`CGPreflightListenEventAccess`/`CGRequestListenEventAccess`), and the feature is hidden until it's granted.
- **Quick draw** (optional, enabled in the menu): the upper mouse side button (button 4) starts drawing with the pen and the lower one (button 3) with the rectangle, without the palette. Left-drag draws; a left click without a drag (under 4 pt) erases every display and stops. Esc or the hotkey stop without erasing, and the tool from before the session is restored either way. Click-based tools chosen by key mid-session keep their clicks. In a hotkey session the side buttons only switch tool, so a click there never erases.
- **Default shortcuts while active:** P pen, H highlighter, L line, A arrow, R rect, O ellipse, T text, N badge, E eraser, V select, S spotlight, M magnifier, F freeze, W whiteboard, C clear, 1–9 colors, `[`/`]` width, ⌘Z/⇧⌘Z undo/redo, ⌘S snapshot, ⌘C copy flattened image. Shift constrains lines and arrows to 45° and rect/ellipse to square/circle. Hold ⌥ while drawing for a temporary highlighter. All shortcuts can be rebound.

## 6. Permissions
| Feature | Permission | Without it |
|---|---|---|
| Pen, shapes, text, ghost toggle, snapshots without a background | none | everything works |
| Cursor halo, click pulses | none (`NSEvent.addGlobalMonitorForEvents` for mouse events) | n/a |
| Freeze, magnifier, export with screen background | Screen Recording (ScreenCaptureKit) | the feature is greyed out, with a "Grant…" button |
| Hold-Fn pass-through | Input Monitoring | the feature is hidden |
| Mouse side buttons | Accessibility (active event tap) | the menu item shows "waiting for Accessibility…" and offers to open Settings |

None are requested at first launch. Each one is asked for the first time its feature is used, with an explanation sheet first.

## 7. Phases and milestones (≈ 8–9 weeks, one developer)

**Status (2026-10-12):** Phases 0–2 implemented as the SwiftPM package `ScreenInk` (`Sources/ScreenInkCore`, `Sources/ScreenInk`). There are 61 unit tests (`scripts/test.sh`) and an off-screen rendering self-test (`ScreenInk --self-test <dir>`), and `scripts/build-app.sh` produces an arm64-only app bundle. Deviations:
- **Hotkeys:** a small Carbon `RegisterEventHotKey` wrapper instead of the `KeyboardShortcuts` package. It has no dependency, and the Command Line Tools can't build the package's SwiftUI recorder.
- **Shortcut rebinding UI:** moved to the Phase 6 Settings window. Bindings are already stored as data (`ShortcutMap`).
- **Deferred to the backlog:** text background pill and the eraser's "preserve kinds" filter.
- **Added (not in the original scope):** dim the screen while drawing. The amount is set in the menu-bar submenu "Dim Screen While Drawing" (Off/Slightly/Medium/Strongly) and saved as `ToolState.dimLevel`. It's drawn as a black `DimView` under the annotations in every canvas.
- **Overlay focus:** the overlay is a non-activating panel that becomes key without activating the app, so the presenter's app keeps the menu bar. There's no "remember and re-activate the previous app" step.
- **Added (not in the original scope), 2026-10-30:** quick draw from the mouse's side buttons (§5). Button numbers were measured on an MX Master 3S over Bluetooth without Logi Options+: plain `otherMouseDown`/`otherMouseUp`, not the synthetic swipes reported for older setups. Rebinding the buttons is done in the config file.
- **Settings moved (2026-10-30):** from `UserDefaults` to `~/.ScreenInk/config.yml` (§2), which also makes the hotkey, keyboard shortcuts and mouse buttons rebindable. Existing `UserDefaults` values seed the file on first run and are then ignored. A rebinding UI remains for the Phase 6 Settings window, which should write through the same file.

**Phase 0 — Skeleton (2 days)**
- Xcode project (arm64, macOS 14, hardened runtime), `LSUIElement`, `NSStatusItem` menu (Activate, Ghost Mode, Snapshots…, Settings…, Quit), KeyboardShortcuts hotkey, `SMAppService.mainApp` launch-at-login toggle, and CI (`xcodebuild test` on GitHub macOS arm64 runners).
- *Done when:* the hotkey toggles a log message; launch at login survives a reboot; CI is green.

**Phase 1 — Overlay + pen (MVP, 1 week)**
- `ScreensController`: one non-activating `NSPanel` per `NSScreen`, with `level = .screenSaver`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, a clear background, no shadow, and `canBecomeKey = true`. Windows are rebuilt on `didChangeScreenParametersNotification`.
- `StrokeBuilder` + `PressureFilter` + the live bitmap cache. On mouseUp the stroke becomes an `Annotation`. Esc and the hotkey toggle the overlay; C clears; undo/redo works.
- *Done when:* drawing feels instant on a 120 Hz display (live-segment render < 2 ms, measured with `os_signpost`); the overlay appears over a full-screen Keynote presentation and on every Space; plugging or unplugging a monitor doesn't crash it or lose the strokes on other screens.

**Phase 2 — Object model & tools (2 weeks)**
- `Tool` protocol (`begin/continue/end/cancel`, `preview(in:)`) and the tools pen, highlighter (multiply, 40% opacity), line, arrow (straight + curved), rect (corner radius), ellipse, text (an editable `NSTextView` while editing, then `CATextLayer`), badge (auto-increment, 1/A/I) and eraser (hit-test delete with "preserve kinds").
- Select tool: click or marquee, move, delete, recolor, bring to front.
- `ToolPalette` (a floating, non-activating `NSPanel` that can be dragged and whose position is remembered), swatches, a width slider, `ShortcutMap` and a settings tab for rebinding.
- Clear with fade (0.3 s) and an optional auto-fade per annotation after N seconds.
- *Done when:* every tool round-trips through `Codable` and undo; ⌘Z after any action restores the exact previous state (property tests); a document with 500 strokes still keeps a 120 Hz live stroke.

**Phase 3 — Ghost mode (4 days)**
- `GhostModeController`, focus hand-back, a menu-bar icon state, and an optional `FnHoldTap` behind Input Monitoring.
- *Done when:* in ghost mode, clicks and scrolls reach the app below while annotations stay visible; exiting restores drawing on the correct screen.

**Phase 4 — Presentation effects (2 weeks)**
- **Spotlight:** a dim layer with an even-odd cut-out mask (circle or rect) that follows the cursor and is resizable with the scroll wheel.
- **Magnifier:** live via `SCStream` (≥ 30 fps, cropped to a region around the cursor), excluding our own app; 1.5–4× zoom; round lens.
- **Freeze:** one `SCScreenshotManager` capture per screen used as `backgroundLayer`, with drawing continuing on top.
- **Whiteboard/blackboard:** full-screen background color behind the annotations, toggled with W.
- **Cursor halo + click pulse:** a global mouse monitor drives a ring layer and a scale+fade pulse animation.
- *Done when:* each effect can be toggled independently and combined with drawing; with Screen Recording denied, the dependent features are disabled with no crash or hang; the magnifier never shows our own overlay.

**Phase 5 — Snapshots & export (1 week)**
- ⌘S saves `annotations.json`, plus `background.png` when frozen or the capture is allowed, plus `thumb.png`. A gallery window (`NSCollectionView`) restores a snapshot as editable annotations, and supports rename, delete and drag-out.
- Export: flattened PNG (`CALayer.render(in:)` over the background), vector PDF (annotations as paths, background as an image) and ⌘C to the clipboard.
- *Done when:* save → quit → restore reproduces identical annotations (golden JSON); PDF paths can be selected and edited in Preview or Illustrator.

**Phase 6 — Polish & release (1 week)**
- SwiftUI Settings (General, Tools & Colors, Shortcuts, Effects, Advanced: window level, FPS cap), a first-run tour, permission sheets and an About window.
- Performance pass: coalesced events and `NSView.displayLink` frame pacing; verify committed layers aren't redrawn while drawing.
- Signing, notarization (`notarytool`), a Sparkle appcast, and a DMG.
- *Done when:* the release checklist below passes on a clean macOS 14 and a clean macOS 15 machine.

## 8. Testing
- **Unit tests:** StrokeBuilder (fixed point sequences produce golden Bézier control points), PressureFilter, Geometry hit-testing, `Codable` round-trips, and undo inverse operations (randomized property test: apply N operations and undo N, ending equal to the start).
- **Rendering tests:** render each annotation kind to a bitmap and compare with a reference PNG (tolerance ≤ 1%).
- **Manual matrix (each release):** 1/2/3 displays with mixed Retina/non-Retina; full-screen apps on another Space; Stage Manager; mirroring; pen tablet (Wacom) pressure; Screen Recording and Input Monitoring granted or denied; macOS 14 and 15.

## 9. Release checklist
- [ ] The `lipo -archs` output is just `arm64`; notarized and stapled; Gatekeeper opens it on a clean machine.
- [ ] No permission prompt at first launch; each prompt is preceded by an explanation.
- [ ] Idle CPU < 1% while inactive; no event taps installed unless Fn-hold or the mouse side buttons are enabled.
- [ ] Sparkle update from the previous build works.

## 10. Key risks
| Risk | Mitigation |
|---|---|
| The overlay doesn't appear over full-screen apps, or Stage Manager changes behavior | Spike in Phase 1 day 1; try `collectionBehavior` combinations and `.screenSaver` vs `.statusBar+1` levels. |
| Keyboard focus is taken from the presenter's app | Use a non-activating panel; activate only while drawing and always restore the previous app. |
| macOS 15 re-prompts for Screen Recording | Keep capture optional; the core pen never needs it. |
| Stroke latency on large documents | Live layer and committed layers stay separate; the bitmap cache redraws only dirty rects. |
| `CGPath.union` is slow or inaccurate for long, dense strokes | Fallback: store segment outlines unmerged as one compound path (same visual output; PDF just has more subpaths). |
