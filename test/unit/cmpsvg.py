#!/usr/bin/env python3
"""Compare the SVG images Velox drew (DIR/NAME.W.argb: width.l,
height.l, ARGB pixels) with rsvg-convert's (test/unit/svg/NAME.W.png).
Edges are anti-aliased differently, so: the shapes (alpha >= 128, as
Velox shows them) may differ in a few pixels, and the colours where both
are opaque only a little.  Gradients are one colour in Velox: only
their shape is compared."""
import glob
import os
import struct
import sys

from PIL import Image

d = sys.argv[1] if len(sys.argv) > 1 else "build/svg"
ref_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "svg")
fail = 0
for out in sorted(glob.glob(os.path.join(d, "*.argb"))):
    name = os.path.basename(out)[:-5]
    data = open(out, "rb").read()
    w, h = struct.unpack(">II", data[:8])
    ref = Image.open(os.path.join(ref_dir, name + ".png")).convert("RGBA")
    if ref.size != (w, h):
        print("FAIL %s size %dx%d, rsvg %dx%d" % (name, w, h, ref.size[0], ref.size[1]))
        fail = 1
        continue
    rp = ref.tobytes()
    shape = 0       # pixels in either's shape
    differ = 0      # in one only
    cdiff = 0
    cn = 0
    for i in range(w * h):
        a, r, g, b = data[8 + 4 * i:12 + 4 * i]
        R, G, B, A = rp[4 * i:4 * i + 4]
        mine, theirs = a >= 128, A >= 128
        if mine or theirs:
            shape += 1
        if mine != theirs:
            differ += 1
        if a >= 250 and A >= 250:
            cdiff += max(abs(r - R), abs(g - G), abs(b - B))
            cn += 1
    edge = differ / max(shape, 1)
    col = cdiff / max(cn, 1)
    # (small ones: their edges are much of them)
    ok = edge <= 0.03 and (col <= (6 if w * h > 1024 else 12) or name.startswith("gradient"))
    print("%s %s %dx%d shape %.1f%% colour %.1f" % ("PASS" if ok else "FAIL", name, w, h, 100 * edge, col))
    fail |= not ok
sys.exit(fail)
