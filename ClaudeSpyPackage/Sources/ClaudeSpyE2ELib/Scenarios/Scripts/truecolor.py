import sys,math,time,os
V=int(os.environ.get("V","0"))
def o(s):
 sys.stdout.buffer.write(s.encode());sys.stdout.buffer.flush()
E="\033";C=E+"["
def cup(r,c):o(f"{C}{r};{c}H")
def bg(r,g,b):return f"{C}48;2;{r};{g};{b}m"
PI=math.pi
CFG=[(50,5,2,3,30,0),(55,7,2,2,20,60),(25,3,3,3,40,120),(100,3,1,6,25,180),(20,4,4,3,15,240)]
TT=["Standard Gradients","Wide Warm Boxes","Small Cool Grid","Full-Width Bars","Dense Rainbow Grid"]
bw,bh,nc,nr,ms,cs=CFG[V]
nb=nc*nr
def grad(idx,t):
 ph=(idx*360/nb+cs)*PI/180
 return (int(128+127*math.sin(t*PI*2+ph)),int(128+127*math.sin(t*PI*2+ph+PI*2/3)),int(128+127*math.sin(t*PI*2+ph+PI*4/3)))
bx=[]
for ri in range(nr):
 for ci in range(nc):
  bx.append((3+ri*(bh+3),3+ci*(bw+3)))
o(f"{C}?25l{C}2J{C}H")
cup(1,3);o(f"{C}38;2;255;255;100m{TT[V]} (variant {V+1}/5){C}0m")
for i,(tr,tc) in enumerate(bx):
 cup(tr,tc);o(f"{C}38;2;180;180;180m#{i+1}{C}0m")
for fr in range(41):
 o(f"{C}?2026h")
 for i,(tr,tc) in enumerate(bx):
  for r in range(bh):
   cup(tr+1+r,tc);s=""
   for c in range(bw):
    t=((c+(0 if fr==40 else fr)*2)%bw)/bw
    t=(t+math.sin(r*.6+fr*.12)*.15)%1
    cr,cg,cb=grad(i,t);s+=bg(cr,cg,cb)+" "
   o(s+f"{C}0m")
 o(f"{C}?2026l")
 if fr<40:time.sleep(ms/1000)
y=3+nr*(bh+3)+1
cup(y,1);o(f"{C}?25h{C}0mDone.\n")
