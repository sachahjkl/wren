# Refreshes the embedded Public Suffix List (src\url\public_suffix_list.dat) from publicsuffix.org.
#   powershell -File tools\update_psl.ps1
# The file is embedded with #load: rebuild afterwards, and run the url tests.
$root = Split-Path $PSScriptRoot -Parent
$dest = Join-Path $root 'src\url\public_suffix_list.dat'
Invoke-WebRequest -Uri https://publicsuffix.org/list/public_suffix_list.dat -OutFile $dest -UseBasicParsing
$version = Select-String -Path $dest -Pattern '^// VERSION' | Select-Object -First 1
"updated: $($version.Line)"
