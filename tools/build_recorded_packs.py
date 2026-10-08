"""
Builds Tik's recorded sound packs from sound-sources/.

  sound-sources/<Style>/<scancode>-down.wav, <scancode>-up.wav   (13 keys per style)
  sound-sources/mechanical-keyboard.mp3                         (a short typing recording)

Each style becomes tik/Resources/rec-<style>.tikpack with:
  • leading silence trimmed to 2 ms before the main transient (no "asset latency"),
    tails cleaned up, everything resampled to 48 kHz mono
  • per-row groups (top / home / bottom letter rows) mapped onto the physical keyboard,
    so keys sound like the region of the board they sit on
  • Enter, Space and ⌘ from their own recordings; Shift/Tab/Caps and Delete derived from Enter
  • mouse clicks borrowed from Tik's synthesized pack
  • loudness matched to the other Tik packs

Usage:  python3 tools/build_recorded_packs.py <sound-sources dir> <output dir> [synth cream.tikpack]
"""
import json
import os
import struct
import subprocess
import sys
import tempfile

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, resample_poly, sosfilt

SR = 48000

# PC scan code (file names) -> macOS virtual key code
SCAN_TO_MAC = {17: 13, 18: 14, 19: 15, 23: 34, 25: 35, 30: 0, 37: 40, 38: 37, 46: 8, 47: 9,
               28: 36, 57: 49, 3675: 55}
ROW_OF_SCAN = {17: "row_top", 18: "row_top", 19: "row_top", 23: "row_top", 25: "row_top",
               30: "row_home", 37: "row_home", 38: "row_home",
               46: "row_bottom", 47: "row_bottom"}

# macOS key codes per physical row (number row joins the top row)
MAC_ROWS = {
    "row_top": [50, 10, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24,
                12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42],
    "row_home": [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39],
    "row_bottom": [6, 7, 8, 9, 11, 45, 46, 43, 47, 44],
}

STYLES = [
    # folder,          id slug,          display name,     keycap color
    ("Cardboard",      "cardboard",      "Cardboard",      "#B48A5E"),
    ("Cream",          "cream",          "Cream",          "#EFE4CB"),
    ("Crystal-purple", "crystal-purple", "Crystal Purple", "#9D7BEA"),
    ("Japanese-black", "japanese-black", "Japanese Black", "#26262A"),
    ("Milky-yellow",   "milky-yellow",   "Milky Yellow",   "#F2D58A"),
    ("Oreo",           "oreo",           "Oreo",           "#3B3B40"),
    ("Super-red",      "super-red",      "Super Red",      "#E0393E"),
]
MECH = ("mechanical", "Mechanical", "#8C96A3")

TARGET_LOUDNESS = -24.0     # same K-weighted alpha-down level as Tik's synthesized packs
PEAK_CEILING = 0.944        # -0.5 dBFS


def db(x):
    return 10 ** (x / 20)


# ---------------------------------------------------------------------------- loudness (matches tiksynth)
_hp = butter(2, 120, btype="high", fs=SR, output="sos")
_shelf = butter(1, 1800, btype="high", fs=SR, output="sos")


def loudness(y):
    z = sosfilt(_hp, y)
    z = z + 0.6 * sosfilt(_shelf, z)
    w = z[: int(0.1 * SR)]
    return 10 * np.log10(np.sum(w * w) / (0.1 * SR) + 1e-20)


def centroid(y):
    sp = np.abs(np.fft.rfft(y, 8192)) ** 2
    f = np.fft.rfftfreq(8192, 1 / SR)
    return float(np.sum(sp * f) / (np.sum(sp) + 1e-20))


