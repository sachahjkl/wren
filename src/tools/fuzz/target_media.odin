package fuzz

import "wb:media"

MP4_FILES := []Seed_Files{{dir = "examples/site/media", suffixes = {".mp4", ".m4a", ".m4v"}}}
WEBM_FILES := []Seed_Files{{dir = "examples/site/media", suffixes = {".webm", ".mkv"}}}

// A box tree with the boxes the demuxer descends into, sizes left to the mutations.
MP4_SEEDS := []string{
	"\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2\x00\x00\x00\x08moov\x00\x00\x00\x08mdat",
	"\x00\x00\x00\x08moov\x00\x00\x00\x6cmvhd\x00\x00\x00\x00",
	"\x00\x00\x00\x10moof\x00\x00\x00\x08traf\x00\x00\x00\x10mdat\x00\x00\x00\x00\x00\x00\x00\x00",
	"\x00\x00\x00\x01mdat\x00\x00\x00\x00\xff\xff\xff\xff",
}

MP4_TOKENS := []string{
	"ftyp", "moov", "mvhd", "trak", "tkhd", "mdia", "mdhd", "hdlr", "minf", "stbl", "stsd", "stts", "stsc", "stsz", "stz2", "stco", "co64",
	"ctts", "stss", "edts", "elst", "mvex", "trex", "moof", "mfhd", "traf", "tfhd", "tfdt", "trun", "mdat", "avc1", "avcC", "hvc1", "hvcC",
	"av01", "av1C", "vp09", "vpcC", "mp4a", "esds", "Opus", "dOps", "colr", "nclx", "sidx", "free", "uuid", "vide", "soun",
	"\x00\x00\x00\x00", "\x00\x00\x00\x01", "\xff\xff\xff\xff", "\x7f\xff\xff\xff", "\x00\x00\x00\x08",
}

// EBML header, a Segment of unknown size, Info, Tracks with one track, a Cluster with a SimpleBlock.
WEBM_SEEDS := []string{
	"\x1a\x45\xdf\xa3\x9f\x42\x86\x81\x01\x42\xf7\x81\x01\x42\xf2\x81\x04\x42\xf3\x81\x08\x42\x82\x84webm\x42\x87\x81\x04\x42\x85\x81\x02" +
	"\x18\x53\x80\x67\x01\xff\xff\xff\xff\xff\xff\xff" +
	"\x15\x49\xa9\x66\x88\x2a\xd7\xb1\x83\x0f\x42\x40\x00" +
	"\x16\x54\xae\x6b\x92\xae\x90\xd7\x81\x01\x83\x81\x01\x86\x85V_VP9\xe0\x84\xb0\x81\x10\xba\x81\x10" +
	"\x1f\x43\xb6\x75\x01\xff\xff\xff\xff\xff\xff\xff\xe7\x81\x00\xa3\x86\x81\x00\x00\x80\x00\x00",
}

WEBM_TOKENS := []string{
	"\x1a\x45\xdf\xa3", "\x18\x53\x80\x67", "\x15\x49\xa9\x66", "\x16\x54\xae\x6b", "\x1f\x43\xb6\x75", "\x1c\x53\xbb\x6b", "\xae", "\xd7", "\x83",
	"\x86", "\xe0", "\xe1", "\xa3", "\xa0", "\xa1", "\xe7", "\x9b", "\x75\xa2", "\x63\xa2", "\x2a\xd7\xb1", "\x44\x89", "V_VP8", "V_VP9", "V_AV1",
	"A_OPUS", "A_VORBIS", "\x01\xff\xff\xff\xff\xff\xff\xff", "\x08\x00\x00\x00\x00\x00\x00\x00", "\x81", "\x40\x00", "\xff",
}

