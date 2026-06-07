#!/usr/bin/env python3
# Generate a DaVinci Resolve "growing file" sidecar (.X.mov) from a fragmented
# qt .mov written by AVAssetWriter (movieFragmentInterval) / RefRecorder.
#
# Recipe (reverse-engineered from RefRecorder, see FINDINGS.md §0):
#   sidecar = ftyp(iso5) + transformed(moov) + verbatim copy of every moof
#   moov transform, per video/audio/timecode track:
#     - drop the minf-level data-information `hdlr` box
#     - replace the `dref` entry (alis self-contained, empty) with an external
#       `url ` box: flags=0x000000, content = main file's basename (NUL-terminated? no — RefRecorder stores it WITHOUT trailing NUL, padded to box size)
#   every `moof` is copied byte-for-byte: AVAssetWriter already writes ABSOLUTE
#   `tfhd base_data_offset` values that point into the main file, so no rewrite.
#
# Usage:  python3 gen_sidecar.py <main.mov> [out_sidecar]
#         (default out = same dir, dot-prefixed basename)
import struct, os, sys

def boxes(data, s, e):
    out = []; o = s
    while o < e - 8:
        sz, t = struct.unpack('>I4s', data[o:o+8]); hs = 8
        if sz == 1:
            sz = struct.unpack('>Q', data[o+8:o+16])[0]; hs = 16
        elif sz == 0:
            sz = e - o
        out.append((t, o, sz, hs))
        if sz <= 0: break
        o += sz
    return out

def find(data, s, e, name):
    for b in boxes(data, s, e):
        if b[0] == name: return b
    return None

def box(t, payload):
    return struct.pack('>I4s', len(payload) + 8, t) + payload

def build_ftyp():
    # major iso5, minor 512, compat iso6 mp41
    return box(b'ftyp', b'iso5' + struct.pack('>I', 512) + b'iso6' + b'mp41')

def build_dref(basename_bytes):
    # url entry: version/flags = 0x00000000 (external), content = basename (no NUL),
    # padded so the box has the same length RefRecorder uses (40 bytes incl 8-byte header → 32 content).
    # RefRecorder: dref size 56 = fullbox(8: ver/flags+count? ) ... reproduce exactly:
    #   dref box = 8 hdr + 4 (ver/flags) + 4 (entry_count=1) + url_entry(40) = 56
    #   url_entry = 8 hdr + 4 (ver/flags=0) + content(28) = 40  -> content len 28
    content = basename_bytes
    url_payload = struct.pack('>I', 0) + content  # ver/flags=0 then string (no length prefix, fills box)
    url_box = box(b'url ', url_payload)
    dref_payload = struct.pack('>I', 0) + struct.pack('>I', 1) + url_box  # ver/flags, entry_count=1
    return box(b'dref', dref_payload)

def transform_minf(data, minf, basename_bytes):
    """Return new minf bytes: drop minf-level hdlr, swap dref->external url."""
    s, e = minf[1] + 8, minf[1] + minf[2]
    out = b''
    for t, o, sz, hs in boxes(data, s, e):
        if t == b'hdlr':
            continue  # drop the data-information handler
        if t == b'dinf':
            # rebuild dinf with new dref
            din_s, din_e = o + 8, o + sz
            din_out = b''
            for tt, oo, ssz, hhs in boxes(data, din_s, din_e):
                if tt == b'dref':
                    din_out += build_dref(basename_bytes)
                else:
                    din_out += data[oo:oo+ssz]
            out += box(b'dinf', din_out)
        else:
            out += data[o:o+sz]
    return box(b'minf', out)

def transform_container(data, parent, child_name, rebuild_fn):
    """Rebuild `parent` box, replacing its `child_name` child via rebuild_fn(childbox)."""
    s, e = parent[1] + 8, parent[1] + parent[2]
    out = b''
    for b in boxes(data, s, e):
        if b[0] == child_name:
            out += rebuild_fn(b)
        else:
            out += data[b[1]:b[1]+b[2]]
    return box(parent[0], out)

def transform_trak(data, trak, basename_bytes):
    def rebuild_mdia(mdia):
        return transform_container(data, mdia, b'minf',
            lambda minf: transform_minf(data, minf, basename_bytes))
    return transform_container(data, trak, b'mdia', rebuild_mdia)

def build_sidecar(main_path):
    data = open(main_path, 'rb').read()
    size = len(data)
    top = boxes(data, 0, size)
    moov = next(b for b in top if b[0] == b'moov')
    basename = os.path.basename(main_path).encode('utf-8')

    # rebuild moov: transform each trak, keep mvhd/meta/mvex verbatim
    moov_out = b''
    for t, o, sz, hs in boxes(data, moov[1]+8, moov[1]+moov[2]):
        if t == b'trak':
            moov_out += transform_trak(data, (t, o, sz, hs), basename)
        else:
            moov_out += data[o:o+sz]
    moov_box = box(b'moov', moov_out)

    out = build_ftyp() + moov_box
    # copy every moof verbatim
    nmoof = 0
    for t, o, sz, hs in top:
        if t == b'moof':
            out += data[o:o+sz]; nmoof += 1
    return out, nmoof

if __name__ == '__main__':
    main_path = sys.argv[1]
    if len(sys.argv) > 2:
        out_path = sys.argv[2]
    else:
        d = os.path.dirname(main_path); b = os.path.basename(main_path)
        out_path = os.path.join(d, '.' + b)
    side, nmoof = build_sidecar(main_path)
    open(out_path, 'wb').write(side)
    print(f"wrote {out_path}  ({len(side)} bytes, {nmoof} moof)")
