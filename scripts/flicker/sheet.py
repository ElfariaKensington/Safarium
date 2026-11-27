import sys
from PIL import Image, ImageDraw
d=sys.argv[1]; idx=[int(x) for x in sys.argv[2].split(',')]; out=sys.argv[3]
ts={int(l.split()[0]):float(l.split()[1]) for l in open(d+'/times.txt')}
ims=[Image.open(d+'/f_%04d.png'%i).convert('RGB') for i in idx]
w,h=ims[0].size; cols=min(4,len(ims)); rows=(len(ims)+cols-1)//cols
S=Image.new('RGB',(cols*w,rows*(h+16)),'gray')
for k,(i,im) in enumerate(zip(idx,ims)):
    x=(k%cols)*w; y=(k//cols)*(h+16); S.paste(im,(x,y+16)); ImageDraw.Draw(S).text((x+4,y+2),'#%d t=%.3f'%(i,ts[i]),fill='yellow')
S.save(out)
