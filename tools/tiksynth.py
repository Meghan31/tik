"""
Tik sound-pack synthesizer.

Physically-motivated keyboard sounds, built from scratch (no recordings, no third-party assets):

  impact = sum of STAGES, each stage at its own delay:
      dense inharmonic modal bank (random modes inside designed formant bands)
    + decaying band-limited noise (the "plastic" texture that keeps it from sounding tonal)
    + short bright contact click
    + low body thump with a fast pitch drop (case / desk coupling)
  then: early desk reflections, DC highpass, 0.25 ms attack, tail trim + fade.

Key classes add size (lower/longer modes, more thump) and stabilizer rattle stages.
Every variant re-rolls modes, noise, press strength and brightness, so no two clips match.
"""
import json
import struct
import numpy as np
from scipy.signal import butter, sosfilt

SR = 48000


def db(x):
    return 10.0 ** (x / 20.0)


# ----------------------------------------------------------------------------- primitives

def modal(n, bands, rng, fscale, tscale, tilt):
    t = np.arange(n) / SR
    out = np.zeros(n)
    for fc, spread, tau, gain, count in bands:
        for _ in range(count):
            f = fc * fscale * np.exp(rng.uniform(-spread, spread))
            if f > SR * 0.44:
                continue
            ti = tau * tscale * np.exp(rng.normal(0.0, 0.15))
            g = gain * db(rng.normal(0.0, 2.0)) / np.sqrt(count)
            g *= (f / 1000.0) ** (0.18 * tilt)          # harder press -> brighter
            ph = rng.uniform(-0.25, 0.25)
            out += g * np.exp(-t / ti) * np.sin(2 * np.pi * f * t + ph)
    return out


def noise(n, rng, tau, lo, hi, gain, fscale, tilt):
    if gain <= 0:
        return np.zeros(n)
    t = np.arange(n) / SR
    x = rng.standard_normal(n) * np.exp(-t / tau)
    lo = max(20.0, lo * fscale)
    hi = min(SR * 0.45, hi * fscale * (1.0 + 0.08 * tilt))
    sos = butter(2, [lo, hi], btype="band", fs=SR, output="sos")
    y = sosfilt(sos, x)
    pk = np.max(np.abs(y)) or 1.0
    return gain * y / pk


def click(n, rng, tau, hp, gain):
    if gain <= 0:
        return np.zeros(n)
    t = np.arange(n) / SR
    x = rng.standard_normal(n) * np.exp(-t / tau)
    sos = butter(2, min(hp, SR * 0.4), btype="high", fs=SR, output="sos")
    y = sosfilt(sos, x)
    pk = np.max(np.abs(y)) or 1.0
    return gain * y / pk


def thump(n, f0, tau, gain, rng):
    if gain <= 0:
        return np.zeros(n)
    t = np.arange(n) / SR
    f0 = f0 * np.exp(rng.normal(0, 0.04))
    f = f0 * (1.0 + 0.55 * np.exp(-t / 0.004))
    phase = 2 * np.pi * np.cumsum(f) / SR
    env = np.exp(-t / tau) * (1.0 - np.exp(-t / 0.0007))
    return gain * np.sin(phase) * env


def render_stage(n, st, rng, fscale, tscale, tilt, thump_mul):
    y = modal(n, st.get("bands", []), rng, fscale, tscale, tilt)
    pk = np.max(np.abs(y)) or 1.0
    y = y / pk * st.get("modal_gain", 1.0)
    if "noise" in st:
        tau, lo, hi, g = st["noise"]
        y += noise(n, rng, tau * tscale, lo, hi, g, fscale, tilt)
    if "click" in st:
        tau, hp, g = st["click"]
        y += click(n, rng, tau, hp, g * db(0.8 * tilt))
    if "thump" in st:
        f0, tau, g = st["thump"]
        y += thump(n, max(115.0, f0 * fscale), tau * tscale, g * thump_mul, rng)
    return y


