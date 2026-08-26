# Window Wrangler

A macOS menu-bar utility for arranging windows across apps. Cascade every visible window in a title-bar-preserving fan layout, lasso windows across apps with click-and-drag, save named window groups ("Corrals") that restore later — including browser tabs — and precision-place any window into a drawn rectangle with **Plot Mode**.

**Status:** MVP-1.0 + Plot / native-Chromium transport / two-phase z-order correction ownership + geometry-quiescence barrier. Distribution pipeline shipped: Developer ID–signed, Apple-notarized DMG + PKG in `dist/`, plus MDM PPPC profiles under `deployment/` — see [`docs/RELEASE_TESTING.md`](docs/RELEASE_TESTING.md).

---

## Requirements

- macOS 13 (Ventura) or later; developed and tested on macOS 26.5 (Tahoe)
- Xcode 26.5+ to build
- Accessibility permission (mandatory)
- Automation permission per browser (only if you want tab capture in Corrals)

## Build and run

Open the project in Xcode and press **⌘R**:

```
open WindowWrangler/WindowWrangler.xcodeproj
```

The project uses Xcode's synchronized file-system group — new `.swift` files in `WindowWrangler/WindowWrangler/` are auto-picked up without editing the `.pbxproj`.

The bundle identifier is `com.jmw3.WindowWrangler`. The user-facing name is **Window Wrangler**. The repo folder, Xcode project, source folder, and test target are all named `WindowWrangler` / `WindowWranglerTests` — matching the product name throughout.

## First launch

On first launch you'll see an onboarding window asking for **Accessibility** permission. Grant it in System Settings → Privacy & Security → Accessibility. The app auto-detects the grant and dismisses the onboarding window.

If Chrome, Safari, Brave, Edge, Vivaldi, or Opera are installed, macOS will also prompt for **Automation** permission per browser during onboarding. Grant them to enable Corral's tab capture. If you decline, Corral still saves the browser's window position — you just won't get the tab list back on restore.

## Keyboard shortcuts

All shortcuts use the `⌃⌥⌘` (Control-Option-Command) chord.

| Shortcut | Action |
|---|---|
| `⌃⌥⌘.` | Cascade Down-Right (current app) |
| `⌃⌥⌘,` | Cascade Down-Left (current app) |
| `⌃⌥⌘]` | Cascade All Apps Down-Right |
| `⌃⌥⌘[` | Cascade All Apps Down-Left |
| `⌃⌥⌘↑` | Restore Previous Layout |
| `⌃⌥⌘C` | Toggle Lasso Mode |
| `⌃⌥⌘P` | Toggle Plot Mode (snap window to drawn area) |
| `⌃⌥⌘S` | Corral: save current lasso selection as a named group |
| `⌃⌥⌘R` | Release: open the saved-groups menu |

The same actions are available from the menu-bar icon.

## Basic workflows

**Cascade** — position the mouse cursor on the display you want cascaded, then hit one of the cascade shortcuts. Wrangler fans that display's windows in a stair-step so every title bar and browser tab strip stays visible.

**Lasso** — press `⌃⌥⌘C` to enter lasso mode (a small chip appears in the corner). Click-and-drag to draw a rectangle around windows across any apps. Selected windows get dashed blue outlines. Press `⌃⌥⌘C` again or `Esc` to exit lasso mode.

**Group drag** — while lasso mode is on, click and drag on any selected window to move the entire selection together with a Finder-style ghost preview.

**Corral (save)** — with a lasso selection active, hit `⌃⌥⌘S`. Type a name and press Return. The selection is saved as a named Corral, including tab lists for any browser windows.

**Corral (release)** — hit `⌃⌥⌘R`. A menu opens listing your saved Corrals. Click one to restore, or click the × next to a corral to delete it. Or use the menu-bar dropdown's "Release ▸" submenu to restore directly without opening the pill.

**Plot (Snap Window to Drawn Area)** — hit `⌃⌥⌘P` to enter Plot Mode (a "Press Esc to End Plot Mode" pill appears near the top). Click any window to select it, then click-and-drag to draw the destination rectangle. On release, the window snaps to that rectangle. Each edge of the Plot Area independently snaps to the display edge when it enters the outer 15% zone. Interior coordinates are preserved exactly as drawn — no grid, no presets. Chromium browsers (Chrome, Brave, Edge, Opera, Vivaldi, Chromium) commit via a reliable AppleScript-bounds path so the drawn size persists where AX size writes typically revert. Plot Mode is mutually exclusive with Lasso; press `Esc` or `⌃⌥⌘P` again to exit.

## Things to know as a user

**Multi-Desktop (Virtual Desktop / Space) restore behavior.** If you save a Corral on one Desktop and restore it while looking at a different Desktop, macOS may auto-switch you to the Desktop where the target apps have their most-recently-active windows. This is macOS's own "when switching to an application, switch to a Space with open windows for the application" behavior — not something the app controls.

If you want restore to always stay on your current Desktop instead of switching:
**System Settings → Desktop & Dock → Mission Control → "When switching to an application, switch to a Space with open windows for the application"** → **OFF**.

With that setting off, Corral restore always creates windows on your current Desktop.

**The 5-corral limit.** MVP-scope cap. You can delete a corral to make room. Adjustable in code if needed.

**Slow-app group drag.** During a fast group drag of Chrome or Zoom windows, the dashed selection outlines can visibly lag the moving windows by 20–40 pixels for a frame or two before catching up on release. This is inherent to macOS's cross-app Accessibility latency (Rectangle, Magnet, and Apple's own tiling all show this).

**If the app ever feels sluggish** after many operations in one session, quit and relaunch. Some AppleScript failures leak a background thread we can't cancel; a fresh launch clears them.

**Launch at Login.** The menu-bar dropdown has a "Launch at Login" toggle. Turn it on once and Wrangler will silently start on every login / reboot — you never need to relaunch it manually. Managed via the standard **System Settings → General → Login Items & Extensions**; you can revoke there or by unchecking the menu item.

## Documentation

- [`docs/HANDOFF.md`](docs/HANDOFF.md) — comprehensive developer guide: architecture, module responsibilities, TCC deep dive, all known limitations with root causes, extension surfaces, deferred features.
- [`docs/TECHNICAL_OVERVIEW.md`](docs/TECHNICAL_OVERVIEW.md) — product technical profile for consumption by external planning agents. Feature inventory, competitive landscape, distribution readiness gap analysis.
- [`CLAUDE.md`](CLAUDE.md) — working notes for the AI-assisted development process (author-facing).

## License

Proprietary — all rights reserved. See [`LICENSE`](LICENSE) for the full terms.
