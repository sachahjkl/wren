// Images for the image tests (src/images unit tests, src/tools/imagestest, examples/site/images.html).
//
//	testserver -gen-images DIR   writes the test files into DIR and exits (they are committed under examples/site/images)
//
//	/images/f/NAME               a file of examples/site/images, counted; ?delay=MS waits first, ?ct=TYPE overrides the
//	                             Content-Type, ?nosniff=1 adds X-Content-Type-Options: nosniff, any other query is ignored
//	/images/cors/NAME            the same with Access-Control-Allow-Origin: * (for crossorigin=anonymous)
//	/images/slow/NAME            the file one byte every 100 ms (cancellation tests); counts requests cut by the client
//	/images/gen?w=W&h=H&seed=N   a W x H JPEG made on the fly (performance test), cached per parameters
//	/images/count?path=P         requests seen for P (the path without query); /images/count?path=slow-aborted for cuts
//	/images/reset                forgets the counts
package main

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"image"
	"image/color"
		"image/draw"
	"image/gif"
	"image/jpeg"
	"image/png"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

var imageCounts = struct {
	sync.Mutex
	m map[string]int
}{m: map[string]int{}}

func countImage(key string) {
	imageCounts.Lock()
	imageCounts.m[key]++
	imageCounts.Unlock()
}

func init() {
	for i, a := range os.Args {
		if a == "-gen-images" && i+1 < len(os.Args) {
			if err := generateImages(os.Args[i+1]); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			os.Exit(0)
		}
	}
}

func imageType(name string) string {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	case ".bmp":
		return "image/bmp"
	case ".ico":
		return "image/x-icon"
	case ".tif", ".tiff":
		return "image/tiff"
	case ".webp":
		return "image/webp"
	case ".svg":
		return "image/svg+xml"
	}
	return "application/octet-stream"
}

func serveImageFile(w http.ResponseWriter, r *http.Request, prefix string, cors bool) {
	name := strings.TrimPrefix(r.URL.Path, prefix)
	countImage(r.URL.Path)
	if d, _ := strconv.Atoi(r.URL.Query().Get("delay")); d > 0 {
		time.Sleep(time.Duration(d) * time.Millisecond)
	}
	b, err := os.ReadFile(filepath.Join("examples/site/images", filepath.Base(name)))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	ct := imageType(name)
	if q := r.URL.Query().Get("ct"); q != "" {
		ct = q
	}
	w.Header().Set("Content-Type", ct)
	if r.URL.Query().Get("nosniff") == "1" {
		w.Header().Set("X-Content-Type-Options", "nosniff")
	}
	if cors {
		w.Header().Set("Access-Control-Allow-Origin", "*")
	}
	w.Write(b)
}

var genCache = struct {
	sync.Mutex
	m map[string][]byte
}{m: map[string][]byte{}}

func registerImageHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/images/f/", func(w http.ResponseWriter, r *http.Request) { serveImageFile(w, r, "/images/f/", false) })
	mux.HandleFunc("/images/cors/", func(w http.ResponseWriter, r *http.Request) { serveImageFile(w, r, "/images/cors/", true) })
	mux.HandleFunc("/images/slow/", func(w http.ResponseWriter, r *http.Request) {
		countImage(r.URL.Path)
		b, err := os.ReadFile(filepath.Join("examples/site/images", filepath.Base(strings.TrimPrefix(r.URL.Path, "/images/slow/"))))
		if err != nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", imageType(r.URL.Path))
		w.Header().Set("Content-Length", strconv.Itoa(len(b)))
		fl, _ := w.(http.Flusher)
		for i := range b {
			select {
			case <-r.Context().Done():
				countImage("slow-aborted")
				return
			case <-time.After(100 * time.Millisecond):
			}
			if _, err := w.Write(b[i : i+1]); err != nil {
				countImage("slow-aborted")
				return
			}
			if fl != nil {
				fl.Flush()
			}
		}
	})
	mux.HandleFunc("/images/gen", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		countImage(r.URL.Path)
		wd, _ := strconv.Atoi(q.Get("w"))
		ht, _ := strconv.Atoi(q.Get("h"))
		seed, _ := strconv.Atoi(q.Get("seed"))
		if wd <= 0 || ht <= 0 || wd > 8192 || ht > 8192 {
			http.Error(w, "bad size", 400)
			return
		}
		key := fmt.Sprintf("%dx%d/%d", wd, ht, seed)
		genCache.Lock()
		b, ok := genCache.m[key]
		genCache.Unlock()
		if !ok {
			img := image.NewRGBA(image.Rect(0, 0, wd, ht))
			for y := 0; y < ht; y++ {
				for x := 0; x < wd; x++ {
					img.Pix[(y*wd+x)*4+0] = uint8(x*255/wd + seed*37)
					img.Pix[(y*wd+x)*4+1] = uint8(y*255/ht + seed*11)
					img.Pix[(y*wd+x)*4+2] = uint8(seed * 53)
					img.Pix[(y*wd+x)*4+3] = 255
				}
			}
			var buf bytes.Buffer
			jpeg.Encode(&buf, img, &jpeg.Options{Quality: 80})
			b = buf.Bytes()
			genCache.Lock()
			genCache.m[key] = b
			genCache.Unlock()
		}
		w.Header().Set("Content-Type", "image/jpeg")
		w.Header().Set("Cache-Control", "no-store")
		w.Write(b)
	})
	mux.HandleFunc("/images/count", func(w http.ResponseWriter, r *http.Request) {
		imageCounts.Lock()
		n := imageCounts.m[r.URL.Query().Get("path")]
		imageCounts.Unlock()
		w.Header().Set("Access-Control-Allow-Origin", "*")
		fmt.Fprint(w, n)
	})
	mux.HandleFunc("/images/reset", func(w http.ResponseWriter, r *http.Request) {
		imageCounts.Lock()
		imageCounts.m = map[string]int{}
		imageCounts.Unlock()
		w.Header().Set("Access-Control-Allow-Origin", "*")
		io.WriteString(w, "ok")
	})
}

