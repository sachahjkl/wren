package images

// What the file's own header says, read here before WIC sees the bytes: the dimensions (so the limits refuse a bomb
// before any decoder allocates for it) and whether the file is complete. WIC decodes a PNG or GIF cut short without
// complaint (the missing rows come out transparent); a browser that got a truncated file should show it as broken.

@(private = "file")
be16 :: #force_inline proc(b: []byte, at: int) -> int { return int(b[at]) << 8 | int(b[at + 1]) }
@(private = "file")
be32 :: #force_inline proc(b: []byte, at: int) -> int { return int(b[at]) << 24 | int(b[at + 1]) << 16 | int(b[at + 2]) << 8 | int(b[at + 3]) }
@(private = "file")
le16 :: #force_inline proc(b: []byte, at: int) -> int { return int(b[at]) | int(b[at + 1]) << 8 }
@(private = "file")
le24 :: #force_inline proc(b: []byte, at: int) -> int { return int(b[at]) | int(b[at + 1]) << 8 | int(b[at + 2]) << 16 }
@(private = "file")
le32 :: #force_inline proc(b: []byte, at: int) -> int { return int(b[at]) | int(b[at + 1]) << 8 | int(b[at + 2]) << 16 | int(b[at + 3]) << 24 }

// Width and height announced by the header (as stored, before EXIF orientation). ok = false: not found here (the
// decoder's own GetSize still applies its limits later).
header_size :: proc(data: []byte, f: Format) -> (w, h: int, ok: bool) {
	#partial switch f {
	case .Png:
		if len(data) >= 24 && string(data[12:16]) == "IHDR" { return be32(data, 16), be32(data, 20), true }
	case .Gif:
		if len(data) >= 10 { return le16(data, 6), le16(data, 8), true }
	case .Bmp:
		if len(data) >= 26 {
			if le32(data, 14) == 12 { return le16(data, 18), le16(data, 20), true }   // OS/2 BITMAPCOREHEADER
			hh := i32(u32(le32(data, 22)))
			return abs(int(i32(u32(le32(data, 18))))), abs(int(hh)), true
		}
	case .Jpeg:
		// markers up to the first start-of-frame
		at := 2
		for at + 9 < len(data) {
			if data[at] != 0xFF { return 0, 0, false }
			m := data[at + 1]
			if m == 0xFF { at += 1; continue }
			if m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7) { at += 2; continue }
			n := be16(data, at + 2)
			if (m >= 0xC0 && m <= 0xCF) && m != 0xC4 && m != 0xC8 && m != 0xCC {
				return be16(data, at + 7), be16(data, at + 5), true
			}
			if n < 2 { return 0, 0, false }
			at += 2 + n
		}
	case .Webp:
		if len(data) >= 30 {
			switch string(data[12:16]) {
			case "VP8 ": return le16(data, 26) & 0x3FFF, le16(data, 28) & 0x3FFF, true
			case "VP8L":
				if data[20] != 0x2F { return 0, 0, false }
				bits := le32(data, 21)
				return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1, true
			case "VP8X": return le24(data, 24) + 1, le24(data, 27) + 1, true
			}
		}
	}
	return 0, 0, false
}

// False when the file visibly stops before its end: a PNG without IEND, a GIF without its trailer, a JPEG without the
// end-of-image marker (trailing bytes after it are tolerated).
looks_complete :: proc(data: []byte, f: Format) -> bool {
	#partial switch f {
	case .Png:
		// walk the chunks: each is length, type, data, CRC
		at := 8
		for at + 12 <= len(data) {
			n := be32(data, at)
			if n < 0 || n > len(data) { return false }
			if string(data[at + 4:at + 8]) == "IEND" { return true }
			at += 12 + n
		}
		return false
	case .Gif:
		end := len(data)
		for end > 0 && data[end - 1] == 0 { end -= 1 }   // zero padding after the trailer
		return end > 0 && data[end - 1] == 0x3B
	case .Jpeg:
		tail := data[max(len(data) - 4096, 0):]
		for i := len(tail) - 2; i >= 0; i -= 1 {
			if tail[i] == 0xFF && tail[i + 1] == 0xD9 { return true }
		}
		return false
	}
	return true
}
