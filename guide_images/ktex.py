"""KTEX (Klei .tex) <-> PNG. Enough of the format to read a guide page and write one back."""
import struct
from io import BytesIO
from PIL import Image

MAGIC = b"KTEX"
DXT5 = 2

def header(plat, pf, tt, nmip, flags):
    return plat | (pf << 4) | (tt << 9) | (nmip << 13) | (flags << 18) | (0b111111111111 << 20)

def parse(path):
    d = open(path, "rb").read()
    assert d[:4] == MAGIC, path
    h, = struct.unpack("<I", d[4:8])
    info = dict(platform=h & 0xF, pf=(h >> 4) & 0x1F, tt=(h >> 9) & 0xF,
                nmip=(h >> 13) & 0x1F, flags=(h >> 18) & 0x3)
    off, mips = 8, []
    for _ in range(info["nmip"]):
        w, hh, pitch = struct.unpack("<HHH", d[off:off + 6])
        ds, = struct.unpack("<I", d[off + 6:off + 10])
        mips.append([w, hh, pitch, ds]); off += 10
    for m in mips:
        m.append(d[off:off + m[3]]); off += m[3]
    return info, mips

def dds(w, h, data, fourcc=b"DXT5"):
    """Wrap one mip level in a DDS container so Pillow can decompress it."""
    hdr = bytearray(128)
    hdr[0:4] = b"DDS "
    struct.pack_into("<I", hdr, 4, 124)                 # dwSize
    struct.pack_into("<I", hdr, 8, 0x1 | 0x2 | 0x4 | 0x1000 | 0x80000)  # caps|h|w|pixelformat|linearsize
    struct.pack_into("<I", hdr, 12, h)
    struct.pack_into("<I", hdr, 16, w)
    struct.pack_into("<I", hdr, 20, len(data))          # dwPitchOrLinearSize
    struct.pack_into("<I", hdr, 28, 1)                  # dwMipMapCount
    struct.pack_into("<I", hdr, 76, 32)                 # ddspf.dwSize
    struct.pack_into("<I", hdr, 80, 0x4)                # DDPF_FOURCC
    hdr[84:88] = fourcc
    struct.pack_into("<I", hdr, 108, 0x1000)            # DDSCAPS_TEXTURE
    return bytes(hdr) + data

def to_png(path, out):
    info, mips = parse(path)
    assert info["pf"] == DXT5, f"{path}: pixelformat {info['pf']}"
    w, h, _, _, data = mips[0]
    img = Image.open(BytesIO(dds(w, h, data))).convert("RGBA")
    # Klei stores textures upside down.
    img = img.transpose(Image.FLIP_TOP_BOTTOM)
    img.save(out)
    return img.size

if __name__ == "__main__":
    import sys
    print(to_png(sys.argv[1], sys.argv[2]))

def encode(img, path, platform=0, tt=1, flags=3):
    """Write an RGBA PIL image back out as a DXT5 KTEX with a full mip chain."""
    import struct as _s
    img = img.convert("RGBA").transpose(Image.FLIP_TOP_BOTTOM)
    levels, w, h = [], img.width, img.height
    cur = img
    while True:
        b = BytesIO(); cur.save(b, format="DDS", pixel_format="DXT5")
        levels.append((cur.width, cur.height, b.getvalue()[128:]))
        if cur.width == 1 and cur.height == 1:
            break
        cur = cur.resize((max(1, cur.width // 2), max(1, cur.height // 2)), Image.LANCZOS)
    out = bytearray(MAGIC)
    out += _s.pack("<I", header(platform, DXT5, tt, len(levels), flags))
    for lw, lh, data in levels:
        out += _s.pack("<HHH", lw, lh, lw * 4)          # pitch: DXT5 is 4 bytes per 4x1 row
        out += _s.pack("<I", len(data))
    for _, _, data in levels:
        out += data
    open(path, "wb").write(bytes(out))
    return len(out)
