"""Writes models.txt: CRC32 of every NDP3 and NTP3 section as tk5decomp ndp3.py / ntp3.py parse it.
usage: ../tk5decomp/.venv/bin/python tests/ref/models_ref.py"""
import struct, sys, zlib
from pathlib import Path
TK5 = Path("../tk5decomp").resolve()
sys.path.insert(0, str(TK5 / "tools"))
import ndp3, ntp3
from motbin import unlz

ENTRIES = list(range(1534, 2125, 7)) + list(range(2132, 2132 + 3 * 38, 3))
LZ_TEXTURES = range(1474, 1528)


def is_container(d):
    if len(d) < 8:
        return False
    n, = struct.unpack_from("<I", d, 0)
    return 0 < n < 64 and 4 + 8 * n <= len(d) and all(o + s <= len(d) for o, s in struct.iter_unpack("<II", d[4:4 + 8 * n]))


def crc_ndp3(d):
    crc, polys, verts, tris = 0, 0, 0, 0
    meshes = ndp3.parse(d)
    for m in meshes:
        crc = zlib.crc32(m.name.encode() + struct.pack("<h", m.single_bind), crc)
        for p in m.polys:
            for a in (p.positions, p.normals, p.uvs, p.colors, p.joints, p.weights, p.triangles):
                if a is not None:
                    crc = zlib.crc32(a.tobytes(), crc)
            crc = zlib.crc32(struct.pack("<%dI" % len(p.texture_hashes), *p.texture_hashes), crc)
            polys, verts, tris = polys + 1, verts + len(p.positions), tris + len(p.triangles)
    return f"{len(meshes)} {polys} {verts} {tris} {crc:08x}"


def crc_ntp3(d):
    crc, texs = 0, ntp3.parse(d)
    for t in texs:
        crc = zlib.crc32(struct.pack("<I", t.hash) + ntp3.to_rgba(t).tobytes(), crc)
    return f"{len(texs)} {crc:08x}"


def walk(entry, d, path, out):
    if d[:4] == b"NDP3":
        out.append(f"ndp3 {entry} {path} {crc_ndp3(d)}")
    elif d[:4] == b"NTP3":
        out.append(f"ntp3 {entry} {path} {crc_ntp3(d)}")
    elif is_container(d):
        for i, s in enumerate(ndp3.sections(d)):
            walk(entry, s, f"{path}/{i}" if path else str(i), out)


out = []
for e in ENTRIES:
    p = TK5 / f"extract/{e:04d}.bin"
    if p.exists():
        walk(e, p.read_bytes(), "", out)
for e in LZ_TEXTURES:
    p = next((TK5 / "extract").glob(f"{e:04d}.*"), None)
    if p:
        out.append(f"ntp3 {e} lz {crc_ntp3(unlz(p.read_bytes()))}")
(Path(__file__).parent / "models.txt").write_text("\n".join(out) + "\n")
print(len(out), "sections")
