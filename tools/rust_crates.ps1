# Writes native\media\rust-crates.txt: every Rust crate linked into wren_media.lib (the image decoders), with its license
# and source, from cargo metadata of the locked graph. wren.exe embeds the file (src\browser\about_wren.odin: about:licenses),
# so the release needs no folder of licenses beside the program.
#   powershell -NoProfile -File tools\rust_crates.ps1          writes the file
#   powershell -NoProfile -File tools\rust_crates.ps1 -Check   fails when the file is not what Cargo.lock says (package.ps1)
param([switch]$Check)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$file = Join-Path $root 'native\media\rust-crates.txt'
$ErrorActionPreference = 'Continue'   # cargo reports progress on stderr ("Updating crates.io index")
$json = & cargo metadata --manifest-path (Join-Path $root 'native\media\Cargo.toml') --format-version 1 --locked --all-features 2>$null   # (all features: the toolkit's text backend, gt_text, is the optional `text` feature that the release builds with: its crates (ICU4X, Fontations...) are linked into wren.exe)
$ok = $LASTEXITCODE -eq 0
$ErrorActionPreference = 'Stop'
if (-not $ok -or -not $json) { throw 'cargo metadata failed' }
$meta = $json | ConvertFrom-Json
$lines = @('Rust crates of native/media (wren_media.lib, linked into wren.exe), from Cargo.lock: the whole graph, with the',
           'build-time and test-only crates (they are not in wren.exe).',
           'Each crate''s license text is in its source package (crates.io) or repository.', '')
foreach ($p in ($meta.packages | Where-Object { $_.name -ne 'wren_media' } | Sort-Object name, version)) {
    $lines += ('{0} {1}  [{2}]  {3}' -f $p.name, $p.version, $p.license, $(if ($p.repository) { $p.repository } else { "https://crates.io/crates/$($p.name)" }))
}
$text = ($lines -join "`n") + "`n"
if ($Check) {
    if (-not (Test-Path $file) -or [IO.File]::ReadAllText($file).Replace("`r`n", "`n") -ne $text) { throw 'native\media\rust-crates.txt is out of date: run tools\rust_crates.ps1 and commit it' }
    'rust-crates.txt is up to date'
} else {
    [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding $false))
    "wrote $file ($($lines.Count - 4) crates)"
}
