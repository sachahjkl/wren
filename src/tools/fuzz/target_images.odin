package fuzz

import "wb:images"

IMAGE_FILES := []Seed_Files{
	{dir = "examples/site/images", suffixes = IMAGE_SUFFIXES},
	{dir = "examples/site/media", suffixes = IMAGE_SUFFIXES},
	{dir = "examples/site/blocker", suffixes = IMAGE_SUFFIXES},
	{dir = "assets", suffixes = IMAGE_SUFFIXES},
}

IMAGE_SUFFIXES := []string{".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".bmp", ".ico", ".tif", ".tiff", ".svg"}

// The smallest file of each format the repository lacks, and headers that announce large sizes.
IMAGE_SEEDS := []string{
	"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;",
	"GIF89a\x02\x00\x02\x00\x00\x00\x00!\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00;",
	"BM\x3a\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00\x28\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x18\x00\x00\x00\x00\x00\x04\x00\x00\x00\x13\x0b\x00\x00\x13\x0b\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\x00",
	"\x00\x00\x01\x00\x01\x00\x10\x10\x00\x00\x01\x00\x20\x00\x68\x04\x00\x00\x16\x00\x00\x00",
	"II*\x00\x08\x00\x00\x00\x01\x00\x00\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00",
	"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x7f\xff\xff\xff\x7f\xff\xff\xff\x08\x06\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00IEND\xaeB`\x82",
	"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xc0\x00\x11\x08\xff\xff\xff\xff\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01\xff\xd9",
	"RIFF\x1a\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x10\x00\x00\x00\xff\xff\xff\xff\xff\xff",
	"\x00\x00\x00\x1cftypavif\x00\x00\x00\x00avifmif1miaf",
	"<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><rect width='10' height='10' fill='red'/></svg>",
	"<?xml version='1.0'?><!DOCTYPE svg [<!ENTITY a 'aaaaaaaaaa'><!ENTITY b '&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;'>]><svg xmlns='http://www.w3.org/2000/svg'><text>&b;</text></svg>",
	"<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink'><defs><g id='a'><use href='#a'/></g></defs><use xlink:href='#a'/><filter id='f'><feGaussianBlur stdDeviation='1e9'/></filter><rect filter='url(#f)' width='1e9' height='1e9'/></svg>",
}

IMAGE_TOKENS := []string{
	"\x89PNG\r\n\x1a\n", "IHDR", "IDAT", "IEND", "PLTE", "tRNS", "iCCP", "acTL", "fcTL", "fdAT", "\xff\xd8", "\xff\xd9", "\xff\xc0", "\xff\xc4",
	"\xff\xda", "\xff\xe1", "Exif\x00\x00", "GIF89a", "NETSCAPE2.0", "!\xf9\x04", ",", ";", "RIFF", "WEBP", "VP8 ", "VP8L", "VP8X", "ANIM", "ANMF",
	"ftyp", "avif", "meta", "iloc", "ipma", "ispe", "BM", "II*\x00", "MM\x00*", "<svg", "<use", "<filter", "<image href='data:", "&a;",
	"\xff\xff\xff\xff", "\x00\x00\x00\x00", "\x7f\xff\xff\xff",
}

// What Wren reads of an image itself, before a decoder sees it: the format, the size its header says (the limits refuse a
// bomb there) and whether the file is complete.
target_images :: proc(data: []u8) {
	_ = images.sniff(data)
	mimes := [?]string{"image/png", "image/svg+xml", "text/xml", "application/octet-stream", "image/x-icon"}
	_ = images.sniff(data, mimes[len(data) % len(mimes)], len(data) % 2 == 0)
	for f in images.Format {
		_, _, _ = images.header_size(data, f)
		_ = images.looks_complete(data, f)
	}
	_, _ = images.plays_from_loop_extension(data)
}

// Small bounds: an input that announces a huge image is refused as the browser refuses it, and one that passes costs
// little. The built-in decoders on every system (WIC is the system's, not under test).
@(private = "file")
image_options :: proc(data: []u8) -> images.Decode_Options {
	o := images.Decode_Options{limits = images.LIMITS_DEFAULT}
	o.limits.max_encoded_bytes = MAX_INPUT
	o.limits.max_dimension = 4096
	o.limits.max_pixels = 4_000_000
	o.limits.max_frames = 16
	o.limits.max_image_bytes = 64 << 20
	o.limits.system_decoders = false
	o.limits.svg.max_nodes = 20_000
	o.limits.svg.max_render_cost = 50_000_000
	o.limits.svg.text = false
	o.allow_truncated = len(data) % 2 == 1
	o.first_frame_only = len(data) % 3 == 0
	return o
}

target_image_decode :: proc(data: []u8) {
	o := image_options(data)
	_, _ = images.probe_now(data, o)
	img, _, _ := images.decode_now(data, o)
	images.image_destroy(img)
	// (a reduced decode takes another path in the decoders)
	o.target_w, o.target_h, o.downscale_below = 16, 16, 0.5
	small, _, _ := images.decode_now(data, o)
	images.image_destroy(small)
}
