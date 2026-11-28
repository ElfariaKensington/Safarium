# Usage: python3 scripts/flicker/blank.py <wrec-dir>
# Measures main-column blank/checkerboard frames (mean > 250, std < 6.5) and total blank duration in ms.
import sys, glob
import numpy as np
from PIL import Image

d = sys.argv[1]
ts = {int(l.split()[0]): float(l.split()[1]) for l in open(d + '/times.txt') if l.strip()}
fs = sorted(glob.glob(d + '/f_*.png'))

blank_frames = []
rows = []
prev = None
for i, f in enumerate(fs):
    im = Image.open(f).convert('L')
    a = np.asarray(im, dtype=np.float32)
    h, w = a.shape
    feed = a[int(h * 0.24):int(h * 0.92), int(w * 0.24):int(w * 0.72)]
    mean = float(feed.mean())
    sd = float(feed.std())
    diff = 0.0 if prev is None else float(np.abs(feed - prev).mean())
    prev = feed
    t = ts.get(i, i / 120.0)
    is_blank = (mean > 250.0 and sd < 6.5)
    if is_blank:
        blank_frames.append((i, t, mean, sd))
    rows.append((i, t, mean, sd, diff, is_blank))

total_blank_ms = 0.0
for idx in range(len(rows)):
    if rows[idx][5]:
        dt = (rows[idx + 1][1] - rows[idx][1]) if idx + 1 < len(rows) else (1.0 / 120.0)
        total_blank_ms += dt * 1000.0

print(f"total_frames={len(rows)} blank_frames={len(blank_frames)} blank_ms={total_blank_ms:.1f}")
for r in rows:
    if r[5] or r[4] > 2.5 or r[0] in (0, len(rows) - 1):
        flag = "BLANK" if r[5] else "     "
        print(f"{r[0]:4d} t={r[1]:6.3f}s mean={r[2]:5.1f} sd={r[3]:5.1f} diff={r[4]:5.1f} {flag}")
