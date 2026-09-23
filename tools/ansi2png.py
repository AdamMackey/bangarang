# Draws terminal output (24-bit and 256-colour SGR, bold) to a PNG, so the real script output can be looked at.
import sys, re
from PIL import Image, ImageDraw, ImageFont
lines=sys.stdin.read().rstrip('\n').split('\n')
reg=ImageFont.truetype('/System/Library/Fonts/SFNSMono.ttf',24)
bold=ImageFont.truetype('/System/Library/Fonts/SFNSMono.ttf',24)
try: bold.set_variation_by_name('Bold')
except Exception: pass
cw=reg.getlength('M'); lh=36
# Glyphs SF Mono lacks, drawn from Menlo as CoreText does for Terminal (measured for the hearts).
menlo=ImageFont.truetype('/System/Library/Fonts/Menlo.ttc',24)
FALLBACK=set('♥♡❤❥')
def c256(n):
    if n<16: return (200,200,200)
    if n<232:
        n-=16; lv=[0,95,135,175,215,255]; return (lv[n//36],lv[(n//6)%6],lv[n%6])
    g=8+(n-232)*10; return (g,g,g)
W=int(cw*max(len(re.sub(r'\x1b\[[0-9;]*m','',l)) for l in lines))+40
img=Image.new('RGB',(W,lh*len(lines)+20),(30,30,30)); d=ImageDraw.Draw(img)
for row,l in enumerate(lines):
    x=20; y=10+row*lh; fg=(160,160,160); b=False
    for tok in re.split(r'(\x1b\[[0-9;]*m)',l):
        m=re.match(r'\x1b\[([0-9;]*)m',tok)
        if m:
            ps=[int(p) for p in m.group(1).split(';') if p!=''] or [0]; i=0
            while i<len(ps):
                p=ps[i]
                if p==0: fg=(160,160,160); b=False
                elif p==1: b=True
                elif p==38 and ps[i+1]==2: fg=tuple(ps[i+2:i+5]); i+=4
                elif p==38 and ps[i+1]==5: fg=c256(ps[i+2]); i+=2
                i+=1
            continue
        for ch in tok:
            f=menlo if ch in FALLBACK else (bold if b else reg)
            d.text((x,y),ch,font=f,fill=fg); x+=cw
img.save(sys.argv[1])
