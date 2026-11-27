# usage: python3 motion.py <rec dir>  — per captured frame, the vertical content shift (in window points) of the page
# area, by best row alignment against the previous frame. Shows what actually reached the screen while scrolling.
import sys, glob, numpy as np
from PIL import Image
d = sys.argv[1]
ts = {int(l.split()[0]): float(l.split()[1]) for l in open(d + '/times.txt')}
fs = sorted(glob.glob(d + '/f_*.png'))
prev = None; out = []
for i, f in enumerate(fs):
    a = np.asarray(Image.open(f).convert('L'), dtype=np.float32)
    h, w = a.shape; scale = w / 1200.0           # window is 1200 pt wide
    band = a[int(h * 0.12):int(h * 0.95), int(w * 0.25):int(w * 0.75)]
    if prev is not None:
        best, bs = 1e9, 0
        n = band.shape[0]
        for s in range(-min(n - 20, int(400 * scale)), min(n - 20, int(400 * scale))):
            # s > 0: content moved up by s (scrolled down); s < 0: moved down.
            if s >= 0: diff = np.abs(band[:n - s] - prev[s:]).mean()
            else: diff = np.abs(band[-s:] - prev[:n + s]).mean()
            if diff < best - 1e-6 or (abs(diff - best) < 1e-6 and abs(s) < abs(bs)): best, bs = diff, s
        out.append((ts[i], round(bs / scale)))
    prev = band
moving = [o for o in out if o[1] != 0]
if moving:
    t0, t1 = moving[0][0], moving[-1][0]
    seg = [o for o in out if t0 <= o[0] <= t1]
    print('frames', len(seg), 'in', round((t1 - t0) * 1000), 'ms; stalls(0 while moving):', sum(1 for o in seg if o[1] == 0))
    print(' '.join(str(o[1]) for o in seg))
