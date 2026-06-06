#!/usr/bin/env python3
# Deep MOV/MP4 fingerprint for diffing a growing recording (JustInMac) vs our AVAssetWriter output.
import struct, os, sys

p = sys.argv[1]
f = open(p, 'rb'); size = os.path.getsize(p)
CONT = {b'moov',b'trak',b'mdia',b'minf',b'stbl',b'edts',b'dinf',b'udta',b'mvex',b'moof',b'traf',b'tref',b'gmhd'}

def boxes(s, e):
    out=[]; o=s
    while o < e-8:
        f.seek(o); h=f.read(8)
        if len(h)<8: break
        sz,t = struct.unpack('>I4s',h); hs=8
        if sz==1: sz=struct.unpack('>Q',f.read(8))[0]; hs=16
        elif sz==0: sz=e-o
        out.append((t,o,sz,hs))
        if sz<=0: break
        o+=sz
    return out

def child(parent, name):
    for t,o,s,hs in boxes(parent[1]+parent[3], parent[1]+parent[2]):
        if t==name: return (t,o,s,hs)
    return None

def fullbox(o):
    f.seek(o+8); v=f.read(1)[0]; fl=struct.unpack('>I', b'\x00'+f.read(3))[0]; return v,fl

def u32(o): f.seek(o); return struct.unpack('>I',f.read(4))[0]
def read_at(o,n): f.seek(o); return f.read(n)

print(f"\n############### {os.path.basename(p)}  ({size} bytes) ###############")
top = boxes(0, size)
from collections import Counter
print("TOP counts:", dict(Counter(t.decode('latin1','replace') for t,_,_,_ in top)))
print("TOP order[:8]:", [t.decode('latin1','replace') for t,_,_,_ in top[:8]])

# ftyp
ft = next((b for b in top if b[0]==b'ftyp'), None)
if ft:
    d = read_at(ft[1]+8, ft[2]-8)
    major=d[0:4]; minor=struct.unpack('>I',d[4:8])[0]; compat=[d[i:i+4] for i in range(8,len(d),4)]
    print(f"ftyp: major={major} minor={minor} compat={compat}")

moov = next((b for b in top if b[0]==b'moov'), None)
if moov:
    mvhd = child(moov,b'mvhd')
    if mvhd:
        v,_ = fullbox(mvhd[1]); base=mvhd[1]+12
        if v==1: ts=u32(base+16); dur=struct.unpack('>Q',read_at(base+20,8))[0]; rate_o=base+28
        else: ts=u32(base+8); dur=u32(base+12); rate_o=base+16
        rate=struct.unpack('>i',read_at(rate_o,4))[0]; vol=struct.unpack('>h',read_at(rate_o+4,2))[0]
        nextid=u32(mvhd[1]+mvhd[2]-4)
        print(f"mvhd: ver={v} timescale={ts} duration={dur} rate=0x{rate&0xffffffff:08x} vol=0x{vol&0xffff:04x} nextTrackID={nextid}")
    for i,tk in enumerate(b for b in boxes(moov[1]+8,moov[1]+moov[2]) if b[0]==b'trak'):
        tkhd=child(tk,b'tkhd'); tkinfo=""
        if tkhd:
            v,fl=fullbox(tkhd[1]); base=tkhd[1]+12
            if v==1: tid=u32(base+16); dur=struct.unpack('>Q',read_at(base+24,8))[0]
            else: tid=u32(base+8); dur=u32(base+16)
            wo=tkhd[1]+tkhd[2]-8; w=u32(wo)>>16; hh=u32(wo+4)>>16
            tkinfo=f"id={tid} flags=0x{fl:06x} dur={dur} w={w} h={hh}"
        mdia=child(tk,b'mdia'); hdlr_name=""; htype=""; mts=mdur=0; lang=""
        if mdia:
            mdhd=child(mdia,b'mdhd')
            if mdhd:
                v,_=fullbox(mdhd[1]); base=mdhd[1]+12
                if v==1: mts=u32(base+16); mdur=struct.unpack('>Q',read_at(base+20,8))[0]; lo=base+28
                else: mts=u32(base+8); mdur=u32(base+12); lo=base+16
            hd=child(mdia,b'hdlr')
            if hd:
                htype=read_at(hd[1]+16,4).decode('latin1','replace')
                hdlr_name=read_at(hd[1]+32, hd[2]-32-1).split(b'\x00')[0].decode('latin1','replace')
        edts=child(tk,b'edts'); elst=""
        if edts:
            el=child(edts,b'elst')
            if el:
                v,_=fullbox(el[1]); cnt=u32(el[1]+12)
                ents=[]
                eo=el[1]+16
                for _ in range(min(cnt,3)):
                    if v==1: seg=struct.unpack('>Q',read_at(eo,8))[0]; mt=struct.unpack('>q',read_at(eo+8,8))[0]; eo+=20
                    else: seg=u32(eo); mt=struct.unpack('>i',read_at(eo+4,4))[0]; eo+=12
                    ents.append((seg,mt))
                elst=f"elst{ents}"
        tref=child(tk,b'tref'); trefs=""
        if tref:
            trefs="tref="+",".join(t.decode('latin1','replace') for t,_,_,_ in boxes(tref[1]+8,tref[1]+tref[2]))
        print(f"  trak#{i} {tkinfo} | hdlr={htype}({hdlr_name}) mdTimescale={mts} mdDur={mdur} | {elst} {trefs}")
    mvex=child(moov,b'mvex')
    if mvex:
        for t,o,s,hs in boxes(mvex[1]+8,mvex[1]+mvex[2]):
            if t==b'trex':
                tid=u32(o+12); dsi=u32(o+16); dsd=u32(o+20); dss=u32(o+24); dsf=u32(o+28)
                print(f"  trex: trackID={tid} defSampleDescIdx={dsi} defDur={dsd} defSize={dss} defFlags=0x{dsf:08x}")
            elif t==b'mehd':
                print(f"  mehd present")
    else:
        print("  mvex: ABSENT")

# moof: which track IDs appear per fragment, and counts
moofs=[b for b in top if b[0]==b'moof']
print(f"moof count={len(moofs)}")
for idx,mf in enumerate(moofs[:4]):
    tids=[]
    for tr in boxes(mf[1]+8,mf[1]+mf[2]):
        if tr[0]==b'traf':
            tf=child(tr,b'tfhd')
            if tf: tids.append(u32(tf[1]+12))
    has_tfdt = any(child(tr,b'tfdt') for tr in boxes(mf[1]+8,mf[1]+mf[2]) if tr[0]==b'traf')
    print(f"  moof#{idx}: traf trackIDs={tids} has_tfdt={has_tfdt}")
# per-track total traf count across all moofs
pertrack=Counter()
for mf in moofs:
    for tr in boxes(mf[1]+8,mf[1]+mf[2]):
        if tr[0]==b'traf':
            tf=child(tr,b'tfhd')
            if tf: pertrack[u32(tf[1]+12)]+=1
print("  traf-per-trackID across all moofs:", dict(pertrack))
