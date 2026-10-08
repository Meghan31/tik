"""Render all packs to .tikpack + demo audio + analysis."""
import os
import sys
import subprocess
import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, sosfilt

sys.path.insert(0, os.path.dirname(__file__))
import tiksynth as ts  # noqa: E402

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "out")
os.makedirs(OUT, exist_ok=True)
SR = ts.SR

# ---------------------------------------------------------------- key model (mirrors KeyMap.swift)
LAYOUT = {}
def row(y, items):
    for code, x in items:
        LAYOUT[code] = (x, y)
row(1.0, [(53, -.95), (122, -.80), (120, -.67), (99, -.53), (118, -.40), (96, -.27), (97, -.13), (98, 0.0),
          (100, .13), (101, .27), (109, .40), (103, .53), (111, .67)])
row(0.6, [(50, -.93), (18, -.80), (19, -.67), (20, -.53), (21, -.40), (23, -.27), (22, -.13), (26, 0.0), (28, .13),
          (25, .27), (29, .40), (27, .53), (24, .67), (51, .88)])
row(0.2, [(48, -.88), (12, -.73), (13, -.60), (14, -.47), (15, -.33), (17, -.20), (16, -.07), (32, .07), (34, .20),
          (31, .33), (35, .47), (33, .60), (30, .73), (42, .90)])
row(-0.2, [(57, -.86), (0, -.69), (1, -.56), (2, -.43), (3, -.29), (5, -.16), (4, -.03), (38, .10), (40, .23),
           (37, .37), (41, .50), (39, .63), (36, .85)])
row(-0.6, [(56, -.82), (6, -.62), (7, -.49), (8, -.36), (9, -.22), (11, -.09), (45, .04), (46, .17), (43, .30),
           (47, .44), (44, .57), (60, .80)])
row(-1.0, [(63, -.95), (59, -.83), (58, -.70), (55, -.55), (49, 0.0), (54, .50), (61, .65), (123, .75), (125, .85),
           (124, .95)])
LAYOUT[126] = (.85, -.8)

CLASS_OF = {49: "space", 36: "enter", 76: "enter", 51: "backspace", 48: "wide", 57: "wide", 56: "wide", 60: "wide",
            55: "modifier", 54: "modifier", 58: "modifier", 61: "modifier", 59: "modifier", 62: "modifier",
            63: "modifier", 53: "function", 123: "nav", 124: "nav", 125: "nav", 126: "nav"}

def key_offset_cents(code):
    # deterministic per-key personality (same hash as Swift)
    h = (code * 2654435761) & 0xFFFFFFFF
    u = (h >> 8) / float(1 << 24) * 2.0 - 1.0
    y = LAYOUT.get(code, (0, 0))[1]
    return u * 18.0 + y * 6.0

CHARS = {}
for ch, code in zip("asdfhgzxcvbqweryt123465=97-80]ou[ip", [0,1,2,3,4,5,6,7,8,9,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35]):
    CHARS[ch] = code
CHARS.update({"l": 37, "j": 38, "'": 39, "k": 40, ";": 41, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49})

# ---------------------------------------------------------------- typing script
def typing_events(rng):
    text = "Hello, Tik. The quick brown fox jumsp|||mps over the lazy dog.\n"
    ev = []  # (t, code, phase)
    t = 0.35
    for ch in text:
        if ch == "|":
            code = 51
        elif ch == "\n":
            code = 36
        else:
            code = CHARS.get(ch.lower())
            if code is None:
                continue
        hold = float(np.exp(rng.normal(np.log(0.085), 0.25)))
        if code in (49, 36, 51):
            hold *= 1.15
        if ch.isupper():
            ev.append((t - 0.07, 56, "down"))
            ev.append((t, code, "down"))
            ev.append((t + hold, code, "up"))
            ev.append((t + hold + 0.05, 56, "up"))
        else:
            ev.append((t, code, "down"))
            ev.append((t + hold, code, "up"))
        gap = float(np.exp(rng.normal(np.log(0.135), 0.33)))
        if ch in " .,":
            gap *= 1.25
        if ch == "|":
            gap = 0.17
        if ch == "p" and text[text.index("jumsp") + 4] == "p":
            pass
        t += gap
    t += 0.5
    # a shortcut: cmd+s
    ev += [(t, 55, "down"), (t + 0.09, 1, "down"), (t + 0.17, 1, "up"), (t + 0.24, 55, "up")]
    t += 0.7
    # two mouse clicks
    for k in range(2):
        ev += [(t, 1000, "down"), (t + 0.075, 1000, "up")]
        t += 0.32
    return sorted(ev), t + 0.6


