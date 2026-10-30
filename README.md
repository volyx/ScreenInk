<img src="docs/images/icon.png" width="128" alt="ScreenInk icon">

# ScreenInk

A macOS menu-bar app for drawing on top of the screen during presentations, demos and screen recordings.

Press **⌃⌥⌘A** (or pick **Draw on Screen** from the menu-bar icon) and every display gets a transparent canvas. Press **Esc** or the hotkey again to put it away.

![Annotating a slide with the pen, highlighter, arrow, text and numbered badges](docs/images/drawing.png)

With **Dim Screen While Drawing** on, the screen behind the ink darkens so annotations stand out:

![The same slide with the screen dimmed behind the annotations](docs/images/dimmed.png)

## Features

- Pressure-sensitive pen, highlighter, line, arrow (straight or curved), rectangle, ellipse, text and numbered badges
- Eraser, selection (move, delete, recolor, bring to front), undo/redo
- Floating tool palette with 9 colors and a width slider
- Works over full-screen apps, on every Space and on all connected displays, and keeps each display's drawing when monitors are plugged in or out
- Menu-bar settings: auto-fade drawings after a few seconds, dim the screen while drawing, launch at login
- Optional: start drawing from a mouse's side buttons

## Requirements

- macOS 14 or later on Apple Silicon
- Swift 6 toolchain (Xcode or the Command Line Tools)

## Build and run

```sh
make install      # check this Mac and install the toolchain (Command Line Tools) if missing
make run          # build build/ScreenInk.app and launch it
make build        # build the app bundle only
make check        # unit tests + off-screen rendering self-test (what CI runs)
make screenshots  # re-render the README images in docs/images/
make icon         # re-draw the app icon (scripts/make-icon.swift)
make clean
```

The bundle is ad-hoc signed by default. To sign it for distribution, set `SIGN_ID="Developer ID Application: …"` when you run `scripts/build-app.sh`. Launch at Login only works for a signed app run from `/Applications`.

## Shortcuts while drawing

| Key | Action |
|---|---|
| P · H · L · A | Pen · Highlighter · Line · Arrow |
| R · O · T · N | Rectangle · Ellipse · Text · Numbered badge |
| E · V | Eraser · Select |
| 1–9 | Color (recolors the selection when one exists) |
| `[` · `]` | Thinner · Thicker |
| C | Clear all |
| ⌘Z · ⇧⌘Z | Undo · Redo |
| ⌘A · ⌘] | Select all · Bring to front |
| Delete | Delete the selection |
| Esc | Deselect, or stop drawing |

Hold **Shift** to constrain lines and arrows to 45° and rectangles/ellipses to squares/circles. Hold **⌥** with the pen for a temporary highlighter, or with the arrow for a curved arrow. Double-click text with the select tool to edit it.

## Drawing with the mouse's side buttons

Turn on **Draw with Mouse Side Buttons** in the menu-bar menu to start drawing straight from the mouse. The default buttons match a Logitech MX Master 3S:

| Input | Action |
|---|---|
| Upper side button | Start drawing with the pen |
| Lower side button | Start drawing with the rectangle |
| Left-drag | Draw, as many times as you like |
| Left click without dragging | Erase everything on every display and stop drawing |

macOS asks for the **Accessibility** permission when you turn this on, so that a press doesn't also go Back or Forward in the app underneath. While it's on, those two buttons don't navigate in any app. Turn it off to get them back. If you use Logi Options+ or another mouse tool that remaps these buttons, ScreenInk may not see them.

Each rebuild of an ad-hoc signed app can lose the permission. If the buttons stop working, run `tccutil reset Accessibility dev.screenink.ScreenInk` and grant it again.

## Config file

All settings live in `~/.ScreenInk/config.yml`, which ScreenInk creates on first launch. Choose **Open Config File…** from the menu-bar menu to edit it. Saved changes apply right away, and any option you leave out uses its default. Comments in the file list the available values for each option.

```yaml
tool: pen                     # pen, highlighter, line, arrow, rectangle, ellipse, text, badge, eraser, select
color: red                    # red, orange, yellow, green, blue, purple, pink, white, black
width: 4                      # 1 to 32
auto_fade_seconds: 0          # 0 = never
dim_level: 0                  # 0 to 0.8
hotkey: ctrl+option+cmd+a     # modifiers plus a letter, digit, space or f1-f12
side_buttons: false           # needs the Accessibility permission
mouse_buttons:                # button number: tool
  3: rectangle
  4: pen
shortcuts:                    # key: a tool, a color, thinner, thicker or clear (the file lists them all)
  "p": pen
  "[": thinner
  "1": red
palette_x: 1775               # where the palette was left; remove both to reset it
palette_y: 274
```

If you include `shortcuts` or `mouse_buttons`, that section replaces the defaults, so delete a line to unbind a key.

- If the file has a mistake, ScreenInk names the line, keeps its current settings and doesn't touch the file until it's fixed.
- Changing a setting in the app rewrites the file from the built-in template, which drops comments you added.
- Launch at Login stays in the menu only, because macOS manages it.
- Only this part of YAML is supported: nested `key: value` lines, quotes and comments.

## Project layout

- `Sources/ScreenInkCore`: model and geometry (no AppKit), unit-tested in `Tests/`
- `Sources/ScreenInk`: the AppKit app (overlay windows, tools, palette, menu)
- `PLAN.md`: scope, design decisions and roadmap
- `docs/images/`: README screenshots, rendered off-screen by `make screenshots`
