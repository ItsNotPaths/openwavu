// Retail PS3 .pkg -> its files, the PS3 part of RPCS3 rpcs3/Loader/PKG.cpp (package_reader).
package ps3

import "core:crypto/aes"
import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

PKG_HEADER_SIZE :: 0xc0
PKG_ENTRY_SIZE :: 0x20
PKG_FOLDER :: 4
PKG_CHUNK :: 1 << 20

// Data area: AES-128-CTR, counter = iv + block index from the data start.
Pkg :: struct {
	file:          ^os.File,
	data_offset:   i64,
	iv_hi, iv_lo:  u64,
}

// Writes the .pkg's files under out_dir at their package paths (PARAM.SFO, USRDIR/EBOOT.BIN, ...), as RPCS3 installs them.
unpack_pkg :: proc(path, out_dir: string) -> (err: string) {
	file, open_err := os.open(path)
	if open_err != nil do return fmt.tprintf("cannot open %s", path)
	defer os.close(file)
	header: [PKG_HEADER_SIZE]byte
	if n, _ := os.read_at(file, header[:], 0); n != len(header) || string(header[:4]) != "\x7fPKG" do return "not a .pkg file"
	if be16(header[:], 0x04) != 0x8000 do return "debug .pkg is not supported"
	if be16(header[:], 0x06) != 1 do return "not a PS3 .pkg"
	pkg := Pkg{file = file, data_offset = i64(be64(header[:], 0x20)), iv_hi = u64(be64(header[:], 0x70)), iv_lo = u64(be64(header[:], 0x78))}

	count := int(be32(header[:], 0x14))
	entries := make([]byte, count * PKG_ENTRY_SIZE, context.temp_allocator)
	if err = read_pkg(pkg, 0, entries); err != "" do return
	for i in 0 ..< count {
		e := entries[i * PKG_ENTRY_SIZE:]
		name := make([]byte, be32(e, 0x04), context.temp_allocator)
		if err = read_pkg(pkg, i64(be32(e, 0x00)), name); err != "" do return
		if strings.contains(string(name), "..") || filepath.is_abs(string(name)) do return fmt.tprintf(".pkg entry %q leaves the game folder", name)
		target, _ := filepath.join({out_dir, string(name)}, context.temp_allocator)
		dir := be32(e, 0x18) & 0xff == PKG_FOLDER ? target : filepath.dir(target)
		if os.make_directory_all(dir) != nil && !os.is_dir(dir) do return fmt.tprintf("cannot create %s", dir)
		if dir != target {
			if err = copy_pkg_file(pkg, target, i64(be64(e, 0x08)), i64(be64(e, 0x10))); err != "" do return
		}
	}
	return ""
}

@(private = "file")
copy_pkg_file :: proc(pkg: Pkg, target: string, offset, size: i64) -> (err: string) {
	out, create_err := os.create(target)
	if create_err != nil do return fmt.tprintf("cannot write %s", target)
	defer os.close(out)
	buf := make([]byte, PKG_CHUNK)
	defer delete(buf)
	for done: i64 = 0; done < size; done += PKG_CHUNK {
		chunk := buf[:min(PKG_CHUNK, size - done)]
		if err = read_pkg(pkg, offset + done, chunk); err != "" do return
		if _, write_err := os.write(out, chunk); write_err != nil do return fmt.tprintf("cannot write %s", target)
	}
	return ""
}

// dst = decrypted data area bytes from offset on.
@(private = "file")
read_pkg :: proc(pkg: Pkg, offset: i64, dst: []byte) -> (err: string) {
	if got, _ := os.read_at(pkg.file, dst, pkg.data_offset + offset); got != len(dst) do return "the .pkg is cut short"
	lo := pkg.iv_lo + u64(offset / 16)
	hi := pkg.iv_hi + (lo < pkg.iv_lo ? 1 : 0)
	counter: [16]byte
	endian.put_u64(counter[:8], .Big, hi)
	endian.put_u64(counter[8:], .Big, lo)
	ctx: aes.Context_CTR
	aes.init_ctr(&ctx, PKG_AES_KEY[:], counter[:])
	skipped: [16]byte
	aes.keystream_bytes_ctr(&ctx, skipped[:offset % 16])
	aes.xor_bytes_ctr(&ctx, dst, dst)
	return ""
}