# ---------------------------------------------------------------------------- clip cleanup
def load_mono48(path):
    sr, x = wavfile.read(path)
    if x.dtype == np.int16:
        x = x.astype(np.float64) / 32768.0
    elif x.dtype == np.int32:
        x = x.astype(np.float64) / 2147483648.0
    else:
        x = x.astype(np.float64)
    if x.ndim == 2:
        l, r = x[:, 0], x[:, 1]
        corr = np.corrcoef(l, r)[0, 1] if np.std(l) > 0 and np.std(r) > 0 else 1.0
        # Dual-mono -> average. Different mics per channel -> keep the stronger (direct) one.
        x = (l + r) / 2 if corr > 0.9 else (l if np.mean(l * l) >= np.mean(r * r) else r)
    if sr != SR:
        g = np.gcd(sr, SR)
        x = resample_poly(x, SR // g, sr // g)
    return x


_dc = butter(1, 20, btype="high", fs=SR, output="sos")


def clean(x, max_ms=600):
    x = sosfilt(_dc, x)
    peak = np.max(np.abs(x)) or 1.0
    # start 2 ms before the main transient (first sample at >= -12 dB of peak)
    onset = int(np.argmax(np.abs(x) >= 0.25 * peak))
    start = max(0, onset - 96)
    y = x[start:].copy()
    pre = onset - start
    if pre > 1:
        y[:pre] *= 0.5 - 0.5 * np.cos(np.pi * np.arange(pre) / pre)
    # tail: drop only true silence (45 dB under the peak); the decay that sinks into the
    # recording's hiss is kept and faded out smoothly over the last third of the clip.
    hop = 96
    n = len(y) // hop
    if n > 4:
        e = np.array([20 * np.log10(np.sqrt(np.mean(y[k * hop:(k + 1) * hop] ** 2)) + 1e-9) for k in range(n)])
        above = np.nonzero(e > e.max() - 45)[0]
        end = min(len(y), (above[-1] + 3) * hop) if len(above) else len(y)
        y = y[:end]
    y = y[: int(max_ms / 1000 * SR)]
    fade = max(48, min(int(0.035 * SR), int(len(y) * 0.35)))
    y[-fade:] *= 0.5 + 0.5 * np.cos(np.pi * np.arange(fade) / fade)
    return y


def pitch(y, cents):
    rate = 2 ** (cents / 1200)
    n = int((len(y) - 1) / rate)
    pos = np.arange(n) * rate
    return np.interp(pos, np.arange(len(y)), y)


# ---------------------------------------------------------------------------- tikpack io
def read_tikpack(path):
    d = open(path, "rb").read()
    assert d[:4] == b"TIKP"
    _, hl = struct.unpack_from("<II", d, 4)
    header = json.loads(d[12:12 + hl])
    pcm = np.frombuffer(d[12 + hl:], dtype="<i2").astype(np.float64) / 32768.0
    clips = [(c["group"], c["phase"], pcm[c["offset"]:c["offset"] + c["length"]]) for c in header["clips"]]
    return header, clips


def write_tikpack(path, header, clips):
    pcm, meta, off = [], [], 0
    for group, phase, y in clips:
        q = np.clip(np.round(y * 32767.0), -32768, 32767).astype("<i2")
        meta.append({"group": group, "phase": phase, "offset": off, "length": int(len(q))})
        pcm.append(q)
        off += len(q)
    header = dict(header, clips=meta)
    hb = json.dumps(header, separators=(",", ":")).encode("utf-8")
    with open(path, "wb") as f:
        f.write(b"TIKP")
        f.write(struct.pack("<II", 1, len(hb)))
        f.write(hb)
        f.write(np.concatenate(pcm).tobytes())


def mapping():
    m = {}
    for group, codes in MAC_ROWS.items():
        for c in codes:
            m[str(c)] = group
    return m


def finish_pack(slug, name, color, summary, clips, mouse, out_dir):
    """Loudness-match, cap peaks, add mouse clicks, write."""
    alpha = [y for g, p, y in clips if g == "alpha" and p == "down"]
    gain = db(TARGET_LOUDNESS - float(np.median([loudness(y) for y in alpha])))
    # never push typical letters into clipping...
    alpha_peak = float(np.median([np.max(np.abs(y)) for y in alpha]))
    if alpha_peak * gain > db(-3):
        gain = db(-3) / alpha_peak
    # ...and tame individual outliers (a loud space bar) instead of turning the whole pack down
    def limit(y):
        y = y * gain
        pk = np.max(np.abs(y))
        return y * (PEAK_CEILING / pk) if pk > PEAK_CEILING else y
    clips = [(g, p, limit(y)) for g, p, y in clips] + mouse
    header = {"schemaVersion": 1, "id": f"com.tik.pack.rec.{slug}", "name": name, "author": "Tik",
              "description": summary, "version": "1.0.0", "sampleRate": SR, "format": "s16le", "gain": 1.0,
              "category": "recorded", "color": color, "mapping": mapping()}
    path = os.path.join(out_dir, f"rec-{slug}.tikpack")
    write_tikpack(path, header, clips)
    return path, clips


def describe(downs):
    c = np.median([centroid(y) for y in downs])
    length = np.median([len(y) for y in downs]) / SR * 1000
    tone = "deep" if c < 1500 else "warm" if c < 2800 else "bright" if c < 5000 else "crisp, high"
    body = "short and tight" if length < 45 else "snappy" if length < 80 else "full, ringing"
    return f"Recorded switch: {tone}, {body}."


# ---------------------------------------------------------------------------- styles
def build_style(src, folder, slug, name, color, mouse, out_dir):
    clips = []
    rows = {}
    enter = {}
    for scan in SCAN_TO_MAC:
        for phase in ("down", "up"):
            y = clean(load_mono48(os.path.join(src, folder, f"{scan}-{phase}.wav")))
            if scan in ROW_OF_SCAN:
                clips.append(("alpha", phase, y))
                rows.setdefault(ROW_OF_SCAN[scan], []).append((phase, y))
            elif scan == 28:
                clips.append(("enter", phase, y))
                enter[phase] = y
            elif scan == 57:
                clips.append(("space", phase, y))
            elif scan == 3675:
                clips.append(("modifier", phase, y))
    for row, items in rows.items():
        clips += [(row, p, y) for p, y in items]
    # Big stabilized keys borrow Enter's body, retuned so they don't sound identical.
    for phase in ("down", "up"):
        clips.append(("backspace", phase, pitch(enter[phase], 150)))
        clips.append(("wide", phase, pitch(enter[phase], 100)))
        clips.append(("wide", phase, pitch(enter[phase], 40)))
    downs = [y for g, p, y in clips if g == "alpha" and p == "down"]
    return finish_pack(slug, name, color, describe(downs), clips, mouse, out_dir)


def build_mechanical(mp3, mouse, out_dir, slicer_dir):
    sys.path.insert(0, slicer_dir)
    from slicer import find_hits  # noqa: E402
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "m.wav")
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", mp3, "-ac", "1", "-ar", str(SR), wav], check=True)
        x = load_mono48(wav)
    hits = [x[s:e] for s, e in find_hits(x)]
    feats = []
    for h in hits:
        pk = 20 * np.log10(np.max(np.abs(h)) + 1e-12)
        w = h[:960]
        ld = 10 * np.log10(np.mean(w * w) + 1e-12)
        feats.append((pk, ld, centroid(h)))
    downs = [clean(h, 300) for h, (pk, ld, c) in zip(hits, feats) if pk >= -10 and ld >= -27]
    ups = [clean(h, 200) for h, (pk, ld, c) in zip(hits, feats) if -26 <= pk < -10 and ld >= -38 and c < 4000]
    # the two deepest, longest presses play for the space bar
    order = sorted(range(len(downs)), key=lambda i: centroid(downs[i]) - len(downs[i]) / 10)
    space = [downs[i] for i in order[:2]]
    clips = [("alpha", "down", y) for y in downs] + [("alpha", "up", y) for y in ups]
    clips += [("space", "down", pitch(y, -120)) for y in space] + [("space", "up", pitch(y, -80)) for y in ups[:3]]
    summary = "Sliced from a real typing recording: bright, busy, mechanical."
    return finish_pack(MECH[0], MECH[1], MECH[2], summary, clips, mouse, out_dir), len(downs), len(ups)


def main():
    src, out_dir = sys.argv[1], sys.argv[2]
    synth = sys.argv[3] if len(sys.argv) > 3 else os.path.join(out_dir, "cream.tikpack")
    here = os.path.dirname(os.path.abspath(__file__))
    os.makedirs(out_dir, exist_ok=True)
    _, synth_clips = read_tikpack(synth)
    mouse = [(g, p, y) for g, p, y in synth_clips if g == "mouse"]
    for folder, slug, name, color in STYLES:
        if not os.path.isdir(os.path.join(src, folder)):
            print("skip", folder)
            continue
        path, clips = build_style(src, folder, slug, name, color, mouse, out_dir)
        print(f"{name:15s} {len(clips):3d} clips  {os.path.getsize(path)/1024:6.0f} KB  {path}")
    mp3 = os.path.join(src, "mechanical-keyboard.mp3")
    if os.path.exists(mp3):
        (path, clips), nd, nu = build_mechanical(mp3, mouse, out_dir, here)
        print(f"{'Mechanical':15s} {len(clips):3d} clips  {os.path.getsize(path)/1024:6.0f} KB  ({nd} presses, {nu} releases)  {path}")


if __name__ == "__main__":
    main()
