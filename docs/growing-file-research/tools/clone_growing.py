#!/usr/bin/env python3
# Isolation test for DaVinci Resolve growing-file detection (FINDINGS.md §0.2).
#
# While a reference recorder is writing a LIVE growing file (REC overlay confirmed
# in Resolve), this clones its main byte-for-byte into a new file that grows in
# lockstep, and regenerates our sidecar (.clone) for it via gen_sidecar.
#
#   Clone shows REC overlay  -> our sidecar is fine; problem is our encoder's MAIN.
#   Clone does NOT (real does) -> trigger is NOT the file bytes (runtime/external).
#
# It only ever appends COMPLETE top-level boxes, so the clone is always a valid
# growing fragmented movie and its sidecar offsets always resolve.
#
# Usage: python3 clone_growing.py <source_main.mov> <dest_clone.mov> [seconds]
import struct, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_sidecar

def complete_boxes_end(path):
    """Return byte offset up to which all top-level boxes are fully written."""
    size = os.path.getsize(path)
    f = open(path, 'rb'); o = 0; end = 0
    try:
        while o + 8 <= size:
            f.seek(o); h = f.read(8)
            if len(h) < 8: break
            sz, t = struct.unpack('>I4s', h); hs = 8
            if sz == 1:
                f.seek(o); h = f.read(16)
                if len(h) < 16: break
                sz = struct.unpack('>Q', h[8:16])[0]
            if sz <= 0: break
            if o + sz > size: break          # box not fully flushed yet
            end = o + sz; o += sz
    finally:
        f.close()
    return end

def main():
    src = sys.argv[1]; dst = sys.argv[2]
    dur = float(sys.argv[3]) if len(sys.argv) > 3 else 600
    side = os.path.join(os.path.dirname(dst), '.' + os.path.basename(dst))
    for p in (dst, side):
        try: os.remove(p)
        except FileNotFoundError: pass
    copied = 0
    t0 = time.time()
    out = open(dst, 'ab')
    print(f"cloning {src} -> {dst}  (+ sidecar {side})")
    while time.time() - t0 < dur:
        end = complete_boxes_end(src)
        if end > copied:
            with open(src, 'rb') as f:
                f.seek(copied); chunk = f.read(end - copied)
            out.write(chunk); out.flush(); os.fsync(out.fileno())
            copied = end
            sidebytes, nmoof = gen_sidecar.build_sidecar(dst)
            tmp = side + '.tmp'
            with open(tmp, 'wb') as sf:
                sf.write(sidebytes); sf.flush(); os.fsync(sf.fileno())
            os.replace(tmp, side)
            print(f"  clone={copied} bytes  sidecar moofs={nmoof}", end='\r', flush=True)
        time.sleep(0.5)
    out.close()
    print(f"\ndone: clone {copied} bytes")

if __name__ == '__main__':
    main()
