import numpy as np, sys
sys.path.insert(0,'.')
import tiksynth as ts
from slicer import slice_recording, SR
rng = np.random.default_rng(3)
packs = {p['id']: ts.build_pack(p, seed=1000+i) for i,p in enumerate(ts.PACKS)}
def clips(pid, g, ph): return [y for c,h,y in packs[pid] if c==g and h==ph]
def place(buf, y, t, gain=1.0):
    s=int(t*SR); buf[s:s+len(y)] += y[:len(buf)-s]*gain
def noise(n, db):
    hum = 0.3*np.sin(2*np.pi*60*np.arange(n)/SR)
    return (rng.standard_normal(n)*0.7 + hum) * ts.db(db)
bad = 0
def report(name, x, exp_d, exp_u):
    global bad
    d,u = slice_recording(x)
    ok = (len(d),len(u)) == (exp_d,exp_u)
    bad += not ok
    print(f"{'OK ' if ok else 'BAD'} {name:42s} downs {len(d):2d}/{exp_d}  ups {len(u):2d}/{exp_u}  "
          f"down {np.mean([len(c) for c in d])/SR*1000:4.0f}ms  up {np.mean([len(c) for c in u])/SR*1000 if u else 0:4.0f}ms")
for pid in ['cream','deep','click','soft','retro']:
    x = noise(int(1.2*SR), -62); place(x, clips(pid,'alpha','down')[0], 0.2, 1.0); report(f"single hit {pid}", x, 1, 0)
    x = noise(int(1.2*SR), -62); place(x, clips(pid,'space','down')[0], 0.2, 1.0); report(f"single space hit {pid}", x, 1, 0)
for pid in ['cream','deep','crisp','click','soft','retro']:
    for g in ['space','alpha','enter']:
        for nd in [-62, -45]:
            x = noise(int(9*SR), nd); t = 0.3
            vs = len(clips(pid,g,'down'))
            for k in range(10):
                gg = ts.db(rng.uniform(-3,3))
                place(x, clips(pid,g,'down')[k%vs], t, gg)
                place(x, clips(pid,g,'up')[k%vs], t + rng.uniform(0.09,0.16), gg)
                t += rng.uniform(0.6,0.85)
            report(f"10 {g} presses {pid} noise {nd}dB", x, 10, 10)
for pid in ['cream','deep','click']:
    x = noise(int(6*SR), -55); t=0.2
    for k in range(12):
        place(x, clips(pid,'alpha','down')[k%12], t); t += rng.uniform(0.3,0.45)
    report(f"12 hits, no releases {pid}", x, 12, 0)
x = noise(int(4*SR), -55); t=0.2
for k in range(8):
    place(x, clips('cream','mouse','down')[k%5], t); place(x, clips('cream','mouse','up')[k%5], t+0.08); t+=0.4
report("8 mouse clicks", x, 8, 8)
x = noise(int(4*SR), -55); t=0.2
for k in range(20):
    place(x, clips('cream','alpha','down')[k%12], t); place(x, clips('cream','alpha','up')[k%12], t+0.085); t+=0.13
d,u = slice_recording(x); print("fast burst 20 keys (40 hits): downs", len(d), "ups", len(u))
x = noise(int(2*SR), -50); d,u = slice_recording(x); print("pure noise: downs", len(d), "ups", len(u), "len", len(d[0])/SR)
print("BAD:", bad)