def room(y, amount):
    if amount <= 0:
        return y
    sos = butter(1, 3000, btype="low", fs=SR, output="sos")
    lp = sosfilt(sos, y)
    out = y.copy()
    for ms, g in ((1.1, -13.0), (2.7, -17.0), (4.9, -21.0), (8.3, -26.0)):
        d = int(ms * SR / 1000)
        out[d:] += lp[:-d] * db(g) * amount * 4.0
    return out


def finish(y, max_dur):
    sos = butter(2, 40, btype="high", fs=SR, output="sos")
    y = sosfilt(sos, y)
    # attack: 0.25 ms raised cosine (no leading silence -> no "asset latency")
    a = int(0.00025 * SR)
    y[:a] *= 0.5 - 0.5 * np.cos(np.pi * np.arange(a) / a)
    # trim tail where it drops below -54 dB re peak
    pk = np.max(np.abs(y)) or 1.0
    env = np.abs(y) / pk
    above = np.nonzero(env > db(-54))[0]
    end = min(len(y), int(max_dur * SR), (above[-1] + int(0.002 * SR)) if len(above) else len(y))
    y = y[:end]
    fl = max(int(0.004 * SR), min(int(0.012 * SR), int(len(y) * 0.3)))
    y[-fl:] *= 0.5 + 0.5 * np.cos(np.pi * np.arange(fl) / fl)
    return y


# ----------------------------------------------------------------------------- loudness

_KW = None


def loudness(y):
    """~K-weighted energy over the first 100 ms, in dB. Good enough to balance transients."""
    global _KW
    if _KW is None:
        hp = butter(2, 120, btype="high", fs=SR, output="sos")
        shelf = butter(1, 1800, btype="high", fs=SR, output="sos")
        _KW = (hp, shelf)
    hp, shelf = _KW
    z = sosfilt(hp, y)
    z = z + 0.6 * sosfilt(shelf, z)
    w = z[: int(0.1 * SR)]
    return 10 * np.log10(np.sum(w * w) / (0.1 * SR) + 1e-20)


# ----------------------------------------------------------------------------- classes

CLASSES = {
    #             fscale tscale thump  level  dur   stab  variants
    "alpha":     (1.00, 1.00, 1.0, 0.0, 1.00, 0.0, 12),
    "modifier":  (0.95, 1.05, 1.1, -0.8, 1.00, 0.0, 5),
    "function":  (1.07, 0.90, 0.8, -1.2, 0.90, 0.0, 5),
    "nav":       (1.05, 0.90, 0.8, -1.8, 0.90, 0.0, 5),
    "wide":      (0.90, 1.15, 1.3, 0.6, 1.15, 0.55, 5),
    "backspace": (0.88, 1.20, 1.4, 0.8, 1.20, 0.75, 5),
    "enter":     (0.86, 1.25, 1.5, 1.2, 1.25, 0.85, 5),
    "space":     (0.74, 1.50, 1.7, 1.8, 1.55, 1.00, 6),
}

STAB_STAGES = [
    # (delay range s, stage, base gain dB)
    ((0.0020, 0.0045), {"bands": [(1700, 0.25, 0.004, 1.0, 3), (3300, 0.25, 0.003, 0.6, 3)],
                        "noise": (0.0015, 1000, 7000, 0.7)}, -13.0),
    ((0.0060, 0.0110), {"bands": [(2900, 0.20, 0.0025, 1.0, 3)],
                        "noise": (0.0010, 1500, 9000, 0.5)}, -18.0),
]

MOUSE = {
    "down": {"bands": [(2800, 0.10, 0.0025, 1.0, 3), (4500, 0.10, 0.0020, 0.8, 3), (7000, 0.15, 0.0015, 0.4, 2)],
             "noise": (0.0008, 2000, 12000, 0.6), "click": (0.0002, 5000, 0.4), "dur": 0.045},
    "up": {"bands": [(3100, 0.10, 0.0020, 1.0, 3), (5000, 0.10, 0.0016, 0.7, 3)],
           "noise": (0.0007, 2500, 12000, 0.6), "click": (0.0002, 5000, 0.3), "dur": 0.035},
}


