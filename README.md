# Chord Master XR

Chord training for keyboard players. The app shows a chord; you play it (on a
MIDI keyboard, the on-screen keyboard, or your computer keyboard) or name it.
Runs on Windows, in a web browser, and in passthrough XR on Android XR
headsets (Samsung Galaxy XR, Xreal Aura).

Built with Godot 4.7.2 (GDScript, Compatibility renderer).

---

## Running it

| Where | How |
|---|---|
| **Editor** | Open the project in Godot 4.7.2 and press **F5**. |
| **Galaxy XR / Aura** | Headset in developer mode with (wireless) USB debugging. In the editor use the Android **Remote Deploy** button (top right), or export the **Android XR** preset and `adb install -r build/android/ChordMasterXR.apk`. |
| **Windows** | Project → Export → **Windows Desktop**. |
| **Browser** | Export the **Web** preset and serve `build/web/` over http(s). Chrome asks for MIDI permission on first use. |

The app starts in XR automatically when an OpenXR runtime is present (the
headset); otherwise it shows the flat screen.

---

## Practice modes (top-right dropdown)

**Play the chord** – a chord is shown; play it. It stays until you get it
right. Rules:
- Rolled chords count (you don't have to hit all notes together).
- Any note that isn't in the chord is a miss (release and try again).
- Inversions are fine unless **Strict inversions** is on (Settings → Rules),
  in which case only the inversion asked for counts.
- **Octave mode**: the root must be in the given octave (C4 = middle C).
- The sustain pedal is ignored.

**Name It** – the chord is shown on the staff; pick its name from 3–5 cards.
Wrong answers are plausible (same root, shared notes) but never a chord that
sounds identical.

**Song (play along)** – pick a song, press **Start**. After a one-bar
count-in the chords change in time. Play each chord when it changes; you're
graded per chord:

| Grade | Timing |
|---|---|
| Perfect | within 60 ms |
| Great | within 120 ms |
| Good | within 200 ms |
| OK | anywhere in the chord's window |
| Miss | not played |

Options in the song bar: key (− / + transposes; the key and its key
signature are shown), **BPM** (starts at the song's own tempo, remembered
per song; **Original** resets it), metronome on/off, **Play chords**
(the app plays each chord as backing). The results screen shows your rank,
grade counts, average timing error and whether you tend to rush or drag.

**Chord Defense (game)** – an arcade mode: chords fly at your octave
stations; destroy each one by playing it with its **lowest note in the
octave of the station it attacks** (any inversion). Waves get faster and
bring new chord families (sectors), lane-jumping ships, dive-bombers,
missiles, octave echoes and a progression boss every 5th wave. Scores go
to a per-keyboard-size local leaderboard and, if a server address is set
(Settings → Progress), a global one (`tools/leaderboard_worker.js` is a
ready-to-deploy Cloudflare Worker). In the headset the game plays out on
your calibrated real keyboard. Design notes: `docs/chord_defense.md`.

### Exercises (Play / Name It)

| Exercise | What it does |
|---|---|
| Smart practice | Draws from your chord pool, favouring chords you miss or play slowly. |
| Random from pool | Every pool chord equally likely. |
| ii–V–I in all keys | m7 → 7 → maj7 around the circle of fourths. |
| Circle of fourths | Each pool quality, roots C → F → B♭ → … |
| Inversion ladder | Each pool chord in every inversion (strict). |
| Diatonic in key | The pool's key in scale order (I, ii, iii…). |
| Voice leading | ii–V–I in all keys using the inversion that moves your hand least. |

**Chords…** picks the pool: presets (Maj7, all sevenths, C major sevenths…),
any chord types × roots, the chords of a key (major / natural minor /
harmonic minor, triads and/or sevenths), or a typed list (`Cmaj7 Dm7 G7`).

---

## Connecting a keyboard

**USB MIDI on Windows/Mac/Linux** – plug it in; it's picked up automatically
(hot-plug works). Settings → Input shows connected devices, the last MIDI
message received, and a channel filter (Omni or 1–16).

**Bluetooth MIDI on the headset** – pair the keyboard with the headset, then
in the app: Settings → Input → **Connect Bluetooth MIDI keyboard** (allow the
Bluetooth permission the first time). Already-paired keyboards are also
opened automatically at startup.

**USB MIDI on the headset** – plug the keyboard into the headset / compute
puck with a direct cable or OTG adapter (not through a charger or powered
hub – the headset must be the USB host); it's opened automatically.

**XR controls** – touch buttons with your index fingertip, or point and
pinch. Pinch the bar under the panel to move it, a corner ball to resize
it. Allow the hand-tracking permission on first launch.

**Keyboard on your computer, playing in the headset (Wi-Fi relay)**
1. Laptop and headset on the same Wi-Fi network.
2. Run Chord Master XR on both (the headset app must be open in front of
   you – Android pauses apps that aren't).
3. Headset: **Receive MIDI over Wi-Fi** is on by default. Leave **Send**
   off there.
4. Laptop: Settings → Input → **Send this device's MIDI over Wi-Fi**. The
   headset is found automatically within a second ("Sending to SM-I610
   (10.0.0.x)"); no IP or firewall rule needed. **Headset IP** is only a
   fallback for unusual networks.
5. Optional: turn off Settings → Sound → **Sound the notes I play** on the
   laptop so only the headset makes sound.

**No MIDI keyboard** – use the on-screen keyboard (click/tap keys), switch
Input to **On-screen keyboard (select + submit)**, or turn on **Play notes
with the computer keyboard**: `A S D F G H J K L ;` are white keys from
middle C, `W E T Y U O P` are black keys, `Z`/`X` shift the octave.

**Keyboard range** – Settings → Input → **Detect** then press your lowest
and highest keys, or pick a key-count preset. Chords that don't fit are
never asked for.

---

## Settings overview

- **Input** – answer method, MIDI channel, devices, Bluetooth, keyboard range,
  Wi-Fi relay, computer-keyboard piano.
- **Display** – show chord notes, highlight keys, staff on/off, clef
  (auto / treble / bass / grand), key signature vs accidentals, number of
  Name It choices.
- **Rules** – strict inversions, varied inversions, octave mode, pause after a
  correct chord.
- **Sound** – play chord on prompt / after correct, echo your notes (turn off
  if your keyboard has its own sound), volume, spoken chord names
  (text-to-speech voice and rate).
- **Progress** – your weakest chords; reset statistics or settings.

Settings and statistics are saved per device (`user://settings.cfg`,
`user://stats.json`).

---

## Adding songs

Songs live in [`data/songs.json`](data/songs.json). Each song has sections of
bars and an `order` to play them in. A bar is one or more chord symbols; the
bar's beats are split evenly between them:

```json
{
  "id": "my_song", "title": "My Song", "artist": "Me", "year": 2026,
  "decade": "Mine", "bpm": 90, "beats_per_bar": 4, "key": "G",
  "sections": {
    "Verse":  ["G", "Em", "C D", "G"],
    "Chorus": ["C", "G", "Am7 D7", "G"]
  },
  "order": ["Verse", "Chorus", "Verse"]
}
```

Chord symbols use the same names as the app (`C`, `F#m`, `Bbmaj7`, `Am7b5`,
`Dsus4`, `Eb9`…). The included charts are simplified, chords only.

---

## Project layout

```
scenes/              main.tscn (entry), xr_main.tscn, ui/*.tscn (editable UI)
ui/theme.tres        shared look – edit to restyle everything
scripts/core/        music theory, chord matcher, pools, exercises, stats, songs (no UI)
scripts/autoload/    Settings, Midi, Synth, Voice (always-loaded services)
scripts/ui/          screen, settings, pool picker, staff, keyboard, beat dots
scripts/net/         Wi-Fi MIDI relay
scripts/xr/          XR scene, floating panel, hand/controller pointers
scripts/defense/     Chord Defense game (rules, waves, records, 3D view)
data/songs.json      song chord charts
audio/piano/         baked piano tones (tools/bake_piano.gd regenerates)
fonts/               Noto Music (SIL OFL) for music symbols
addons/              godot_ai (MCP), gut (tests), godotopenxrvendors, chordmaster_midi
android_plugin/      Java source of the Android MIDI plugin
tests/               GUT unit tests
```

UI tips: nodes marked `%` in the scene tree are referenced by scripts – move
them freely, don't rename them. A CheckButton / OptionButton / HSlider /
LineEdit in the Settings scene with a `setting` metadata entry is bound to
that setting automatically (OptionButtons also need an `options` array).

---

## Development

Run the tests (headless):

```
godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```

Rebuild the Android MIDI plugin after changing its Java code:

```
powershell -File android_plugin\build_plugin.ps1
```

Screenshot a UI state without hardware (dev scripts in `scripts/dev_scripts.gd`):

```
powershell -File tools\shot.ps1 -Name song_sim -Out C:\tmp\song.png
```

The Android XR preset uses the Gradle build; the build template lives in
`android/` (not committed – reinstall with Project → Install Android Build
Template). The **Chord Master MIDI (Android)** plugin must be enabled
(Project Settings → Plugins) or headset builds won't read MIDI.

## Known gaps

- The real-keyboard highlight overlay (XR calibration) is still a first
  version.
- Sending sound to an external synth (MIDI out) isn't implemented.
- Highlighting the keys of your real keyboard in passthrough is planned.
