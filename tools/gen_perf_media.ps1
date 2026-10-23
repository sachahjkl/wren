# Makes the 1080p files of the yt_* scenarios of tools\perf.ps1 (examples\site\yt-sim.html) in examples\site\media\video\perf_*
# (not committed: 100 MB). Needs FFmpeg on PATH (libx264, libsvtav1, aac). Skips files that exist; -Force makes them again.
#   powershell -NoProfile -File tools\gen_perf_media.ps1 [-Force]
# perf_h264_1080p60   1920x1080, 60 fps, H.264 high@4.2 + AAC, 30 s: the video a browser has to keep up with at 60 Hz
# perf_av1_1080p30    1920x1080, 30 fps, AV1 (SVT-AV1) + AAC, 30 s
# perf_short_1080x1920 1080x1920, 30 fps, H.264 + AAC, 30 s: a Short
# For each, _frag (one fragmented file), _v and _a (the video and the audio alone, fragmented: what a DASH player appends
# to two SourceBuffers). The picture is FFmpeg's testsrc2 with temporal noise (a bit rate like real video's).
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$out = Join-Path (Split-Path $PSScriptRoot -Parent) 'examples\site\media\video'
New-Item -ItemType Directory -Force $out | Out-Null
function F([string[]]$ffargs) {
    # (FFmpeg's encoder banners on stderr are not failures: a failure is the exit code)
    $p = Start-Process ffmpeg -ArgumentList (@('-hide_banner', '-loglevel', 'error', '-y') + $ffargs) -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "ffmpeg $ffargs" }
}
$aud = 'aevalsrc=0.2*sin(2*PI*t*440)|0.2*sin(2*PI*t*554):s=48000:d=30'
function Make($name, [string]$video, [string[]]$codec) {
    $mp4 = Join-Path $out "$name.mp4"
    if ((Test-Path $mp4) -and -not $Force) { Write-Host "$name exists"; return }
    F (@('-f', 'lavfi', '-i', $video, '-f', 'lavfi', '-i', $aud) + $codec + @('-c:a', 'aac', '-b:a', '128k', '-shortest', '-movflags', '+faststart', $mp4))
    $frag = @('-c', 'copy', '-movflags', 'frag_keyframe+empty_moov+default_base_moof+separate_moof')
    F (@('-i', $mp4) + $frag + @((Join-Path $out "${name}_frag.mp4")))
    F (@('-i', $mp4, '-an') + $frag + @((Join-Path $out "${name}_v.mp4")))
    F (@('-i', $mp4, '-vn') + $frag + @((Join-Path $out "${name}_a.mp4")))
    Write-Host "made $name"
}
$h264 = @('-c:v', 'libx264', '-profile:v', 'high', '-level', '4.2', '-preset', 'veryfast', '-crf', '27', '-pix_fmt', 'yuv420p')
Make 'perf_h264_1080p60' 'testsrc2=s=1920x1080:r=60:d=30,noise=alls=5:allf=t' ($h264 + @('-g', '120', '-bf', '2'))
Make 'perf_av1_1080p30' 'testsrc2=s=1920x1080:r=30:d=30,noise=alls=5:allf=t' @('-c:v', 'libsvtav1', '-preset', '9', '-crf', '38', '-g', '120', '-pix_fmt', 'yuv420p')
Make 'perf_short_1080x1920' 'testsrc2=s=1080x1920:r=30:d=30,noise=alls=5:allf=t' ($h264 + @('-g', '60', '-bf', '2'))