////////////////////////////////
// Generator

func solid(w, h int, c color.RGBA) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.Draw(img, img.Bounds(), &image.Uniform{c}, image.Point{}, draw.Src)
	return img
}

func encodePNG(img image.Image) []byte {
	var b bytes.Buffer
	png.Encode(&b, img)
	return b.Bytes()
}

func encodeJPEG(img image.Image) []byte {
	var b bytes.Buffer
	jpeg.Encode(&b, img, &jpeg.Options{Quality: 95})
	return b.Bytes()
}

// A JPEG with an EXIF APP1 segment carrying only the Orientation tag, inserted after SOI.
func withOrientation(j []byte, orientation uint16) []byte {
	var tiff bytes.Buffer
	tiff.WriteString("MM\x00\x2a")
	binary.Write(&tiff, binary.BigEndian, uint32(8)) // IFD0 offset
	binary.Write(&tiff, binary.BigEndian, uint16(1)) // one entry
	binary.Write(&tiff, binary.BigEndian, uint16(0x0112))
	binary.Write(&tiff, binary.BigEndian, uint16(3)) // SHORT
	binary.Write(&tiff, binary.BigEndian, uint32(1))
	binary.Write(&tiff, binary.BigEndian, orientation)
	binary.Write(&tiff, binary.BigEndian, uint16(0))
	binary.Write(&tiff, binary.BigEndian, uint32(0)) // no next IFD
	payload := append([]byte("Exif\x00\x00"), tiff.Bytes()...)
	var out bytes.Buffer
	out.Write(j[:2])
	out.Write([]byte{0xFF, 0xE1})
	binary.Write(&out, binary.BigEndian, uint16(len(payload)+2))
	out.Write(payload)
	out.Write(j[2:])
	return out.Bytes()
}

var testPalette = color.Palette{color.RGBA{0, 0, 0, 255}, color.RGBA{255, 0, 0, 255}, color.RGBA{0, 255, 0, 255}, color.RGBA{0, 0, 255, 255}, color.RGBA{255, 255, 0, 255}}

func paletted(w, h int, c color.Color) *image.Paletted {
	p := image.NewPaletted(image.Rect(0, 0, w, h), testPalette)
	draw.Draw(p, p.Bounds(), &image.Uniform{c}, image.Point{}, draw.Src)
	return p
}

func bmp24(w, h int, c color.RGBA) []byte {
	row := (w*3 + 3) &^ 3
	size := 54 + row*h
	var b bytes.Buffer
	b.WriteString("BM")
	binary.Write(&b, binary.LittleEndian, uint32(size))
	binary.Write(&b, binary.LittleEndian, uint32(0))
	binary.Write(&b, binary.LittleEndian, uint32(54))
	binary.Write(&b, binary.LittleEndian, uint32(40))
	binary.Write(&b, binary.LittleEndian, int32(w))
	binary.Write(&b, binary.LittleEndian, int32(h))
	binary.Write(&b, binary.LittleEndian, uint16(1))
	binary.Write(&b, binary.LittleEndian, uint16(24))
	binary.Write(&b, binary.LittleEndian, uint32(0))
	binary.Write(&b, binary.LittleEndian, uint32(row*h))
	binary.Write(&b, binary.LittleEndian, int32(2835))
	binary.Write(&b, binary.LittleEndian, int32(2835))
	binary.Write(&b, binary.LittleEndian, uint32(0))
	binary.Write(&b, binary.LittleEndian, uint32(0))
	for y := 0; y < h; y++ {
		line := make([]byte, row)
		for x := 0; x < w; x++ {
			line[x*3], line[x*3+1], line[x*3+2] = c.B, c.G, c.R
		}
		b.Write(line)
	}
	return b.Bytes()
}

