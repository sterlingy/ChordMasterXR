# Chord Defense — design

A 3D arcade mode inside Chord Master XR. Chords attack your octave
stations; you destroy them by playing them. Built so the same game world
drops into AR (the stations sit on your real keyboard) without changes.

## The one rule the player must learn

> **Play the attacker's chord with its lowest note in the octave of the
> station it is attacking.**

Each station guards one octave of the keyboard (C to B), and the stations
sit left-to-right like the keys, so the station above a group of keys *is*
that octave. Any inversion and any spread counts, as long as every note is
a chord tone and the lowest note is in that station's octave. Holding a
chord doesn't keep firing: each shot needs a fresh key press.

## Input

Only the MIDI keyboard during play. Start, Pause/Resume and Stop are the
only buttons. Everything else is decided by the game (waves, difficulty).

## Readability (top priority)

* Every attacker carries a **name plate**: the chord symbol in large white
  text with a dark outline, always facing the player and drawn on top of
  everything. It stays the same size on screen however far away the
  attacker is.
* **Notes** toggle: the plate also lists the notes (C–E–G).
* **Keys** toggle: the most urgent attacker's chord is highlighted on the
  on-screen keyboard (and on the real keyboard in AR), placed in the right
  octave.
* A **target line** runs from each attacker down to the station it is
  heading for, and the station glows while under attack.
* The most urgent attacker's plate is larger and turns orange, then red,
  as it closes in.
* Partial progress: as you hold correct chord tones, the matching note
  orbs on the attacker light up — so you see which note you're missing.

## How chords look ("harmonic hulls")

Inspired by *chord pizzas* (Ethan Hein, NYU MusEDLab) and interval-shape
diagrams: put the 12 pitch classes on a circle, root at the top, and join
the chord tones. Every chord **quality** gets its own silhouette —

* major and minor triads are mirror images,
* the augmented triad is an equilateral triangle,
* the diminished seventh is a square,
* sevenths add a fourth corner, ninths a fifth.

So an attacker's hull *is* its chord's shape, extruded into a ship. With
practice you start recognising "that's a minor 7" from the silhouette
before you read the name. Each corner carries a glowing **note orb**,
coloured by its job in the chord: root white, major 3rd/6th green,
minor 3rd blue, 5th violet, altered 5th orange, 7th gold, 9th cyan.

## Attackers (arcade lineage → our twist)

| Type | Inspired by | Behaviour |
|---|---|---|
| **Drifter** | Space Invaders formations | Arrive in a loose row, drift down their lane in steps |
| **Lane-jumper** | Spy Hunter traffic | Switches lane (= changes target octave) once or twice on the way — the target line shows where it's heading |
| **Diver** | Galaga dives | Swoops in on a curve from the side, fast at the end |
| **Missile** | Missile Command | Small, fast, straight; triads only; comes in salvos |
| **Progression carrier** | (boss) | A big ship carrying a ii–V–I (or I–vi–IV–V); destroy each segment in order. Every 5th wave |

## Waves and sectors

Waves get longer and faster, and new chord families arrive in "sectors",
each with its own colours:

1. **Triad Nebula** (waves 1–4): major/minor triads, drifters and missiles.
2. **Shadow Belt** (5–8): adds diminished and augmented, lane-jumpers.
3. **Seventh Heaven** (9–12): 7, maj7, m7, divers.
4. **Tritone Void** (13–16): m7♭5, dim7, sus chords.
5. **Ninth Gate** (17+): 9ths and everything, all types.

"Use my chord pool" (Settings) replaces the sector chord lists with your
own pool, for drilling.

Between waves: a short break, and one damaged station repairs one shield.

## Stations

One per full octave on your keyboard (from the detected range), up to 8.
Three shields each. A hit takes one shield; at zero the station is lost and
its lane goes dark (chords stop targeting it). Game over when every station
is lost.

## Scoring

* Base points by chord size (triad 100, 4-note 150, 5-note 200).
* Distance bonus: more for kills far from the station (fast reading).
* Combo multiplier: ×1 … ×8, +1 every 4 kills in a row; a misfire (a chord
  that matches nothing in that octave) or a hit on a station resets it.
* Wave clear bonus: 500 × wave, + 250 per full-shield station.

## Stats and leaderboards

* Per game: score, wave, kills, accuracy, best combo, average and fastest
  kill time, slowest chord.
* Every kill/miss is also recorded in the practice stats, so *Smart
  practice* learns which chords you struggle with in the game.
* **Local leaderboard**: top 10 per keyboard size (number of stations).
* **Global leaderboard**: the game talks to an optional HTTP endpoint
  (`leaderboard_url` setting). Nothing is sent unless it's set. The server
  side isn't built yet — see "Global leaderboard" below.

## AR

The game world is built in metres with the stations along the x axis at
y = 0, z = 0 and attackers coming from −z (away from the player). In AR the
world's origin is placed on the calibrated keyboard and each station is
moved over its real octave, so chords literally fly at the keys you have
to play. On desktop a camera sits where the player's eyes would be.

## Global leaderboard (not built yet)

Options, simplest first:

1. A tiny serverless function (Cloudflare Workers + KV, or Supabase) with
   `POST /scores` and `GET /scores?board=…`. Needs an account and a deploy.
2. Apple Game Center / Google Play Games — platform-specific.

Anti-cheat is out of scope; scores are signed with nothing. The client
code sends `{name, score, wave, kills, accuracy, stations, version}`.
