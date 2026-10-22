# Noto Color Emoji (COLR v1) for the built-in emoji (text.emoji = builtin): the toolkit's script, pinned by commit and SHA-256,
# writes build\emoji\NotoColorEmoji-COLRv1.ttf (+ OFL.txt), which src/browser/font_settings.odin compiles into wren.exe (#load).
#   tools\fetch_emoji.ps1            the font and its license
#   tools\fetch_emoji.ps1 -Unicode   also Unicode's emoji-test.txt and emoji-data.txt (the toolkit's tests/colr use them)
param([switch]$Unicode, [string]$Dest = '')
$root = Split-Path $PSScriptRoot -Parent
if (-not $Dest) { $Dest = Join-Path $root 'build\emoji' }
$args2 = @{ Dest = $Dest }
if ($Unicode) { $args2.Unicode = $true }
& (Join-Path $root 'ext\gui_toolkit\tools\fetch_emoji.ps1') @args2