// The image of an icon entry: a BITMAPINFOHEADER (height doubled for the AND mask), BGRA rows bottom-up, the mask.
func dib32(w, h int, c color.RGBA) []byte {
	var b bytes.Buffer
	le := binary.LittleEndian
	binary.Write(&b, le, uint32(40))
	binary.Write(&b, le, int32(w))
	binary.Write(&b, le, int32(h*2))
	binary.Write(&b, le, uint16(1))
	binary.Write(&b, le, uint16(32))
	binary.Write(&b, le, uint32(0))
	mask := ((w + 31) / 32) * 4 * h
	binary.Write(&b, le, uint32(w*h*4+mask))
	binary.Write(&b, le, []int32{0, 0})
	binary.Write(&b, le, []uint32{0, 0})
	for i := 0; i < w*h; i++ {
		b.Write([]byte{c.B, c.G, c.R, c.A})
	}
	b.Write(make([]byte, mask))
	return b.Bytes()
}

// An ICO of DIB images.
func icoOf(images ...[]byte) []byte {
	var b bytes.Buffer
	binary.Write(&b, binary.LittleEndian, uint16(0))
	binary.Write(&b, binary.LittleEndian, uint16(1))
	binary.Write(&b, binary.LittleEndian, uint16(len(images)))
	offset := 6 + 16*len(images)
	for _, p := range images {
		wd := int(binary.LittleEndian.Uint32(p[4:]))
		wb, hb := byte(wd), byte(wd)
		b.Write([]byte{wb, hb, 0, 0})
		binary.Write(&b, binary.LittleEndian, uint16(1))
		binary.Write(&b, binary.LittleEndian, uint16(32))
		binary.Write(&b, binary.LittleEndian, uint32(len(p)))
		binary.Write(&b, binary.LittleEndian, uint32(offset))
		offset += len(p)
	}
	for _, p := range images {
		b.Write(p)
	}
	return b.Bytes()
}

func pngChunk(b *bytes.Buffer, typ string, data []byte) {
	binary.Write(b, binary.BigEndian, uint32(len(data)))
	b.WriteString(typ)
	b.Write(data)
	crc := crc32.ChecksumIEEE(append([]byte(typ), data...))
	binary.Write(b, binary.BigEndian, crc)
}

// A PNG whose header announces w x h pixels, followed by a tiny (valid zlib, far too short) IDAT.
func pngBomb(w, h uint32) []byte {
	var b bytes.Buffer
	b.WriteString("\x89PNG\r\n\x1a\n")
	ihdr := make([]byte, 13)
	binary.BigEndian.PutUint32(ihdr[0:], w)
	binary.BigEndian.PutUint32(ihdr[4:], h)
	ihdr[8], ihdr[9] = 8, 6 // 8-bit RGBA
	pngChunk(&b, "IHDR", ihdr)
	pngChunk(&b, "IDAT", []byte{0x78, 0x9c, 0x63, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01})
	pngChunk(&b, "IEND", nil)
	return b.Bytes()
}

// A GIF whose logical screen and only frame are w x h.
func gifBomb(w, h uint16) []byte {
	var b bytes.Buffer
	b.WriteString("GIF89a")
	binary.Write(&b, binary.LittleEndian, w)
	binary.Write(&b, binary.LittleEndian, h)
	b.Write([]byte{0x80, 0, 0, 0, 0, 0, 255, 255, 255}) // global color table of 2
	b.Write([]byte{0x2C, 0, 0, 0, 0})
	binary.Write(&b, binary.LittleEndian, w)
	binary.Write(&b, binary.LittleEndian, h)
	b.Write([]byte{0, 2, 2, 0x4C, 0x01, 0, 0x3B})
	return b.Bytes()
}

