import sys,glob,numpy as np
from PIL import Image
d=sys.argv[1]
ts={int(l.split()[0]):float(l.split()[1]) for l in open(d+'/times.txt')}
fs=sorted(glob.glob(d+'/f_*.png'))
prev=None; rows=[]
for i,f in enumerate(fs):
    a=np.asarray(Image.open(f).convert('L'),dtype=np.float32)
    h=a.shape[0]; tb=int(h*48/800)
    top=a[:tb].mean(); web=a[tb:].mean(); sd=a[tb:].std()
    diff=0 if prev is None else np.abs(a-prev).mean()
    rows.append((i,ts[i],top,web,diff,sd)); prev=a
for r in rows:
    if r[4]>1.0 or r[0]==0: print("%4d t=%.3f top=%6.1f web=%6.1f diff=%5.1f sd=%5.1f"%r)
print('n',len(rows))
