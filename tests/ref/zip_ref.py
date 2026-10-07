#!/usr/bin/env python3
"""Generate deterministic ZIP reader fixtures with Python's zipfile."""
import io
from pathlib import Path
import struct
import zipfile

ROOT = Path(__file__).resolve().parent


def archive(method, entries, *, streaming=False, zip64=False):
    class Stream(io.BytesIO):
        def seekable(self):
            return False

        def seek(self, *args):
            raise io.UnsupportedOperation

    output = Stream() if streaming else io.BytesIO()
    with zipfile.ZipFile(output, 'w', compression=method) as z:
        z.comment = b'fixture comment PK\x05\x06'
        for name, data in entries:
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = method
            if zip64:
                with z.open(info, 'w', force_zip64=True) as f:
                    f.write(data)
            else:
                z.writestr(info, data)
    return output.getvalue()


entries = [('anims/', b''), ('overlay.db', b'SQLite fixture\x00'),
           ('anims/test.anim', b'OWAN' * 128), ('empty', b''),
           ('images/\u03bb.png', bytes(range(256)))]
stored = archive(zipfile.ZIP_STORED, entries)
(ROOT / 'stored.zip').write_bytes(stored)
(ROOT / 'deflated.zip').write_bytes(archive(zipfile.ZIP_DEFLATED, entries))
(ROOT / 'descriptor.zip').write_bytes(archive(zipfile.ZIP_DEFLATED, entries, streaming=True))
(ROOT / 'zip64.zip').write_bytes(archive(zipfile.ZIP_STORED, [('overlay.db', b'x')], zip64=True))
(ROOT / 'traversal.zip').write_bytes(archive(zipfile.ZIP_STORED, [('anims/../escape', b'x')]))
(ROOT / 'backslash.zip').write_bytes(archive(zipfile.ZIP_STORED, [('anims\\..\\escape', b'x')]))
(ROOT / 'unsupported.zip').write_bytes(archive(zipfile.ZIP_BZIP2, [('overlay.db', b'x')]))
(ROOT / 'empty.zip').write_bytes(archive(zipfile.ZIP_STORED, []))

corrupt = bytearray(stored)
local = corrupt.index(b'PK\x03\x04', 4)
name_size, extra_size = struct.unpack_from('<HH', corrupt, local + 26)
corrupt[local + 30 + name_size + extra_size] ^= 1
(ROOT / 'crc.zip').write_bytes(corrupt)

encrypted = bytearray(stored)
for signature, flag_offset in ((b'PK\x03\x04', 6), (b'PK\x01\x02', 8)):
    offset = encrypted.index(signature)
    flags, = struct.unpack_from('<H', encrypted, offset + flag_offset)
    struct.pack_into('<H', encrypted, offset + flag_offset, flags | 1)
(ROOT / 'encrypted.zip').write_bytes(encrypted)
