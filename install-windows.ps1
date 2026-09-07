#Requires -Version 5.1
<#! Run explicitly with PowerShell. No administrator rights needed for portable tools. !#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [string[]]$SearchRoot = @(),
    [switch]$DeepScan,
    [switch]$ScanOnly,
    [switch]$NoPause,
    [string]$CubeMXInstaller
)
$ErrorActionPreference = 'Stop'
function Wait-BeforeExit {
    if (-not $NoPause -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        [void](Read-Host 'Finished. Press Enter to exit (output will remain in terminal history)')
    }
}
trap {
    Write-Host "ERROR: $_"
    Wait-BeforeExit
    exit 1
}
# Native PowerShell progress panels can have a colored background. Use text
# status instead, including for Invoke-WebRequest and Expand-Archive.
$ProgressPreference = 'SilentlyContinue'
if ($env:OS -ne 'Windows_NT') { throw 'Use the Linux/macOS script on this platform.' }
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'AMD64') {
    throw 'This script supports Windows x64 only.'
}
$names = @('cmake', 'git', 'arm-none-eabi-gcc', 'openocd', 'STM32CubeMX', 'ninja')
$found = @{}
$status = @{}
$pathDirs = New-Object 'System.Collections.Generic.List[string]'
function Banner([string]$Text) {
    Write-Host "`n+------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host '+------------------------------------------------------------+' -ForegroundColor Cyan
}
function Find-Tools {
    $script:found = @{}
    foreach ($name in $names) {
        $cmd = Get-Command "$name.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $found[$name] = $cmd.Source }
    }
    $roots = @($InstallDir, 'D:\embedded_toolchain', $env:ProgramFiles, ${env:ProgramFiles(x86)},
        "$env:LOCALAPPDATA\Programs", "$env:LOCALAPPDATA\Microsoft\WinGet\Packages", "$env:USERPROFILE\ST", 'C:\ST', 'D:\ST', 'C:\Tools', 'D:\Tools', 'D:\Apps') + $SearchRoot
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        $roots += @(Get-ItemProperty $key -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'CMake|Git|GNU Arm|Arm GNU|OpenOCD|STM32CubeMX|Ninja' } |
            ForEach-Object { $_.InstallLocation })
    }
    if ($DeepScan) { $roots = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root }) }
    foreach ($root in @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique)) {
        Write-Host "Scanning: $root (unreadable folders are skipped)"
        # Do not follow directory junctions/symlinks into other volumes.
        $queue = New-Object 'System.Collections.Generic.Queue[string]'
        $queue.Enqueue($root)
        while ($queue.Count -gt 0) {
            $dir = $queue.Dequeue()
            foreach ($entry in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
                if ($entry.PSIsContainer) {
                    if ($entry.Name -notlike '.staging-*' -and -not ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $queue.Enqueue($entry.FullName) }
                } elseif ($entry.Extension -eq '.exe' -and $names -contains $entry.BaseName -and -not $found.ContainsKey($entry.BaseName)) {
                    $found[$entry.BaseName] = $entry.FullName
                }
            }
        }
    }
}
function Show-Plan {
    Banner 'Embedded toolchain | installation plan'
    foreach ($name in $names) {
        if ($found.ContainsKey($name)) { Write-Host "[FOUND / SKIP] $name : $($found[$name])" -ForegroundColor Green }
        else { Write-Host "[MISSING]      $name" -ForegroundColor Yellow }
    }
    Write-Host 'Targets: CMake 3.22.6 | Arm 13.3.rel1 | CubeMX 6.18.0 (optional)'
    Write-Host "New portable tools: $InstallDir"
}
function Add-ToolPath([string]$Executable) {
    $dir = Split-Path -Parent $Executable
    if (-not $pathDirs.Contains($dir)) { $pathDirs.Add($dir) }
    if (($env:PATH -split ';') -notcontains $dir) { $env:PATH = "$dir;$env:PATH" }
}
function Save-Path {
    $old = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($old -split ';' | Where-Object { $_ })
    foreach ($dir in $pathDirs) { if ($parts -notcontains $dir) { $parts += $dir } }
    $new = $parts -join ';'
    if ($new -ne $old) { [Environment]::SetEnvironmentVariable('Path', $new, 'User') }
}
function Download([string]$Url, [string]$File) {
    if (-not $Url.StartsWith('https://')) { throw 'Only HTTPS downloads are supported.' }
    Write-Host "Download: $Url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $File -TimeoutSec 600
    if ((Get-Item -LiteralPath $File).Length -eq 0) { throw 'Empty download.' }
}
function Release-Asset([string]$Repo, [string]$Pattern) {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'embedded-toolchain-installer' }
    $assets = @($release.assets | Where-Object { $_.name -match $Pattern })
    if ($assets.Count -ne 1) { throw "Expected one asset for $Repo / $Pattern; found $($assets.Count)." }
    return $assets[0]
}
function Install-Zip([string]$Name, [string]$Url, [string]$VersionPattern, [string]$Digest = '') {
    $work = Join-Path $InstallDir ('.staging-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $zip = Join-Path $work 'download.zip'
    Download $Url $zip
    if ($Name -eq 'arm-none-eabi-gcc') {
        $checksumFile = Join-Path $work 'sha256.txt'
        Download ($Url + '.sha256asc') $checksumFile
        $checksumText = Get-Content -LiteralPath $checksumFile -Raw
        if ($checksumText -notmatch '(?im)^([a-f0-9]{64})(?:\s|$)') { throw 'Arm SHA256 checksum not found.' }
        $Digest = $Matches[1]
    }
    if ($Digest) {
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $Digest) { throw 'SHA256 mismatch.' }
    }
    $unpack = Join-Path $work 'payload'
    Expand-Archive -LiteralPath $zip -DestinationPath $unpack
    $exe = Get-ChildItem -LiteralPath $unpack -Recurse -Filter "$Name.exe" | Select-Object -First 1
    if (-not $exe) { throw "Archive does not contain $Name.exe" }
    # Windows PowerShell 5.1 wraps native stderr (including OpenOCD version output)
    # as ErrorRecord; judge native success by the exit code instead.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $exe.FullName --version 2>&1
        $nativeExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($nativeExit -ne 0) { throw "$Name failed its version check: $output" }
    if ($VersionPattern -and "$output" -notmatch $VersionPattern) { throw "Unexpected version: $output" }
    $relative = $exe.FullName.Substring($unpack.Length)
    $dest = Join-Path $InstallDir ($Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $boundary = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\') + '\'
    foreach ($target in @($unpack, $dest)) {
        if (-not [IO.Path]::GetFullPath($target).StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Move target is outside the selected installation directory: $target"
        }
    }
    if (Test-Path -LiteralPath $dest) { throw "Destination already exists: $dest" }
    Move-Item -LiteralPath $unpack -Destination $dest
    $script:found[$Name] = $dest + $relative
    Add-ToolPath $found[$Name]
    # Keep staging downloads for troubleshooting; never remove user directories.
    Write-Host "$output" -ForegroundColor Green
}
if (-not $InstallDir) { $InstallDir = 'D:\embedded_toolchain' }
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
Find-Tools
Show-Plan
if ($ScanOnly) { Wait-BeforeExit; exit 0 }
$answer = Read-Host 'Enter I to install missing tools and repair PATH, R to change destination, or Q to quit'
if ($answer -eq 'R') {
    $InstallDir = Read-Host 'Absolute installation directory'
    if (-not [IO.Path]::IsPathRooted($InstallDir)) { throw 'An absolute path is required.' }
    $InstallDir = [IO.Path]::GetFullPath($InstallDir)
    Find-Tools
    Show-Plan
    $answer = Read-Host 'Enter I to continue, anything else to quit'
}
if ($answer -ne 'I') { Wait-BeforeExit; exit 0 }
while ($true) {
    try {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        $probe = Join-Path $InstallDir ('.write-test-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe
        break
    } catch {
        Write-Warning "Cannot write to $InstallDir : $_"
        $InstallDir = Read-Host 'Specify another absolute directory (empty to cancel)'
        if (-not $InstallDir) { Wait-BeforeExit; exit 1 }
        if (-not [IO.Path]::IsPathRooted($InstallDir)) { throw 'An absolute path is required.' }
        $InstallDir = [IO.Path]::GetFullPath($InstallDir)
        Find-Tools
    }
}
$failed = $false
foreach ($name in $names) {
    Banner $name
    try {
        if ($found.ContainsKey($name)) {
            Add-ToolPath $found[$name]
            $status[$name] = 'EXISTING (installation skipped)'
            continue
        }
        switch ($name) {
            'cmake' {
                $file = 'cmake-3.22.6-windows-x86_64.zip'
                $hashFile = Join-Path $InstallDir ('.cmake-sha-' + [guid]::NewGuid().ToString('N'))
                Download 'https://cmake.org/files/v3.22/cmake-3.22.6-SHA-256.txt' $hashFile
                $line = Get-Content -LiteralPath $hashFile | Where-Object { $_ -match ([regex]::Escape($file) + '$') }
                if (@($line).Count -ne 1) { throw 'CMake checksum not found.' }
                Install-Zip $name "https://cmake.org/files/v3.22/$file" '3\.22\.6' (($line -split '\s+')[0])
            }
            'arm-none-eabi-gcc' {
                Install-Zip $name 'https://developer.arm.com/-/media/Files/downloads/gnu/13.3.rel1/binrel/arm-gnu-toolchain-13.3.rel1-mingw-w64-i686-arm-none-eabi.zip' '13\.3\.1'
            }
            'git' {
                $asset = Release-Asset 'git-for-windows/git' '^MinGit-[0-9.]+-64-bit\.zip$'
                $digest = if ($asset.digest -match '^sha256:([a-fA-F0-9]{64})$') { $Matches[1] } else { '' }
                Install-Zip $name $asset.browser_download_url '' $digest
            }
            'ninja' {
                $asset = Release-Asset 'ninja-build/ninja' '^ninja-win\.zip$'
                $digest = if ($asset.digest -match '^sha256:([a-fA-F0-9]{64})$') { $Matches[1] } else { '' }
                Install-Zip $name $asset.browser_download_url '' $digest
            }
            'openocd' {
                $asset = Release-Asset 'xpack-dev-tools/openocd-xpack' '-win32-x64\.zip$'
                $digest = if ($asset.digest -match '^sha256:([a-fA-F0-9]{64})$') { $Matches[1] } else { '' }
                Install-Zip $name $asset.browser_download_url '' $digest
            }
            'STM32CubeMX' {
                if (-not $CubeMXInstaller) {
                    Write-Host 'Download/extract the official CubeMX 6.18.0 installer: https://www.st.com/en/development-tools/stm32cubemx.html'
                    $CubeMXInstaller = Read-Host 'Local 6.18.0 installer .exe (empty to skip)'
                }
                if (-not $CubeMXInstaller) { $status[$name] = 'SKIPPED (optional ST login/manual download)'; continue }
                $installer = Get-Item -LiteralPath $CubeMXInstaller
                if ($installer.Extension -ne '.exe') { throw 'Supply an extracted official .exe installer.' }
                if ((Read-Host 'Confirm this is the official CubeMX 6.18.0 installer: type 6.18.0') -ne '6.18.0') {
                    $status[$name] = 'SKIPPED'; continue
                }
                $process = Start-Process -FilePath $installer.FullName -Wait -PassThru
                if ($process.ExitCode -ne 0) { throw "CubeMX installer exit code: $($process.ExitCode)" }
                $exePath = Read-Host 'Full path to installed STM32CubeMX.exe (empty to skip PATH setup)'
                if (-not $exePath) { $status[$name] = 'UNVERIFIED (installer finished; PATH not configured)'; continue }
                $exe = Get-Item -LiteralPath $exePath
                if ($exe.Name -ne 'STM32CubeMX.exe') { throw 'Expected STM32CubeMX.exe.' }
                Add-ToolPath $exe.FullName
            }
        }
        $status[$name] = 'INSTALLED'
    } catch {
        $failed = $true
        $status[$name] = "FAILED: $_"
        Write-Warning "$name : $_"
    }
}
try { Save-Path; Write-Host 'User PATH saved. Open a new terminal; restart its parent app if needed.' }
catch { $failed = $true; Write-Warning "Cannot persist user PATH: $_" }
Banner 'Summary'
foreach ($name in $names) { Write-Host ('{0,-20} {1}' -f $name, $status[$name]) }
Write-Host 'Downloads/staging are retained in the installation directory for diagnosis.'
Wait-BeforeExit
if ($failed) { exit 1 }
