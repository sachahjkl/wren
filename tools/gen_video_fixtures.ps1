# Makes the video test files of examples\site\media\video (committed: tests do not need FFmpeg).
# Needs FFmpeg on PATH (libx264, libsvtav1, libvpx-vp9, libopus, aac).
#   powershell -NoProfile -File tools\gen_video_fixtures.ps1
# clip.mp4         H.264 main (B-frames) + AAC-LC 44.1 kHz stereo, 320x180, 24 fps, 4 s: FFmpeg's testsrc2;
#                  the tone steps every second (440, 550, 660, 770 Hz). Progressive: moov first.
# clip_moov_end.mp4 the same with moov at the end (what FFmpeg writes by default).
# clip_frag.mp4    the same as fragmented MP4 (one fragment per keyframe): what Media Source Extensions append.
# clip.webm        AV1 + Opus.
# clip_vp9.webm    VP9 + Opus (demuxing only: no decoder is promised for VP9).
# tone_opus.webm   the tone of clip.mp4 as Opus only, in WebM (the audio-only source buffer of Media Source Extensions).
# clip_av1_video.webm  the video track of clip.webm alone (a video-only source buffer; tone_opus.webm is the audio one).
# clip_live.webm   clip.webm as a live stream: Segment and Clusters of unknown size, no Cues.
# clip_vp8.webm    VP8, 160x90, 1 s, no audio (demuxing only: Wren has no VP8 decoder).
# quad.mp4         64x32, four quadrants red / lime / blue / white, BT.709 limited range, 1 s, no audio: exact pixels.
# tone.m4a         AAC-LC audio only, 2 s, 440 Hz.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'examples\site\media\video'
New-Item -ItemType Directory -Force $out | Out-Null
function F {
    param([string[]]$ffargs)
    $ErrorActionPreference = 'Continue'   # (FFmpeg's warnings on stderr are not failures)
    & ffmpeg -hide_banner -loglevel error -y @ffargs 2>&1 | Where-Object { $_ -notmatch 'Fontconfig' } | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg $ffargs" }
}

$v = 'testsrc2=s=320x180:r=24:d=4'
$a = 'aevalsrc=sin(2*PI*t*(440+floor(t)*110))*0.3|sin(2*PI*t*(440+floor(t)*110))*0.3:s=44100:d=4'
$enc = @('-c:v', 'libx264', '-profile:v', 'main', '-preset', 'medium', '-bf', '2', '-g', '24', '-pix_fmt', 'yuv420p', '-crf', '28', '-c:a', 'aac', '-b:a', '64k', '-shortest')
$src = @('-f', 'lavfi', '-i', $v, '-f', 'lavfi', '-i', $a)
F ($src + $enc + @('-movflags', '+faststart', (Join-Path $out 'clip.mp4')))
F ($src + $enc + @((Join-Path $out 'clip_moov_end.mp4')))
F @('-i', (Join-Path $out 'clip.mp4'), '-c', 'copy', '-movflags', 'frag_keyframe+empty_moov+default_base_moof+separate_moof', (Join-Path $out 'clip_frag.mp4'))
F @('-i', (Join-Path $out 'clip.mp4'), '-c:v', 'libsvtav1', '-preset', '10', '-crf', '40', '-g', '24', '-c:a', 'libopus', '-b:a', '48k', (Join-Path $out 'clip.webm'))
F @('-i', (Join-Path $out 'clip.mp4'), '-c:v', 'libvpx-vp9', '-b:v', '200k', '-g', '24', '-deadline', 'realtime', '-cpu-used', '8', '-c:a', 'libopus', '-b:a', '48k', (Join-Path $out 'clip_vp9.webm'))
F @('-i', (Join-Path $out 'clip.mp4'), '-vn', '-c:a', 'libopus', '-b:a', '48k', (Join-Path $out 'tone_opus.webm'))
F @('-f', 'lavfi', '-i', 'testsrc2=s=160x90:r=24:d=1', '-c:v', 'libvpx', '-b:v', '100k', '-g', '12', '-deadline', 'realtime', '-cpu-used', '8', '-an', (Join-Path $out 'clip_vp8.webm'))

F @('-i', (Join-Path $out 'clip.webm'), '-an', '-c', 'copy', (Join-Path $out 'clip_av1_video.webm'))
F @('-i', (Join-Path $out 'clip.webm'), '-c', 'copy', '-live', '1', '-f', 'webm', (Join-Path $out 'clip_live.webm'))

$q = 'color=c=red:s=32x16:d=1,format=yuv420p[a];color=c=lime:s=32x16:d=1,format=yuv420p[b];color=c=blue:s=32x16:d=1,format=yuv420p[c];color=c=white:s=32x16:d=1,format=yuv420p[d];[a][b][c][d]xstack=inputs=4:layout=0_0|w0_0|0_h0|w0_h0'
F @('-filter_complex', $q, '-r', '24', '-c:v', 'libx264', '-preset', 'slow', '-crf', '10', '-pix_fmt', 'yuv420p', '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-color_range', 'tv', '-movflags', '+faststart', '-an', (Join-Path $out 'quad.mp4'))
F @('-f', 'lavfi', '-i', 'sine=frequency=440:duration=2', '-c:a', 'aac', '-b:a', '64k', '-movflags', '+faststart', (Join-Path $out 'tone.m4a'))
Get-ChildItem $out | Select-Object Name, Length
