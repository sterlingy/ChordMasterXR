# Handoff: working on Chord Master XR from another PC

How to pick up this project on a fresh Windows machine (for example the
second studio PC) and where things stand. Feature docs are in
[README.md](../README.md) and [chord_defense.md](chord_defense.md).

_Last updated 2026-11-25 (commit after 575d76c)._

---

## 1. Get the code

Two remotes carry the same `main`:

| Remote | URL | Notes |
|---|---|---|
| `origin` | https://gitlab.shivoostudios.com/shivoo-core/godot/chordmasterxr.git | primary |
| `github` | https://github.com/sterlingy/ChordMasterXR.git | public; also hosts the web build (`gh-pages`) and releases |

```powershell
git lfs install
git clone https://gitlab.shivoostudios.com/shivoo-core/godot/chordmasterxr.git ChordMasterXR
cd ChordMasterXR
git remote add github https://github.com/sterlingy/ChordMasterXR.git
git lfs pull
```

**Git LFS is required.** About 55 files are LFS: fonts, audio, and the plugin
binaries in `addons/` (OpenXR vendors, the MIDI plugin AARs, godot_git).
Without `git lfs pull` the editor fails to load the addons.

## 2. Tools

| Tool | Version / where | Needed for |
|---|---|---|
| Godot | **4.7.2 stable**, console exe (`Godot_v4.7.2-stable_win64_console.exe`) | everything |
| Export templates | 4.7.2 (Editor → Manage Export Templates) | any export |
| Android SDK + JDK 21 | Editor Settings → Export → Android | Android XR export (Gradle build) |
| Android build template | Project → Install Android Build Template (creates `android/build/`, not in git) | Android XR export |
| adb | Android platform-tools | headsets |
| Node 23+ | optional | reading a headset browser's console (section 6) |
| GitHub CLI `gh` | optional | releases |

Open the project once in the editor (or run `--headless --import`) so
`.godot/` is built before running anything from the command line.

## 3. Run and test

```powershell
# App (flat screen; switches to XR when an OpenXR runtime is present)
godot --path .

# Unit tests (GUT): expect 119 passing
godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```

Dev helpers (all after `--`):

| Args | Does |
|---|---|
| `--screenshot=<png> [--script=<name>]` | saves a screenshot of the flat app, optionally after a step in `scripts/dev_scripts.gd` |
| `--xrpreview [--script=<name>] [--screenshot=<png>]` | the XR scene seen flat on the desktop (no headset), e.g. `--script=name` or `--script=defense` |

`tools/shot.ps1 -Name <dev script> -Out <png>` wraps the flat screenshot.

## 4. Builds

Presets in `export_presets.cfg`:

| Preset | Output | Notes |
|---|---|---|
| Windows Desktop | `build/windows/ChordMasterXR.exe` | ship `libgodotopenxrvendors.dll` beside the exe |
| Android XR | `build/android/ChordMasterXR.apk` | package `com.chordmasterxr.app`; Gradle build |
| Web | `build/web/index.html` | PWA off on purpose (its service worker served stale builds) |

```powershell
godot --headless --path . --export-release "Web" build/web/index.html
godot --headless --path . --export-debug "Android XR" build/android/ChordMasterXR.apk
```

- The Android export often finishes but Godot hangs on exit: put a timeout
  on it and look for "DONE export" in the output.
- Each export restarts the adb daemon; wireless headsets can take a few
  minutes to come back (`adb mdns services`, then `adb connect <ip:port>`).
- The Android MIDI plugin is prebuilt in `addons/chordmaster_midi/bin`.
  Rebuild only if you change it: `powershell -File android_plugin\build_plugin.ps1`.

## 5. Publish the web build (GitHub Pages)

Live at **https://sterlingy.github.io/ChordMasterXR/**, served from the
`gh-pages` branch of the `github` remote (no CI, published from a PC):

1. Bump `BUILD` in `scripts/xr/web_xr.gd` (shown beside the Enter AR button).
2. Export the **Web** preset to `build/web`.
3. Copy `build/web/*` (without `*.import` files) into a scratch git repo,
   add an empty `.nojekyll` and `tools/web/index.service.worker.js`
   (a clean-up worker that removes the old PWA cache).
4. Commit there on branch `gh-pages` and
   `git push -f https://github.com/sterlingy/ChordMasterXR.git gh-pages:gh-pages`.
5. Pages updates in about a minute; compare the md5 of the live
   `index.pck` with `build/web/index.pck` to confirm.

Browsers may keep the old files for up to 10 minutes (Pages sets
`max-age=600`); a refresh after that gets the new build.

## 6. Web AR (WebXR) in headset browsers

Chrome on Android XR has no multiview, so Godot's own WebXR can't run there.
Instead:

- `web/webxr_stereo.js` (page script, from ShivooXRPlugin) runs the
  immersive-ar session and copies two eye images into the headset.
- `scripts/xr/web_xr.gd` (`WebXRStereo`) renders the eyes and feeds the same
  trackers the OpenXR rig reads, so `scenes/xr_main.tscn` runs unchanged.
- Web builds lack the OpenXR classes: never use `OpenXRInterface` or other
  OpenXR types in XR scripts, or the XR scene fails to load on the web only.
- Hand clicks use the browser's select (pinch) event. The joint-based pinch
  reads "pinched" for a relaxed hand on the Aura, so it is not used for clicks.

URL switches: `?xrdebug=1` (floating status readout in AR),
`?xrpreview=1` (XR scene flat in a desktop browser).

**Reading the headset browser's console:** with the headset on wireless adb,
`adb forward tcp:9333 localabstract:chrome_devtools_remote`, then
`http://localhost:9333/json` lists tabs; connect to a tab's
`webSocketDebuggerUrl` with the DevTools protocol (`Runtime.enable` streams
`console.log`). Notes:
- Page timers pause during immersive AR; to sample per frame, hook
  `XRSession.prototype.requestAnimationFrame`.
- Don't reload the page while someone is in AR (check
  `window.ShivooStereo.session` is null first).
- A stale build can be cleared with `Network.clearBrowserCache` + `Page.reload`.

## 7. Status (2026-11-25)

- Windows, Android XR (Galaxy XR, Xreal Aura) and web all work.
- **Web AR 6** confirmed on the Aura: pinch to click and grab, Exit AR button
  on the panel, floating Name It answers, keyboard overlay and Chord Defense on
  the real keyboard after "Calibrate real keyboard" (web settings are stored
  in the browser, separate from the headset app).
- A QR code to the web URL is planned for the labs site.
- Release v0.1.0 on GitHub holds the Windows zip.