def impact(recipe, cls, rng, stab_db, is_up):
    fs, ts, thm, _, durm, stab, _ = CLASSES[cls]
    gfs = fs * np.exp(rng.normal(0, 0.018))
    tilt = rng.normal(0, 1.0)
    dur = recipe["dur"] * durm
    n = int((dur + 0.02) * SR)
    y = np.zeros(n)
    for st in recipe["stages"]:
        delay = st.get("delay", 0.0)
        if isinstance(delay, tuple):
            delay = rng.uniform(*delay)
        d = int(delay * SR)
        part = render_stage(n - d, st, rng, gfs, ts, tilt, thm)
        y[d:] += part * db(st.get("gain", 0.0))
    if stab > 0 and stab_db > -40:
        for (lo, hi), st, g in STAB_STAGES:
            d = int(rng.uniform(lo, hi) * (0.7 if is_up else 1.0) * SR)
            part = render_stage(n - d, st, rng, 1.0, 1.0, tilt, 0.0)
            y[d:] += part * db(g + stab_db + 6.0 * (stab - 1.0) + rng.normal(0, 1.5))
    y = room(y, recipe.get("room", 0.0))
    return finish(y, dur + 0.02)


def mouse_clip(phase, rng, tilt_hz):
    r = MOUSE[phase]
    n = int((r["dur"] + 0.01) * SR)
    fs = tilt_hz * np.exp(rng.normal(0, 0.03))
    y = render_stage(n, r, rng, fs, 1.0, rng.normal(0, 0.7), 0.0)
    return finish(y, r["dur"] + 0.01)


# ----------------------------------------------------------------------------- packs

def pack(id_, name, desc, down, up, stab_db, up_level, level, mouse_tilt, room_amt):
    down = dict(down, room=room_amt)
    up = dict(up, room=room_amt * 0.8)
    return dict(id=id_, name=name, desc=desc, down=down, up=up, stab_db=stab_db,
                up_level=up_level, level=level, mouse_tilt=mouse_tilt)


