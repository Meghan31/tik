# Tik

A native macOS menu-bar app that plays near-instant, realistic keyboard sounds as you type, in every app.
Private by design: Tik reacts to physical key codes only and never stores, rebuilds or sends what you type.

Product and engineering spec: [`TIK_MACOS_RND.md`](TIK_MACOS_RND.md).

## Run it

1. Open `tik.xcodeproj` in Xcode and press **⌘R**.
2. The welcome window opens. Click **Allow Keyboard Monitoring**, then switch on **tik** in
   System Settings → Privacy & Security → Input Monitoring.
3. If Tik shows **Relaunch Tik**, click it (macOS sometimes applies the permission only to a fresh process).
4. Type anywhere. The keyboard icon in the menu bar has packs, volume and toggles.
   **Double-tap Right ⌥ Option** turns Tik on/off from any app (change it in Settings → Behavior).

### On/off command

| Option | How it stays out of other apps' way |
|---|---|
| Double-tap Right ⌥ Option (default) / Right ⇧ Shift | A modifier tapped alone types nothing and triggers no shortcut. Any other key, click or modifier in between cancels the gesture, so ⌥+letter accents and Shift+letter never trigger it. |
| Custom key combination | Registered with macOS as an *exclusive* hot key, so only Tik receives it. Tik rejects combos that macOS uses (Keyboard Shortcuts settings) or that another app has claimed, and requires ⌘ or ⌃ plus a second modifier. |
| Spotlight / Siri / Shortcuts | App Intents: "Toggle Tik", "Turn Tik On", "Turn Tik Off". Also `shortcuts run "Toggle Tik"` once added in the Shortcuts app. |

### Make your own pack

Settings → Sound Packs → **Make Your Own Pack…** (or from the menu bar). Drop audio files onto a key type.
A single file can be a recording of one key pressed several times: Tik's slicer (`Packs/PackBuilder.swift`,
reference implementation and tests in `tools/slicer.py`) finds each press and, when it can, each release.
It creates release sounds if you only give presses, evens out loudness, and lets you **Try It** by typing anywhere before saving.
Saved packs use the open folder format below.

Run the unit tests with **⌘U**.

> After a rebuild, if Tik goes quiet with permission still on, remove **tik** from Input Monitoring
> (the – button), add it again, and relaunch. Debug builds occasionally get a new code identity.

## How it works

```
CGEventTap (listen-only, own thread)
  → TikKeyEvent {keyCode, phase, flags}      no characters, ever
  → SoundEngine: key state · repeat filter · shuffle-bag variant · pitch/gain jitter · key-position pan
  → VoiceMixer: lock-free ring → 64-voice real-time sampler (AVAudioSourceNode render callback)
  → AVAudioEngine main mixer → system output
```

| Folder | What's inside |
|---|---|
| `tik/Core` | Key map (physical positions, classes), event model + key state machine, settings, RNG + shuffle bag |
| `tik/Input` | `EventTap` (dedicated run-loop thread, timeout recovery) and Input Monitoring permission |
| `tik/Audio` | `VoiceMixer` (real-time sampler), `SoundEngine` (decides what plays), `AudioOutput` (engine, device changes, sleep/wake), `SoundBank` |
| `tik/Packs` | Pack discovery, `.tikpack` + folder loaders, import validation, editable export |
| `tik/App` | `AppModel`: lifecycle, permission flow, preview, login item, diagnostics |
| `tik/UI` | Menu-bar panel, settings window, onboarding |
| `tik/Resources` | The six bundled packs |
| `tools/` | The Python synthesizer that generates the bundled packs |

Latency budget: the event tap calls straight into `SoundEngine` → `VoiceMixer.enqueue` (microseconds).
The sound starts at the next audio IO cycle (256 frames ≈ 5.3 ms at 48 kHz in Balanced mode), plus the device's own latency.
Settings → Diagnostics shows the measured numbers.

## Sound packs

The pack list has three sections, in this order:

**Recorded:** Cardboard, Cream (the default), Crystal Purple, Japanese Black, Milky Yellow, Oreo, Super Red and Mechanical.
They're built from the recordings in `sound-sources/` by `tools/build_recorded_packs.py`:

- **Source files:** each style folder holds 13 keys, each with a press and a release, named by PC scan code. The keys are W E R I P / A K L / C V, Enter, Space and ⌘.
- **Trimming:** leading silence is cut to 2 ms before the main transient, so clicks land when the key registers. Hissy tails are faded out, and everything becomes 48 kHz mono.
- **Rows:** letters are grouped by keyboard row (top, home, bottom). Each key you press uses samples from its own row.
- **Big keys:** Delete, Shift, Tab and Caps get retuned Enter samples.
- **Mouse:** clicks come from the synthesized pack.
- **Level:** loudness is matched to the synthesized packs.
- **Mechanical:** this pack is sliced from `mechanical-keyboard.mp3`, a fast typing recording. Loud, bright hits are presses, quiet, dull ones are releases, and the two deepest presses become the space bar.

```bash
python3 tools/build_recorded_packs.py sound-sources tik/Resources tik/Resources/cream.tikpack
```

> `sound-sources/` sits **outside** `tik/` on purpose. Xcode copies every file inside `tik/` into the app,
> and the seven style folders share file names (`17-down.wav`…), which breaks the build.
> If these recordings come from another app or a third party, keep them to your own builds. Don't publish them.

**Synthesized:** these are the original six packs (Cream, Deep, Crisp, Click, Soft, Retro), made by `tools/tiksynth.py`.
The synth uses dense inharmonic modal banks, decaying band-limited noise, a contact click, a body "thock" with pitch drop,
stabilizer rattle for big keys, and early desk reflections. Every variant re-rolls modes and press strength.

Regenerate them:

```bash
pip install numpy scipy
python3 tools/build_packs.py tools/out     # writes *.tikpack + demo WAVs
cp tools/out/*.tikpack tik/Resources/
```

### Custom packs (open folder format)

```
MyPack/
  manifest.json
  sounds/alpha/down-01.wav  up-01.wav …
```

```json
{
  "id": "com.you.mypack",
  "name": "My Pack",
  "gain": 1.0,
  "groups": {
    "alpha": { "down": ["sounds/alpha/down-01.wav"], "up": ["sounds/alpha/up-01.wav"] },
    "space": { "down": ["sounds/space/down-01.wav"], "up": ["sounds/space/up-01.wav"] }
  },
  "mapping": { "49": "space" }
}
```

Groups: `alpha`, `modifier`, `function`, `nav`, `wide` (Tab/Caps/Shift), `backspace`, `enter`, `space`, `mouse`.
Missing groups fall back (space/enter/backspace → wide → alpha). `mapping` overrides any key code → any group,
so per-key packs work too. On import Tik validates paths and sizes, converts everything to 48 kHz mono, trims
leading silence and fades tails. Settings → Sound Packs → **Make Editable Copy** writes the current pack in this
format so you can swap in your own recordings.
