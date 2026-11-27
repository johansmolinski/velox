#!/usr/bin/env python3
"""Compare what Velox decoded (DIR/NAME.argb: width.l, height.l, ARGB
pixels, big-endian) with PIL's decoding of DIR/NAME.  Lossless formats
must match exactly; lossy ones (JPEG, lossy WebP) within a tolerance.
An animated GIF's frames after the first (NAME.argb.fN) are compared
with PIL's frames, composited as it does."""
import glob
import os
import struct
import sys

from PIL import Image

d = sys.argv[1] if len(sys.argv) > 1 else "build/img"
fail = 0
for out in sorted(glob.glob(os.path.join(d, "*.argb"))):
    src = out[:-5]
    scale = 1
    if src[-3:-1] == ".s":
        scale = int(src[-1])
        src = src[:-3]
    name = os.path.basename(src)
    data = open(out, "rb").read()
    w, h = struct.unpack(">II", data[:8])
    if src.endswith((".jpg", ".jpeg")) and not os.path.basename(src).startswith(("cut", "bad")):
        # libjpeg itself, with the simple upsampling Velox uses (PIL's
        # default smooths 2x chroma); scaled: its reduced inverse DCTs
        import io
        import subprocess
        args = ["djpeg", "-nosmooth", "-ppm"]
        if scale > 1:
            args[1:1] = ["-scale", "1/%d" % scale]
        ref = Image.open(io.BytesIO(subprocess.run(args + [src], capture_output=True, check=True).stdout))
    else:
        ref = Image.open(src)
    ref.seek(0)
    if ref.mode in ("I;16", "I;16B", "I"):
        # 16-bit grey: PNG means the high byte (PIL would clip)
        ref = ref.point(lambda v: v / 256).convert("L")
    ref = ref.convert("RGBA")
    if ref.size != (w, h):
        # a scaled decode: compare with PIL's own scaling
        ref = ref.resize((w, h), Image.BOX)
    rp = ref.tobytes()
    lossy = name.endswith((".jpg", ".jpeg")) or name.startswith("wy")
    diff = 0
    worst = 0
    n = 0
    for i in range(w * h):
        a, r, g, b = data[8 + 4 * i:12 + 4 * i]
        R, G, B, A = rp[4 * i:4 * i + 4]
        if A == 0 and a == 0:
            continue
        e = max(abs(r - R), abs(g - G), abs(b - B), abs(a - A))
        diff += e
        worst = max(worst, e)
        n += 1
    mean = diff / max(n, 1)
    ok = (mean <= 3.0 and worst <= 60) if lossy else worst == 0
    print("%s %s%s %dx%d mean %.2f max %d" % ("PASS" if ok else "FAIL", name, " 1/%d" % scale if scale > 1 else "", w, h, mean, worst))
    fail |= not ok
for out in sorted(glob.glob(os.path.join(d, "*.argb.f*"))):
    base, k = out.rsplit(".f", 1)
    src = base[:-5]
    k = int(k)
    data = open(out, "rb").read()
    w, h = struct.unpack(">II", data[:8])
    ref = Image.open(src)
    ref.seek(k)
    rp = ref.convert("RGBA").tobytes()
    worst = 0
    for i in range(w * h):
        a, r, g, b = data[8 + 4 * i:12 + 4 * i]
        R, G, B, A = rp[4 * i:4 * i + 4]
        if A == 0 and a == 0:
            continue
        worst = max(worst, abs(r - R), abs(g - G), abs(b - B), abs(a - A))
    print("%s %s frame %d %dx%d max %d" % ("PASS" if worst == 0 else "FAIL", os.path.basename(src), k, w, h, worst))
    fail |= worst != 0
sys.exit(fail)