PACKS = [
    pack("cream", "Cream", "Smooth, rounded and softly damped. The everyday default.",
         down={"dur": 0.15, "stages": [{
             "bands": [(470, 0.18, 0.014, 1.0, 4), (860, 0.15, 0.010, 0.85, 4), (1500, 0.18, 0.006, 0.5, 5),
                       (2600, 0.20, 0.0035, 0.25, 5), (4300, 0.25, 0.002, 0.09, 4)],
             "noise": (0.0035, 400, 4500, 0.65), "click": (0.0006, 2500, 0.22), "thump": (190, 0.012, 0.28)}]},
         up={"dur": 0.09, "stages": [{
             "bands": [(750, 0.20, 0.007, 1.0, 4), (1350, 0.20, 0.005, 0.8, 4), (2400, 0.20, 0.003, 0.45, 4),
                       (4000, 0.25, 0.0018, 0.15, 3)],
             "noise": (0.0020, 700, 5500, 0.6), "click": (0.0004, 3000, 0.18), "thump": (280, 0.006, 0.12)}]},
         stab_db=-6, up_level=-9.0, level=0.0, mouse_tilt=1.0, room_amt=0.15),

    pack("deep", "Deep", "Low, heavy thock. Thick caps on a dense, dampened board.",
         down={"dur": 0.20, "stages": [{
             "bands": [(330, 0.18, 0.019, 1.0, 4), (600, 0.15, 0.014, 0.9, 4), (1050, 0.15, 0.009, 0.55, 4),
                       (1800, 0.18, 0.005, 0.25, 4), (3000, 0.20, 0.003, 0.08, 3)],
             "noise": (0.0040, 250, 3000, 0.6), "click": (0.0005, 2500, 0.10), "thump": (150, 0.018, 0.42)}]},
         up={"dur": 0.11, "stages": [{
             "bands": [(520, 0.20, 0.009, 1.0, 4), (950, 0.20, 0.006, 0.7, 4), (1700, 0.20, 0.004, 0.35, 4)],
             "noise": (0.0025, 400, 4000, 0.5), "click": (0.0004, 3000, 0.10), "thump": (230, 0.008, 0.15)}]},
         stab_db=-7, up_level=-10.0, level=0.5, mouse_tilt=0.85, room_amt=0.2),

    pack("crisp", "Crisp", "Bright and clacky, with a faint metal-plate ring.",
         down={"dur": 0.13, "stages": [{
             "bands": [(900, 0.15, 0.006, 0.55, 4), (1800, 0.12, 0.007, 1.0, 5), (3000, 0.12, 0.005, 0.8, 5),
                       (4600, 0.15, 0.0035, 0.5, 4), (7000, 0.20, 0.0025, 0.25, 3), (2650, 0.0, 0.022, 0.09, 1)],
             "noise": (0.0025, 1000, 9000, 0.65), "click": (0.0004, 3500, 0.40), "thump": (230, 0.010, 0.20)}]},
         up={"dur": 0.08, "stages": [{
             "bands": [(1600, 0.15, 0.005, 0.7, 4), (2800, 0.15, 0.004, 1.0, 4), (4500, 0.15, 0.003, 0.6, 4),
                       (7000, 0.20, 0.002, 0.3, 3)],
             "noise": (0.0015, 1500, 10000, 0.6), "click": (0.0003, 4000, 0.35), "thump": (300, 0.006, 0.05)}]},
         stab_db=0, up_level=-8.0, level=-0.5, mouse_tilt=1.15, room_amt=0.12),

    pack("click", "Click", "A crisp click on the way down and back up, like a clicky switch.",
         down={"dur": 0.14, "stages": [
             {"bands": [(3600, 0.10, 0.004, 1.0, 4), (5200, 0.10, 0.003, 0.8, 4), (7500, 0.12, 0.002, 0.4, 3)],
              "noise": (0.0012, 2500, 11000, 0.5), "click": (0.0003, 4000, 0.5)},
             {"delay": (0.0045, 0.0075), "gain": -3.0,
              "bands": [(1000, 0.15, 0.006, 0.7, 4), (1800, 0.12, 0.005, 1.0, 4), (2800, 0.12, 0.004, 0.6, 4)],
              "noise": (0.0020, 800, 6000, 0.5), "thump": (220, 0.010, 0.25)}]},
         up={"dur": 0.10, "stages": [
             {"bands": [(3900, 0.10, 0.0035, 1.0, 4), (5600, 0.10, 0.0025, 0.7, 3)],
              "noise": (0.0010, 3000, 12000, 0.5), "click": (0.0003, 4500, 0.45)},
             {"delay": (0.0025, 0.0040), "gain": -5.0,
              "bands": [(1500, 0.15, 0.004, 1.0, 4), (2600, 0.15, 0.003, 0.6, 3)],
              "noise": (0.0015, 1000, 7000, 0.5)}]},
         stab_db=-2, up_level=-5.0, level=-1.0, mouse_tilt=1.1, room_amt=0.12),

    pack("soft", "Soft", "Quiet and muted, for late nights and shared rooms.",
         down={"dur": 0.07, "stages": [{
             "bands": [(700, 0.20, 0.004, 1.0, 4), (1300, 0.20, 0.003, 0.7, 4), (2300, 0.20, 0.002, 0.35, 4)],
             "noise": (0.0018, 400, 4000, 0.7), "click": (0.0003, 3000, 0.08), "thump": (200, 0.006, 0.25)}]},
         up={"dur": 0.05, "stages": [{
             "bands": [(1100, 0.20, 0.003, 1.0, 3), (2000, 0.20, 0.002, 0.6, 3)],
             "noise": (0.0012, 800, 5000, 0.7)}]},
         stab_db=-12, up_level=-12.0, level=-5.0, mouse_tilt=0.9, room_amt=0.06),

    pack("retro", "Retro", "Loud, springy and metallic, in the spirit of old office keyboards.",
         down={"dur": 0.18, "stages": [
             {"bands": [(1200, 0.15, 0.008, 0.8, 4), (2100, 0.10, 0.012, 1.0, 4), (3300, 0.10, 0.009, 0.7, 4),
                        (5000, 0.15, 0.005, 0.4, 3),
                        (2300, 0.008, 0.045, 0.16, 2), (4550, 0.008, 0.032, 0.07, 1), (1150, 0.0, 0.040, 0.05, 1)],
              "noise": (0.0030, 800, 9000, 0.7), "click": (0.0004, 3000, 0.45), "thump": (260, 0.012, 0.35)},
             {"delay": (0.0020, 0.0032), "gain": -10.0,
              "bands": [(600, 0.10, 0.020, 1.0, 3)], "noise": (0.002, 300, 2000, 0.4)}]},
         up={"dur": 0.14, "stages": [{
             "bands": [(1800, 0.12, 0.006, 1.0, 4), (3000, 0.12, 0.005, 0.8, 4), (2300, 0.008, 0.030, 0.10, 1)],
             "noise": (0.0020, 1000, 8000, 0.6), "click": (0.0003, 3500, 0.3)}]},
         stab_db=2, up_level=-7.0, level=0.0, mouse_tilt=1.0, room_amt=0.25),
]

