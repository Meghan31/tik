"""Reference implementation of Tik's SoundSlicer (ported 1:1 to Swift). Tested on simulated recordings."""
import numpy as np

SR = 48000
HOP = 96                 # 2 ms
WIN = 480                # 10 ms analysis window (long enough for a 100 Hz "thock")
MIN_GAP_FRAMES = 18      # 36 ms between onsets
RISE_DB = 9.0
TAIL_FRAMES = 10         # 20 ms below floor+6 dB ends a hit
MAX_HIT = int(1.0 * SR)
MIN_HIT = int(0.012 * SR)
PRE_ROLL = 48            # 1 ms


def frame_db(x):
    """Energy of a 10 ms window starting at each 2 ms hop (prefix sums: O(n))."""
    n = max(0, (len(x) - WIN) // HOP + 1)
    c = np.concatenate([[0.0], np.cumsum(x.astype(np.float64) ** 2)])
    out = np.empty(n)
    for k in range(n):
        a = k * HOP
        out[k] = 10 * np.log10((c[a + WIN] - c[a]) / WIN + 1e-12)
    return out


def percentile(values, p):
    s = sorted(values)
    if not s:
        return -120.0
    i = int((len(s) - 1) * p)
    return s[i]


def find_hits(x):
    """Returns list of (start, end) sample ranges."""
    e = frame_db(x)
    n = len(e)
    if n < 4:
        return [(0, len(x))]
    floor = percentile(list(e), 0.15)
    peak = max(e)
    if peak - floor < 15:
        return [(0, len(x))]
    thresh = max(floor + 12, peak - 40)
    onsets = []
    last = -10_000
    for k in range(n):
        if e[k] < thresh or k - last < MIN_GAP_FRAMES:
            continue
        prev = min(e[max(0, k - 8):k]) if k > 0 else floor
        if e[k] - prev >= RISE_DB:
            onsets.append(k)
            last = k
    if not onsets:
        return [(0, len(x))]
    # refine each onset to the first sample above 30% of the local peak
    starts = []
    for k in onsets:
        a = k * HOP
        b = min(len(x), k * HOP + WIN + 2 * HOP)
        local = np.max(np.abs(x[a:b])) if b > a else 0
        p = a
        while p < b and abs(x[p]) < 0.3 * local:
            p += 1
        starts.append(max(0, p - PRE_ROLL))
    hits = []
    for i, k in enumerate(onsets):
        st = starts[i]
        hard_end = starts[i + 1] if i + 1 < len(starts) else len(x)
        end = hard_end
        quiet = 0
        j = st // HOP + 5                      # start looking 10 ms after the onset
        while j < n and j * HOP < hard_end:
            if e[j] < floor + 6:
                quiet += 1
                if quiet >= TAIL_FRAMES:
                    end = (j - TAIL_FRAMES + 1) * HOP + WIN // 2
                    break
            else:
                quiet = 0
            j += 1
        end = min(end, hard_end, st + MAX_HIT, len(x))
        if end - st >= MIN_HIT:
            hits.append((st, end))
    return hits or [(0, len(x))]


def loud_db(seg):
    w = seg[: int(0.02 * SR)]
    return 10 * np.log10(np.mean(w * w) + 1e-12)


def slice_recording(x):
    """Returns (downs, ups) lists of float arrays."""
    hits = find_hits(x)
    clips = [x[s:e].copy() for s, e in hits]
    starts = [s for s, _ in hits]
    L = [loud_db(c) for c in clips]
    n = len(clips)
    pairs, singles = [], []
    i = 0
    while i < n:
        if i + 1 < n and (starts[i + 1] - starts[i]) <= 0.30 * SR and L[i + 1] <= L[i] - 2:
            pairs.append((i, i + 1))
            i += 2
        else:
            singles.append(i)
            i += 1
    if len(pairs) >= 2 and len(pairs) * 2 >= 0.6 * n:
        downs = [clips[a] for a, _ in pairs] + [clips[s] for s in singles]
        ups = [clips[b] for _, b in pairs]
    else:
        downs, ups = clips, []
    return downs, ups
