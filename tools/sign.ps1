# Signs executables with Authenticode (signtool), timestamps the signature (RFC 3161: it stays valid after the certificate
# expires) and checks it. tools\package.ps1 calls it on wren.exe and testserver.exe; it does nothing unless a signing
# identity is configured, so a build without one packages unsigned files as before.
#   powershell -NoProfile -File tools\sign.ps1 -Files a.exe, b.exe
#
# The identity comes from the environment (the CI passes its secrets there; nothing here is stored in the repository):
#   SIGN_PFX            path of a .pfx file, with SIGN_PFX_PASSWORD. A certificate whose private key can be exported: only a
#                       test one (secrets\development.yaml: CODESIGN_TEST_PFX_BASE64), because certificate authorities no
#                       longer hand out exportable keys for public code signing (the key stays in a hardware module).
#   SIGN_SERVICE=azure  Azure Artifact Signing: SIGN_AZURE_DLIB (Azure.CodeSigning.Dlib.dll) and SIGN_AZURE_METADATA (the
#                       metadata .json: endpoint, account, certificate profile); credentials from the Azure environment.
#                       SignPath, which signs from the CI by uploading the artifact, does not go through this script.
#   SIGN_TIMESTAMP      the timestamp server (default http://timestamp.digicert.com; Azure: http://timestamp.acs.microsoft.com)
#   SIGN_TEST=1         the certificate is a self-signed test one: the signature is checked for its content (the signer, the
#                       hash), not for the trust of the chain, which a test certificate can not have.
#   SIGNTOOL            path of signtool.exe (default: the newest x64 one of the Windows SDK)
param([Parameter(Mandatory)][string[]]$Files)
$ErrorActionPreference = 'Stop'

$pfx = $env:SIGN_PFX
$service = $env:SIGN_SERVICE
if (-not $pfx -and -not $service) { Write-Host 'sign: no signing identity configured (SIGN_PFX or SIGN_SERVICE): files left unsigned'; exit 0 }
if ($pfx -and $service) { throw 'sign: SIGN_PFX and SIGN_SERVICE are both set: choose one' }

$signtool = $env:SIGNTOOL
if (-not $signtool) {
    $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $signtool -or -not (Test-Path $signtool)) { throw 'sign: signtool.exe not found (install the Windows SDK, or set SIGNTOOL)' }

$stamp = if ($env:SIGN_TIMESTAMP) { $env:SIGN_TIMESTAMP } elseif ($service -eq 'azure') { 'http://timestamp.acs.microsoft.com' } else { 'http://timestamp.digicert.com' }
$describe = '/d', 'Wren', '/du', 'https://github.com/sachahjkl/wren'

foreach ($f in $Files) {
    $path = (Resolve-Path $f).Path
    if ($pfx) {
        if (-not (Test-Path $pfx)) { throw "sign: SIGN_PFX points to nothing: $pfx" }
        # the password goes to signtool by /p: this is the only place that sees it
        & $signtool sign /fd SHA256 /f $pfx /p $env:SIGN_PFX_PASSWORD /tr $stamp /td SHA256 @describe $path
    } elseif ($service -eq 'azure') {
        if (-not $env:SIGN_AZURE_DLIB -or -not $env:SIGN_AZURE_METADATA) { throw 'sign: SIGN_SERVICE=azure needs SIGN_AZURE_DLIB and SIGN_AZURE_METADATA' }
        & $signtool sign /fd SHA256 /tr $stamp /td SHA256 /dlib $env:SIGN_AZURE_DLIB /dmdf $env:SIGN_AZURE_METADATA @describe $path
    } else { throw "sign: unknown SIGN_SERVICE '$service' (azure)" }
    if ($LASTEXITCODE) { throw "sign: signtool failed on $path" }

    if ($env:SIGN_TEST -eq '1') {
        $sig = Get-AuthenticodeSignature $path
        if (-not $sig.SignerCertificate) { throw "sign: $path has no signature" }
        if ($sig.Status -eq 'HashMismatch') { throw "sign: the signature of $path does not match its content" }
        if (-not $sig.TimeStamperCertificate) { throw "sign: the signature of $path is not timestamped" }
        Write-Host "sign: $path signed by $($sig.SignerCertificate.Subject) (test certificate: the chain is not trusted, as expected), timestamped"
    } else {
        & $signtool verify /pa /v $path | Select-Object -Last 3
        if ($LASTEXITCODE) { throw "sign: $path does not verify (signtool verify /pa)" }
    }
}