MEDIA_TEXT_SEEDS := []string{
	"WEBVTT\n\n00:00.000 --> 00:01.000\nHello\n",
	"WEBVTT - title\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\nREGION\nid:r\nwidth:40%\nlines:3\nregionanchor:0%,100%\nviewportanchor:10%,90%\nscroll:up\n\nSTYLE\n::cue { color: red }\n\nNOTE a note\n\n1\n00:00:01.000 --> 00:00:02.500 position:10%,line-left align:start size:35% line:-1 vertical:rl region:r\n<v Bob>a <b>b</b> <i.x>c</i> <c.y.z>d</c> <ruby>e<rt>f</rt></ruby> <00:00:01.500>g &amp; &lt;&gt;&nbsp;&lrm;</v>\n",
	"video/mp4; codecs=\"avc1.42E01E, mp4a.40.2\"",
	"video/webm; codecs=\"vp09.00.10.08, opus\"",
	"audio/mp4; codecs=\"av01.0.04M.08\", video/mp4;codecs=hvc1.1.6.L93.B0",
	"audio/ogg; codecs=vorbis", "application/vnd.apple.mpegurl", "audio/mpeg",
}

MEDIA_TEXT_TOKENS := []string{
	"WEBVTT", "-->", "\n\n", "NOTE", "STYLE", "REGION", "::cue", ":", ".", "%", ",", "<v ", "<b>", "</b>", "<c.", "<ruby>", "<rt>", "<00:00:00.000>",
	"&amp;", "&", "position:", "line:", "align:", "size:", "vertical:", "region:", "codecs=", "\"", ";", "avc1.", "mp4a.40.", "vp09.", "av01.", "hvc1.",
}

// What the demuxers hand the decoder: a sample's bytes are the sink's, and freed at once.
@(private = "file")
media_sink :: proc() -> media.Demux_Sink {
	return media.Demux_Sink{
		tracks = proc(user: rawptr, tracks: []media.Track, duration: media.Time) {},
		sample = proc(user: rawptr, track: int, s: media.Sample) {
			s := s
			media.sample_destroy(&s)
		},
	}
}

// (a network cut: a box or an element split across two feeds, where a demuxer keeps state)
@(private = "file")
chunk_of :: proc(data: []u8) -> int { return len(data) > 0 ? 1 + int(data[len(data) / 2]) % 509 : 1 }

target_mp4 :: proc(data: []u8) {
	feed_mp4(data, max(len(data), 1))
	feed_mp4(data, chunk_of(data))
}

@(private = "file")
feed_mp4 :: proc(data: []u8, chunk: int) {
	limits := media.MP4_LIMITS_DEFAULT
	limits.max_box_bytes = 16 << 20
	limits.max_retain_bytes = 64 << 20
	limits.max_samples = 100_000
	d: media.Mp4_Demuxer
	media.mp4_init(&d, media_sink(), limits)
	defer media.mp4_destroy(&d)
	for at := 0; at < len(data); at += chunk {
		if media.mp4_feed(&d, data[at:min(at + chunk, len(data))]) != .None { break }
	}
}

target_webm :: proc(data: []u8) {
	feed_webm(data, max(len(data), 1))
	feed_webm(data, chunk_of(data))
}

@(private = "file")
feed_webm :: proc(data: []u8, chunk: int) {
	limits := media.WEBM_LIMITS_DEFAULT
	limits.max_element_bytes = 16 << 20
	d: media.Webm_Demuxer
	media.webm_init(&d, media_sink(), limits)
	defer media.webm_destroy(&d)
	for at := 0; at < len(data); at += chunk {
		if media.webm_feed(&d, data[at:min(at + chunk, len(data))]) != .None { break }
	}
}

target_media_text :: proc(data: []u8) {
	text := string(data)
	f := media.vtt_parse(text)
	media.vtt_destroy(&f)
	cue := media.vtt_cue_from_text(text)
	media.vtt_cue_destroy(&cue)
	t, _ := media.parse_type(text)
	media.parsed_type_destroy(&t)
}