class Bag:
    def __init__(self, n, rng):
        self.n, self.rng, self.order, self.i, self.last = n, rng, [], 0, -1
    def next(self):
        if self.i >= len(self.order):
            self.order = list(self.rng.permutation(self.n))
            if self.n > 1 and self.order[0] == self.last:
                self.order[0], self.order[-1] = self.order[-1], self.order[0]
            self.i = 0
        v = self.order[self.i]; self.i += 1; self.last = v
        return v


def soft_clip(x):
    a = np.abs(x)
    y = np.where(a > 0.8, np.sign(x) * (0.8 + 0.2 * np.tanh((a - 0.8) / 0.2)), x)
    return y


def render_demo(clips, scale, seed, volume=0.8, pitch_jitter=15.0, gain_jitter=1.0, width=0.35, character=0.5):
    rng = np.random.default_rng(seed)
    groups = {}
    for cls, phase, y in clips:
        groups.setdefault((cls, phase), []).append(y * scale)
    bags = {k: Bag(len(v), rng) for k, v in groups.items()}
    events, total = typing_events(np.random.default_rng(7))
    out = np.zeros((int(total * SR) + SR, 2))
    for t, code, phase in events:
        cls = "mouse" if code >= 1000 else CLASS_OF.get(code, "alpha")
        key = (cls, phase)
        clip = groups[key][bags[key].next()]
        cents = (0 if code >= 1000 else key_offset_cents(code) * character) + rng.uniform(-1, 1) * pitch_jitter
        rate = 2 ** (cents / 1200)
        g = volume * ts.db(rng.uniform(-1, 1) * gain_jitter)
        x = 0.0 if code >= 1000 else LAYOUT.get(code, (0, 0))[0]
        pan = x * width
        th = (pan + 1) * np.pi / 4
        gl, gr = np.cos(th) / np.cos(np.pi / 4), np.sin(th) / np.cos(np.pi / 4)
        n_out = int((len(clip) - 1) / rate)
        pos = np.arange(n_out) * rate
        i0 = pos.astype(int)
        fr = pos - i0
        s = clip[i0] + (clip[i0 + 1] - clip[i0]) * fr
        st = int(t * SR)
        out[st:st + n_out, 0] += s * g * gl
        out[st:st + n_out, 1] += s * g * gr
    return soft_clip(out)


def centroid(y):
    sp = np.abs(np.fft.rfft(y, 8192)) ** 2
    f = np.fft.rfftfreq(8192, 1 / SR)
    return float(np.sum(sp * f) / np.sum(sp))


def main():
    all_clips = {}
    for i, p in enumerate(ts.PACKS):
        all_clips[p["id"]] = ts.build_pack(p, seed=1000 + i)
    scale = ts.global_scale(all_clips)
    print(f"global scale {20*np.log10(scale):+.1f} dB")
    tour = []
    for p in ts.PACKS:
        clips = all_clips[p["id"]]
        n = ts.write_tikpack(os.path.join(OUT, p["id"] + ".tikpack"), p, clips, scale)
        size = os.path.getsize(os.path.join(OUT, p["id"] + ".tikpack"))
        ad = [y * scale for c, ph, y in clips if c == "alpha" and ph == "down"]
        au = [y * scale for c, ph, y in clips if c == "alpha" and ph == "up"]
        sp = [y * scale for c, ph, y in clips if c == "space" and ph == "down"]
        onset = max(np.argmax(np.abs(y) > 0.03 * np.max(np.abs(y))) for y in ad) / SR * 1000
        print(f"{p['name']:6s} clips={len(clips):3d} samples={n:7d} file={size/1e6:4.2f}MB "
              f"down: peak {20*np.log10(max(np.max(np.abs(y)) for y in ad)):+5.1f}dB "
              f"loud {np.mean([ts.loudness(y) for y in ad]):5.1f} "
              f"centroid {np.mean([centroid(y) for y in ad]):5.0f}Hz "
              f"len {np.mean([len(y) for y in ad])/SR*1000:4.0f}ms onset<= {onset:.2f}ms | "
              f"up loud {np.mean([ts.loudness(y) for y in au]):5.1f} centroid {np.mean([centroid(y) for y in au]):5.0f} | "
              f"space centroid {np.mean([centroid(y) for y in sp]):5.0f}")
        demo = render_demo(clips, scale, seed=42)
        wav = os.path.join(OUT, f"tik-demo-{p['id']}.wav")
        wavfile.write(wav, SR, (demo * 32767).astype(np.int16))
        tour.append(demo)
        tour.append(np.zeros((int(0.6 * SR), 2)))
    wavfile.write(os.path.join(OUT, "tik-demo-all.wav"), SR, (np.concatenate(tour) * 32767).astype(np.int16))


if __name__ == "__main__":
    main()
