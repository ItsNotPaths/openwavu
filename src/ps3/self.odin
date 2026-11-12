// SELF decryption (disc and NPDRM), a port of RPCS3 rpcs3/Crypto/unself.cpp (64-bit ELF only).
// The SCE keys ship in keys.odin. For a PSN game the user supplies the RAP (per-game license).
package ps3

import "core:bytes"
import "core:compress/zlib"
import "core:crypto/aes"
import "core:encoding/endian"
import "core:encoding/hex"

SCE_HEADER_SIZE :: 0x20
META_INFO_SIZE :: 0x40
META_HEADER_SIZE :: 0x20
META_SECTION_SIZE :: 0x30
SUPPLEMENTAL_NPDRM :: 3
PROGRAM_APP :: 4  // a disc game
PROGRAM_NPDRM :: 8

be16 :: proc(b: []byte, off: int) -> u16 {v, _ := endian.get_u16(b[off:], .Big); return v}
be32 :: proc(b: []byte, off: int) -> u32 {v, _ := endian.get_u32(b[off:], .Big); return v}
be64 :: proc(b: []byte, off: int) -> int {v, _ := endian.get_u64(b[off:], .Big); return int(v)}

// EBOOT.BIN -> plain ELF, byte for byte what `rpcs3 --decrypt` writes. rap: a PSN game's license; nil for a disc game.
decrypt_self :: proc(self: []byte, rap: []byte, allocator := context.allocator) -> (elf: []byte, err: string) {
	if len(self) < 0x90 || string(self[:4]) != "SCE\x00" do return nil, "not a SELF file"
	key_revision := be16(self, 0x08)
	if key_revision & 0x8000 != 0 do return nil, "debug SELF is not supported"
	meta_offset := int(be32(self, 0x0c)) + SCE_HEADER_SIZE
	header_size := be64(self, 0x10)

	ext := SCE_HEADER_SIZE  // extended header: u64 offsets
	program_type := be32(self, be64(self, ext + 0x08) + 0x0c)
	ehdr_offset := be64(self, ext + 0x10)
	phdr_offset := be64(self, ext + 0x18)
	shdr_offset := be64(self, ext + 0x20)
	supp_offset := be64(self, ext + 0x38)
	supp_size := be64(self, ext + 0x40)

	ehdr := self[ehdr_offset:][:0x40]
	if ehdr[4] != 2 do return nil, "32-bit SELF is not supported"
	phoff, shoff := be64(ehdr, 0x20), be64(ehdr, 0x28)
	phnum, shnum := int(be16(ehdr, 0x38)), int(be16(ehdr, 0x3c))

	if program_type != PROGRAM_APP && program_type != PROGRAM_NPDRM do return nil, "SELF type is not supported"
	key, ok := find_self_key(program_type, key_revision)
	if !ok do return nil, "no key for this SELF key revision"

	// Metadata info: the NPDRM layer (klicensee) of a PSN game, then the SELF key.
	info: [META_INFO_SIZE]byte
	copy(info[:], self[meta_offset:])
	if program_type == PROGRAM_NPDRM {
		if len(rap) != 16 do return nil, "RAP file is not 16 bytes"
		license: u32 = 0
		for off := supp_offset; off < supp_offset + supp_size; off += int(be32(self, off + 4)) {
			if be32(self, off) == SUPPLEMENTAL_NPDRM do license = be32(self, off + 0x18)
		}
		switch license {
		case 1, 2:
		case 0: return nil, "SELF has no NPDRM header"
		case: return nil, "free-license SELF is not supported"
		}
		npdrm_key := rap_to_klicensee(rap)
		klic := aes_ecb_decrypt_block(NP_KLIC_KEY[:], npdrm_key[:])
		zero_iv: [16]byte
		aes_cbc_decrypt(klic[:], zero_iv[:], info[:])
	}
	erk, _ := hex.decode(transmute([]byte)key.erk, context.temp_allocator)
	riv, _ := hex.decode(transmute([]byte)key.riv, context.temp_allocator)
	aes_cbc_decrypt(erk, riv, info[:])
	if info[0x10] != 0 || info[0x30] != 0 do return nil, "SELF metadata did not decrypt (wrong RAP?)"

	// Metadata headers: AES-128-CTR with the key and iv from the info.
	headers := make([]byte, header_size - meta_offset - META_INFO_SIZE, context.temp_allocator)
	copy(headers, self[meta_offset + META_INFO_SIZE:])
	aes_ctr(info[0x00:0x10], info[0x20:0x30], headers)
	section_count := int(be32(headers, 0x0c))
	data_keys := headers[META_HEADER_SIZE + section_count * META_SECTION_SIZE:]

	out: [dynamic]byte
	out.allocator = allocator
	write_at :: proc(out: ^[dynamic]byte, off: int, data: []byte) {
		if len(out) < off + len(data) do resize(out, off + len(data))
		copy(out[off:], data)
	}
	write_at(&out, 0, ehdr)
	write_at(&out, phoff, self[phdr_offset:][:phnum * 0x38])

	for i in 0 ..< section_count {
		s := headers[META_HEADER_SIZE + i * META_SECTION_SIZE:]
		data_offset, data_size := be64(s, 0x00), be64(s, 0x08)
		type, program := be32(s, 0x10), int(be32(s, 0x14))
		encrypted, key_idx, iv_idx, compressed := be32(s, 0x20), int(be32(s, 0x24)), int(be32(s, 0x28)), be32(s, 0x2c)
		if type != 2 do continue

		data := make([]byte, data_size, context.temp_allocator)
		copy(data, self[data_offset:])
		if encrypted == 3 do aes_ctr(data_keys[key_idx * 16:][:16], data_keys[iv_idx * 16:][:16], data)

		phdr := self[phdr_offset + program * 0x38:]
		p_offset, p_filesz := be64(phdr, 0x08), be64(phdr, 0x20)
		if compressed == 2 {
			buf: bytes.Buffer
			if zlib.inflate(data, &buf, expected_output_size = p_filesz) != nil do return nil, "SELF segment did not inflate"
			data = bytes.buffer_to_bytes(&buf)
		}
		write_at(&out, p_offset, data)
	}

	if shdr_offset != 0 do write_at(&out, shoff, self[shdr_offset:][:shnum * 0x40])
	return out[:], ""
}