// 3 x 2 uncompressed RGB TIFF.
func tiffRGB(w, h int, c color.RGBA) []byte {
	var b bytes.Buffer
	le := binary.LittleEndian
	pix := make([]byte, w*h*3)
	for i := 0; i < w*h; i++ {
		pix[i*3], pix[i*3+1], pix[i*3+2] = c.R, c.G, c.B
	}
	b.WriteString("II*\x00")
	binary.Write(&b, le, uint32(8))
	type entry struct {
		tag, typ uint16
		count    uint32
		value    uint32
	}
	n := 10
	ifdSize := 2 + n*12 + 4
	bpsOff := 8 + ifdSize
	pixOff := bpsOff + 6
	entries := []entry{
		{256, 3, 1, uint32(w)}, {257, 3, 1, uint32(h)}, {258, 3, 3, uint32(bpsOff)}, {259, 3, 1, 1},
		{262, 3, 1, 2}, {273, 4, 1, uint32(pixOff)}, {277, 3, 1, 3}, {278, 3, 1, uint32(h)},
		{279, 4, 1, uint32(len(pix))}, {284, 3, 1, 1},
	}
	binary.Write(&b, le, uint16(n))
	for _, e := range entries {
		binary.Write(&b, le, e.tag)
		binary.Write(&b, le, e.typ)
		binary.Write(&b, le, e.count)
		if e.typ == 3 && e.count == 1 {
			binary.Write(&b, le, uint16(e.value))
			binary.Write(&b, le, uint16(0))
		} else {
			binary.Write(&b, le, e.value)
		}
	}
	binary.Write(&b, le, uint32(0))
	binary.Write(&b, le, []uint16{8, 8, 8})
	b.Write(pix)
	return b.Bytes()
}

func generateImages(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	red := color.RGBA{255, 0, 0, 255}
	green := color.RGBA{0, 255, 0, 255}
	blue := color.RGBA{0, 0, 255, 255}
	files := map[string][]byte{}

	files["red.png"] = encodePNG(solid(8, 6, red))
	files["alpha.png"] = encodePNG(&image.NRGBA{Pix: bytes.Repeat([]byte{0, 0, 255, 128}, 16), Stride: 16, Rect: image.Rect(0, 0, 4, 4)})
	files["blue-2x.png"] = encodePNG(solid(40, 20, blue))
	files["green.jpg"] = encodeJPEG(solid(16, 8, green))
	// stored 20 x 10, left half red, right half blue; orientation 6 = rotate 90 clockwise to show: 10 x 20, red on top
	half := solid(20, 10, blue)
	draw.Draw(half, image.Rect(0, 0, 10, 10), &image.Uniform{red}, image.Point{}, draw.Src)
	files["orient6.jpg"] = withOrientation(encodeJPEG(half), 6)
	files["blue.bmp"] = bmp24(5, 3, blue)
	files["icon.ico"] = icoOf(dib32(16, 16, red), dib32(32, 32, blue))
	files["magenta.tif"] = tiffRGB(3, 2, color.RGBA{255, 0, 255, 255})
	files["still.gif"] = func() []byte {
		var b bytes.Buffer
		gif.Encode(&b, paletted(4, 4, color.RGBA{255, 255, 0, 255}), nil)
		return b.Bytes()
	}()
	// 10 x 10 animation, plays 3 times (loop count 2):
	//   frame 0: red everywhere, 100 ms, kept
	//   frame 1: blue 5 x 5 at the top left, 200 ms, then restored to the background (transparent)
	//   frame 2: green 5 x 5 at the bottom right, 300 ms
	files["anim.gif"] = func() []byte {
		f0 := paletted(10, 10, red)
		f1 := image.NewPaletted(image.Rect(0, 0, 5, 5), testPalette)
		draw.Draw(f1, f1.Bounds(), &image.Uniform{blue}, image.Point{}, draw.Src)
		f2 := image.NewPaletted(image.Rect(5, 5, 10, 10), testPalette)
		draw.Draw(f2, f2.Bounds(), &image.Uniform{green}, image.Point{}, draw.Src)
		g := &gif.GIF{
			Image:     []*image.Paletted{f0, f1, f2},
			Delay:     []int{10, 20, 30},
			Disposal:  []byte{gif.DisposalNone, gif.DisposalBackground, gif.DisposalNone},
			LoopCount: 2,
			Config:    image.Config{Width: 10, Height: 10, ColorModel: testPalette},
		}
		var b bytes.Buffer
		gif.EncodeAll(&b, g)
		return b.Bytes()
	}()
	files["bomb.png"] = pngBomb(100000, 100000)
	files["bomb.gif"] = gifBomb(65535, 65535)
	noise := image.NewRGBA(image.Rect(0, 0, 64, 64))
	for i := range noise.Pix {
		noise.Pix[i] = byte(i*7919 + i/3)
	}
	full := encodePNG(noise)
	files["noise.png"] = full
	files["truncated.png"] = full[:len(full)/2]
	files["fake.png"] = []byte("\x89PNX\r\n\x1a\nthis is not an image at all")
	files["text.png"] = []byte("<!doctype html><p>not an image")
	files["drawing.svg"] = []byte(`<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10" fill="red"/></svg>`)
	// Modernizr's 1 x 1 lossless WebP: decodes only where the Windows WebP codec is installed
	files["pixel.webp"], _ = base64.StdEncoding.DecodeString("UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(dir, name), data, 0o644); err != nil {
			return err
		}
	}
	return nil
}