GROUP_ORDER = ["alpha", "modifier", "function", "nav", "wide", "backspace", "enter", "space", "mouse"]
REF_LOUDNESS = -21.0   # target K-energy of the average alpha down, before pack level offset


def build_pack(p, seed):
    rng = np.random.default_rng(seed)
    clips = []   # (group, phase, samples)
    for cls in GROUP_ORDER[:-1]:
        nvar = CLASSES[cls][6]
        for i in range(nvar):
            d = impact(p["down"], cls, rng, p["stab_db"], False)
            u = impact(p["up"], cls, rng, p["stab_db"], True)
            clips.append([cls, "down", d])
            clips.append([cls, "up", u])
    for i in range(5):
        clips.append(["mouse", "down", mouse_clip("down", rng, p["mouse_tilt"])])
        clips.append(["mouse", "up", mouse_clip("up", rng, p["mouse_tilt"])])

    # --- loudness balance: per-clip normalize to (class level + phase level + variant jitter)
    for c in clips:
        cls, phase, y = c
        if cls == "mouse":
            target = REF_LOUDNESS - 9.0 + (-4.0 if phase == "up" else 0.0)
        else:
            target = REF_LOUDNESS + CLASSES[cls][3] + (p["up_level"] if phase == "up" else 0.0)
        target += p["level"] + rng.normal(0, 0.6)
        c[2] = y * db(target - loudness(y))
    return clips


def global_scale(all_packs, ceiling_db=-1.0):
    peak = max(np.max(np.abs(y)) for clips in all_packs.values() for _, _, y in clips)
    return db(ceiling_db) / peak


def write_tikpack(path, p, clips, scale):
    pcm = []
    meta = []
    off = 0
    for cls, phase, y in clips:
        q = np.clip(np.round(y * scale * 32767.0), -32768, 32767).astype("<i2")
        meta.append({"group": cls, "phase": phase, "offset": off, "length": int(len(q))})
        pcm.append(q)
        off += len(q)
    header = {
        "schemaVersion": 1, "id": "com.tik.pack." + p["id"], "name": p["name"], "author": "Tik",
        "description": p["desc"], "version": "1.0.0", "sampleRate": SR, "format": "s16le",
        "gain": 1.0, "clips": meta,
    }
    hb = json.dumps(header, separators=(",", ":")).encode("utf-8")
    with open(path, "wb") as f:
        f.write(b"TIKP")
        f.write(struct.pack("<II", 1, len(hb)))
        f.write(hb)
        f.write(np.concatenate(pcm).tobytes())
    return off
