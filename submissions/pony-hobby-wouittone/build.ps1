param([string]$OpenSSLDirectory = '')
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
New-Item -ItemType Directory -Force bin | Out-Null

function Invoke-Checked([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE" }
}

function Get-Tool([string]$Name, [string]$Version, [string]$Archive) {
    $existing = Get-Command $Name -ErrorAction SilentlyContinue
    if ($existing) { return $existing.Source }
    $dest = Join-Path $PSScriptRoot "bin\tools\$Name"
    New-Item -ItemType Directory -Force $dest | Out-Null
    $zip = Join-Path $dest $Archive
    $url = "https://github.com/ponylang/$Name/releases/download/$Version/$Archive"
    Invoke-WebRequest $url -OutFile $zip
    $checksum = "$zip.sha512"
    Invoke-WebRequest "$url.sha512" -OutFile $checksum
    $expected = ((Get-Content $checksum -Raw) -split '\s+')[0]
    if ((Get-FileHash $zip -Algorithm SHA512).Hash -ine $expected) {
        throw "$Name archive checksum mismatch"
    }
    Expand-Archive $zip $dest -Force
    return (Get-ChildItem $dest -Recurse -Filter "$Name.exe" |
        Select-Object -First 1).FullName
}

$ponyc = Get-Tool ponyc 0.77.2 ponyc-x86-64-pc-windows-msvc.zip
$corral = Get-Tool corral 0.9.2 corral-x86-64-pc-windows-msvc.zip
$zigDir = Join-Path $PSScriptRoot 'bin\tools\zig-x86_64-windows-0.15.1'
$zig = Join-Path $zigDir 'zig.exe'
if (-not (Test-Path $zig)) {
    $tools = Join-Path $PSScriptRoot 'bin\tools'
    New-Item -ItemType Directory -Force $tools | Out-Null
    $zip = Join-Path $tools 'zig.zip'
    Invoke-WebRequest 'https://ziglang.org/download/0.15.1/zig-x86_64-windows-0.15.1.zip' -OutFile $zip
    if ((Get-FileHash $zip -Algorithm SHA256).Hash -ine
        '91e69e887ca8c943ce9a515df3af013d95a66a190a3df3f89221277ebad29e34') {
        throw 'Zig archive checksum mismatch'
    }
    Expand-Archive $zip $tools -Force
}

if (-not $OpenSSLDirectory) {
    foreach ($candidate in @(
        'C:\Program Files\Git\ucrt64\bin',
        'C:\Program Files\Git\mingw64\bin'
    )) {
        if (Test-Path (Join-Path $candidate 'libcrypto-3-x64.dll')) {
            $OpenSSLDirectory = $candidate
            break
        }
    }
}
if (-not $OpenSSLDirectory) { throw 'Specify an OpenSSL 3 DLL directory with -OpenSSLDirectory' }

function New-ImportLibrary([string]$Library, [string]$Dll) {
    $image = [IO.File]::ReadAllBytes((Join-Path $OpenSSLDirectory $Dll))
    function U32([int]$Offset) { [BitConverter]::ToUInt32($image, $Offset) }
    $pe = U32 0x3c
    $count = [BitConverter]::ToUInt16($image, $pe + 6)
    $sections = $pe + 24 + [BitConverter]::ToUInt16($image, $pe + 20)
    function FileOffset([uint32]$Rva) {
        for ($i = 0; $i -lt $count; $i++) {
            $section = $sections + ($i * 40)
            $start = U32 ($section + 12)
            $size = [Math]::Max((U32 ($section + 8)), (U32 ($section + 16)))
            if ($Rva -ge $start -and $Rva -lt ($start + $size)) {
                return (U32 ($section + 20)) + $Rva - $start
            }
        }
        throw "Unmapped export RVA $Rva"
    }
    $exports = FileOffset (U32 ($pe + 24 + 112))
    $names = FileOffset (U32 ($exports + 32))
    $symbols = for ($i = 0; $i -lt (U32 ($exports + 24)); $i++) {
        $start = FileOffset (U32 ($names + ($i * 4)))
        $end = $start
        while ($image[$end] -ne 0) { $end++ }
        [Text.Encoding]::ASCII.GetString($image, $start, $end - $start)
    }
    $def = Join-Path $PSScriptRoot "bin\$Library.def"
    "LIBRARY $Dll`nEXPORTS`n$($symbols -join "`n")`n" |
        Set-Content $def -Encoding ascii
    Invoke-Checked $zig @('dlltool', '-m', 'i386:x86-64', '-d', $def,
        '-l', (Join-Path $PSScriptRoot "bin\$Library.lib"))
}

New-ImportLibrary crypto libcrypto-3-x64.dll
New-ImportLibrary ssl libssl-3-x64.dll
$native = Join-Path $PSScriptRoot 'bin\native'
New-Item -ItemType Directory -Force $native | Out-Null
$revision = '3354bb81eea489e972b0a7c63231514ab34f73a0'
foreach ($file in @('crypt_blowfish.c', 'crypt_blowfish.h')) {
    Invoke-WebRequest "https://raw.githubusercontent.com/openwall/crypt_blowfish/$revision/$file" `
        -OutFile (Join-Path $native $file)
}
Invoke-Checked $zig @('cc', '-target', 'x86_64-windows-msvc', '-O2', '-c',
    (Join-Path $native 'crypt_blowfish.c'), '-o', (Join-Path $native 'bcrypt.obj'))
Invoke-Checked $zig @('cc', '-target', 'x86_64-windows-msvc', '-O2', '-c',
    'native\bcrypt_support.c', '-o', (Join-Path $native 'support.obj'))
Invoke-Checked $zig @('ar', 'rcs', 'bin\conduit_bcrypt.lib',
    (Join-Path $native 'bcrypt.obj'), (Join-Path $native 'support.obj'))

Invoke-Checked $corral @('fetch')
foreach ($target in @('conduit', 'tests')) {
    $name = if ($target -eq 'tests') { 'unit-tests' } else { 'conduit' }
    Invoke-Checked $corral @('run', '--', $ponyc, '-D', 'openssl_3.0.x',
        '-p', 'bin', '--output', 'bin', '--bin-name', $name, $target)
}
$env:PATH = "$OpenSSLDirectory;$env:PATH"
Invoke-Checked '.\bin\unit-tests.exe' @()
