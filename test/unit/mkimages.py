#!/usr/bin/env python3
"""Make the test images for test/unit/images.vt in DIR (default build/img)
with PIL: the same pictures in each format and its variants."""
import os
import random
import sys

from PIL import Image, ImageDraw

d = sys.argv[1] if len(sys.argv) > 1 else "build/img"
os.makedirs(d, exist_ok=True)
random.seed(7)


def picture(w, h, alpha=False):
    """Gradients, shapes, some noise and sharp edges."""
    im = Image.new("RGBA", (w, h))
    px = im.load()
    for y in range(h):
        for x in range(w):
            a = 255 if not alpha else (x * 255 // (w - 1) if y < h // 2 else (0 if (x // 4 + y // 4) % 2 else 255))
            px[x, y] = (x * 255 // (w - 1), y * 255 // (h - 1), (x * y) & 255, a)
    dr = ImageDraw.Draw(im)
    dr.ellipse((w // 4, h // 4, w * 3 // 4, h * 3 // 4), fill=(200, 30, 60, 255))
    dr.rectangle((2, 2, w // 3, h // 5), fill=(20, 220, 90, 255))
    dr.line((0, h - 1, w - 1, 0), fill=(255, 255, 0, 255), width=3)
    for _ in range(w * h // 20):
        px[random.randrange(w), random.randrange(h)] = (random.randrange(256), random.randrange(256), random.randrange(256), 255)
    return im


def save(im, name, **kw):
    im.save(os.path.join(d, name), **kw)


# GIF: palette images, interlaced or not, transparency, few colours,
# an image smaller than its screen
p = picture(64, 48).convert("RGB")
save(p.quantize(256), "g256.gif", interlace=False)
save(p.quantize(256), "g256i.gif", interlace=True)
save(p.quantize(2), "g2.gif", interlace=False)
save(p.quantize(16), "g16i.gif", interlace=True)
t = p.quantize(32)
save(t, "gtrans.gif", transparency=5, interlace=False)
big = picture(301, 201).convert("RGB").quantize(200)
save(big, "gbig.gif", interlace=False)

# PNG: every colour type and depth, interlaced or not, palettes with
# tRNS, colour keys, filters of all kinds (PIL picks them per row)
from PIL import PngImagePlugin  # noqa: E402,F401
pic = picture(53, 37, alpha=True)
save(pic, "prgba.png")
save(pic, "prgbai.png", interlace=True)
save(pic.convert("RGB"), "prgb.png")
save(pic.convert("RGB"), "prgbi.png", interlace=True)
save(pic.convert("L"), "pgrey.png")
save(pic.convert("LA"), "pga.png")
save(pic.convert("RGB").quantize(256), "ppal8.png")
save(pic.convert("RGB").quantize(16), "ppal4.png", bits=4)
save(pic.convert("RGB").quantize(4), "ppal2.png", bits=2)
save(pic.convert("1"), "pmono.png")
save(pic.convert("RGB").quantize(16), "ppal4i.png", bits=4, interlace=True)
q = pic.quantize(64)                        # palette with alpha (tRNS)
save(q, "ppaltrns.png")
save(pic.convert("RGB"), "pkey.png", transparency=(255, 255, 0))
save(pic.convert("L"), "pgreykey.png", transparency=0)
# 16 bits per sample (I;16 grey, and 48/64-bit colour through raw data)
g16 = Image.new("I;16", (31, 29))
g16.putdata([(x * 2113 + y * 977) & 0xffff for y in range(29) for x in range(31)])
save(g16, "pgrey16.png")
# a big one, compressed hard (dynamic Huffman codes, long matches)
save(picture(400, 300).convert("RGB"), "pbig.png", optimize=True)
save(picture(400, 300).convert("RGB"), "pfast.png", compress_level=1)
save(picture(64, 64).convert("RGB"), "pstored.png", compress_level=0)
w16 = pic.convert("RGBA")


def png16(name, mode, w, h, px):
    """A 16-bit colour PNG, written by hand (PIL cannot)."""
    import struct, zlib
    ctype = {"RGB": 2, "RGBA": 6}[mode]
    raw = b"".join(b"\0" + b"".join(struct.pack(">" + "H" * len(p), *p) for p in px[y * w:(y + 1) * w]) for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    data = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 16, ctype, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
    open(os.path.join(d, name), "wb").write(data)


px = [((x * 2311) & 0xffff, (y * 4099) & 0xffff, (x * y * 37) & 0xffff, ((x + y) * 3001) & 0xffff) for y in range(21) for x in range(27)]
png16("prgba16.png", "RGBA", 27, 21, px)
png16("prgb16.png", "RGB", 27, 21, [p[:3] for p in px])

# JPEG: baseline with each subsampling, grey, optimized Huffman tables,
# progressive, restart intervals, Adobe RGB (cjpeg), odd sizes
import subprocess  # noqa: E402
jp = picture(83, 61).convert("RGB")
save(jp, "j444.jpg", quality=90, subsampling=0)
save(jp, "j422.jpg", quality=85, subsampling=1)
save(jp, "j420.jpg", quality=75, subsampling=2)
save(jp, "jq30.jpg", quality=30)
save(jp.convert("L"), "jgrey.jpg", quality=85)
save(jp, "jopt.jpg", quality=80, optimize=True)
save(jp, "jprog.jpg", quality=80, progressive=True)
save(jp.convert("L"), "jprogg.jpg", quality=80, progressive=True)
big = picture(320, 240).convert("RGB")
save(big, "jbig.jpg", quality=85)
save(big, "jbigp.jpg", quality=85, progressive=True)
ppm = os.path.join(d, "tmp.ppm")
jp.save(ppm)


def cjpeg(name, *args):
    with open(os.path.join(d, name), "wb") as f:
        subprocess.run(["cjpeg"] + list(args) + [ppm], stdout=f, check=True)


cjpeg("jrst.jpg", "-restart", "1", "-quality", "80")
cjpeg("jrstp.jpg", "-restart", "2", "-progressive", "-quality", "80")
cjpeg("j411.jpg", "-sample", "4x1", "-quality", "85")
cjpeg("j440.jpg", "-sample", "1x2", "-quality", "85")
cjpeg("jrgb.jpg", "-rgb", "-quality", "90")
os.remove(ppm)

# WebP lossless: PIL picks transforms by content: photos (predictor,
# cross colour, subtract green, meta codes, colour cache), few colours
# (colour indexing, packed), alpha; lossy (VP8), with alpha (ALPH)
wp = picture(71, 53, alpha=True)
save(wp, "wl-rgba.webp", lossless=True)
save(wp.convert("RGB"), "wl-rgb.webp", lossless=True)
save(wp.convert("RGB"), "wl-fast.webp", lossless=True, quality=0, method=0)
save(wp.convert("RGB"), "wl-best.webp", lossless=True, quality=100, method=6)
save(wp.convert("RGB").quantize(2).convert("RGB"), "wl-pal2.webp", lossless=True)
save(wp.convert("RGB").quantize(4).convert("RGB"), "wl-pal4.webp", lossless=True)
save(wp.convert("RGB").quantize(16).convert("RGB"), "wl-pal16.webp", lossless=True)
save(wp.convert("RGB").quantize(200).convert("RGB"), "wl-pal200.webp", lossless=True)
save(picture(300, 200).convert("RGB"), "wl-big.webp", lossless=True)

wy = picture(83, 61)
save(wy.convert("RGB"), "wy-q75.webp", quality=75)
save(wy.convert("RGB"), "wy-q20.webp", quality=20)
save(wy.convert("RGB"), "wy-q95.webp", quality=95, method=6)
save(wy.convert("RGB"), "wy-m0.webp", quality=60, method=0)
save(picture(320, 240).convert("RGB"), "wy-big.webp", quality=80)
save(picture(83, 61, alpha=True), "wy-alpha.webp", quality=80)
save(picture(83, 61, alpha=True), "wy-alpha2.webp", quality=50, alpha_quality=50, method=6)
# the loop filters PIL does not choose: simple, and a strong sharp one
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import webpenc  # noqa: E402
webpenc.encode(wy, os.path.join(d, "wy-simple.webp"), 0, 60)
webpenc.encode(picture(320, 240), os.path.join(d, "wy-simbig.webp"), 0, 100, 4, 40)
webpenc.encode(wy, os.path.join(d, "wy-sharp.webp"), 1, 100, 7, 30)

# ICO (favicons): BMP images of 32 (with alpha), 24, 8, 4 and 1 bits a
# pixel with their AND masks, odd sizes (rows padded), several sizes in
# one file (the largest is PIL's and Velox's natural one), PNGs inside
import struct  # noqa: E402


def dib(im, bpp):
    """A BMP image for an ICO file: header, palette, pixels, AND mask."""
    w, h = im.size
    rgba = im.convert("RGBA")
    px = rgba.load()
    pal = []
    if bpp <= 8:
        q = rgba.convert("RGB").quantize(1 << bpp)
        pal = q.getpalette()[:3 * (1 << bpp)]
        pal += [0] * (3 * (1 << bpp) - len(pal))
        qp = q.load()
    rows = []
    for y in range(h - 1, -1, -1):
        bits = []
        row = bytearray()
        for x in range(w):
            r, g, b, a = px[x, y]
            if bpp == 32:
                row += bytes((b, g, r, a))
            elif bpp == 24:
                row += bytes((b, g, r))
            else:
                bits.append(qp[x, y])
        if bpp <= 8:
            acc, n = 0, 0
            for v in bits:
                acc = acc << bpp | v
                n += bpp
                if n == 8:
                    row.append(acc)
                    acc, n = 0, 0
            if n:
                row.append(acc << (8 - n))
        row += bytes(-len(row) % 4)
        rows.append(bytes(row))
    mask = []
    for y in range(h - 1, -1, -1):
        row = bytearray((w + 7) // 8)
        for x in range(w):
            if px[x, y][3] < 128:
                row[x // 8] |= 0x80 >> (x % 8)
        row += bytes(-len(row) % 4)
        mask.append(bytes(row))
    ncol = (1 << bpp) if bpp <= 8 else 0
    hdr = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, bpp, 0, 0, 0, 0, ncol, 0)
    palb = b"".join(bytes((pal[3 * i + 2], pal[3 * i + 1], pal[3 * i], 0)) for i in range(ncol))
    return hdr + palb + b"".join(rows) + b"".join(mask)


def ico(name, images):
    """images: (width, height, bpp, data)"""
    out = struct.pack("<HHH", 0, 1, len(images))
    off = 6 + 16 * len(images)
    for w, h, bpp, data in images:
        out += struct.pack("<BBBBHHII", w % 256, h % 256, (1 << bpp) % 256 if bpp <= 8 else 0, 0, 1, bpp, len(data), off)
        off += len(data)
    open(os.path.join(d, name), "wb").write(out + b"".join(i[3] for i in images))


def icon(w, h, alpha):
    im = picture(w, h, alpha=alpha)
    if not alpha:
        # a round icon: the corners transparent (the AND mask)
        px = im.load()
        for y in range(h):
            for x in range(w):
                if (2 * x - w + 1) ** 2 + (2 * y - h + 1) ** 2 > w * w:
                    px[x, y] = (0, 0, 0, 0)
    return im


i32 = icon(24, 24, True)
ico("i32.ico", [(16, 16, 32, dib(icon(16, 16, True), 32)), (24, 24, 32, dib(i32, 32))])
ico("i24.ico", [(19, 19, 24, dib(icon(19, 19, False), 24))])
ico("i8.ico", [(20, 20, 8, dib(icon(20, 20, False), 8))])
ico("i4.ico", [(13, 11, 4, dib(icon(13, 11, False), 4))])
ico("i1.ico", [(17, 11, 1, dib(icon(17, 11, False), 1))])
save(picture(48, 48, alpha=True), "ipng.ico", sizes=[(16, 16), (32, 32), (48, 48)])

# animated GIFs (gif.s GifNext): frames of the whole canvas, frames
# that cover part of it with transparency, disposals 1, 2 and 3
frames = []
for k in range(5):
    im = Image.new("RGB", (40, 30), (255, 255, 255))
    dr = ImageDraw.Draw(im)
    dr.rectangle((k * 7, 5, k * 7 + 10, 20), fill=(200, 30, 30))
    dr.text((2, 18), str(k), fill=(0, 0, 200))
    frames.append(im)
frames[0].save(os.path.join(d, "ganim.gif"), save_all=True, append_images=frames[1:],
               duration=[100, 200, 50, 300, 100], loop=0)
for disp in (1, 2, 3):
    fr = []
    for k in range(4):
        im = Image.new("RGBA", (32, 24), (0, 0, 0, 0))
        dr = ImageDraw.Draw(im)
        dr.ellipse((k * 5, k * 3, k * 5 + 12, k * 3 + 12), fill=(30, 160, 60, 255))
        if k == 0:
            dr.rectangle((0, 20, 31, 23), fill=(250, 200, 0, 255))
        fr.append(im)
    fr[0].save(os.path.join(d, "ganimd%d.gif" % disp), save_all=True, append_images=fr[1:],
               duration=80, loop=0, disposal=disp, transparency=0, optimize=False)

# broken files: cut short, and with bytes overwritten; decoding them
# must not crash (their output is not compared: ".bad")
random.seed(11)
for name in sorted(os.listdir(d)):
    if "." not in name or name.endswith((".argb", ".bad")) or name.startswith(("cut", "bad")):
        continue
    data = open(os.path.join(d, name), "rb").read()
    for frac in (0.3, 0.7, 0.97):
        open(os.path.join(d, "cut%d-%s" % (int(frac * 100), name)), "wb").write(data[:int(len(data) * frac)])
    for k in range(3):
        b = bytearray(data)
        for _ in range(8):
            i = random.randrange(16, len(b))
            b[i] = random.randrange(256)
        open(os.path.join(d, "bad%d-%s" % (k, name)), "wb").write(bytes(b))