find_self_key :: proc(program_type: u32, revision: u16) -> (Self_Key, bool) {
	if program_type == PROGRAM_APP {
		for key in APP_KEYS do if key.revision == revision do return key, true
	} else {
		for key in NPDRM_KEYS do if key.revision == revision do return key, true
	}
	return {}, false
}

// rap_to_rif in RPCS3 key_vault.cpp.
rap_to_klicensee :: proc(rap: []byte) -> (key: [16]byte) {
	zero_iv: [16]byte
	copy(key[:], rap)
	aes_cbc_decrypt(RAP_KEY[:], zero_iv[:], key[:])
	for _ in 0 ..< 5 {
		for i in 0 ..< 16 {
			p := RAP_PBOX[i]
			key[p] ~= RAP_E1[p]
		}
		for i := 15; i >= 1; i -= 1 {
			key[RAP_PBOX[i]] ~= key[RAP_PBOX[i - 1]]
		}
		o: u8 = 0
		for i in 0 ..< 16 {
			p := RAP_PBOX[i]
			kc := key[p] - o
			ec2 := RAP_E2[p]
			if o != 1 || kc != 0xff {
				o = kc < ec2 ? 1 : 0
				key[p] = kc - ec2
			} else {
				key[p] = kc - ec2
			}
		}
	}
	return key
}

aes_ecb_decrypt_block :: proc(key, block: []byte) -> (out: [16]byte) {
	ctx: aes.Context_ECB
	aes.init_ecb(&ctx, key)
	aes.decrypt_ecb(&ctx, out[:], block)
	return out
}

// In place. len(data) is a multiple of 16.
aes_cbc_decrypt :: proc(key, iv, data: []byte) {
	ctx: aes.Context_ECB
	aes.init_ecb(&ctx, key)
	prev, cur: [16]byte
	copy(prev[:], iv)
	for off := 0; off < len(data); off += 16 {
		block := data[off:][:16]
		copy(cur[:], block)
		aes.decrypt_ecb(&ctx, block, cur[:])
		for i in 0 ..< 16 do block[i] ~= prev[i]
		prev = cur
	}
}

// In place.
aes_ctr :: proc(key, iv, data: []byte) {
	ctx: aes.Context_CTR
	aes.init_ctr(&ctx, key, iv)
	aes.xor_bytes_ctr(&ctx, data, data)
}
