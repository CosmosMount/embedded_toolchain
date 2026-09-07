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
$obsolete = @{}
$removedDirs = New-Object 'System.Collections.Generic.List[string]'
$cubeShareUrl = 'https://hkustgz-my.sharepoint.com/:u:/g/personal/pnx_hkust-gz_edu_cn/IQAhhy-uMdyhTK8LwSanKsiNAShn5shcsRkNmBqSKGvIrZw?e=cpKvAb&download=1'
$scanReport = New-Object 'System.Collections.Generic.List[string]'
$status = @{}
$pathDirs = New-Object 'System.Collections.Generic.List[string]'
$discovered = @()
$versionsChecked = $false
$writeAuthorized = $false
function Confirm-WriteScope([string]$Scope) {
    if (-not $writeAuthorized) { throw 'Write access has not been authorized for the installation phase.' }
    if ((Read-Host "Allow this additional write scope: $Scope [y/N]") -ne 'y') { throw "Write scope declined: $Scope" }
}
function Banner([string]$Text) {
    Write-Host "`n+------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host '+------------------------------------------------------------+' -ForegroundColor Cyan
}
function Scan-Roots {
    param([string[]]$Roots, [IO.TextWriter]$ProgressWriter = $null)
    function Write-ScanStatus([string]$Message) {
        if ($ProgressWriter) { $ProgressWriter.WriteLine('P' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Message))); $ProgressWriter.Flush() }
        else { Write-Host $Message }
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastUpdate = -1000L
    # This function is also the entire elevated scanner: enumerate files only.
    $items = New-Object 'System.Collections.Generic.List[string]'
    $denied = New-Object 'System.Collections.Generic.List[string]'
    $otherErrors = New-Object 'System.Collections.Generic.List[string]'
    $links = New-Object 'System.Collections.Generic.List[string]'
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($root in $Roots) { if ($root) { $queue.Enqueue($root) } }
    while ($queue.Count -gt 0) {
        $dir = $queue.Dequeue()
        if (-not $visited.Add($dir.TrimEnd('\'))) { continue }
        if ($timer.ElapsedMilliseconds - $lastUpdate -ge 1000) {
            Write-ScanStatus ("[SCAN {0:0}s] directories={1} candidates={2} denied={3} errors={4} queued={5} | {6}" -f $timer.Elapsed.TotalSeconds, $visited.Count, $items.Count, $denied.Count, $otherErrors.Count, $queue.Count, $dir)
            $lastUpdate = $timer.ElapsedMilliseconds
        }
        try { $entries = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop) }
        catch {
            if ($_.CategoryInfo.Category -eq 'PermissionDenied' -or $_.Exception -is [UnauthorizedAccessException]) { $denied.Add($dir); Write-ScanStatus "[DENIED] $dir" }
            else { $otherErrors.Add("${dir}: $_"); Write-ScanStatus "[SCAN ERROR] ${dir}: $_" }
            continue
        }
        foreach ($entry in $entries) {
            if ($entry.PSIsContainer) {
                if ($entry.Name -like '.staging-*') { continue }
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    # Resolve known junction/symlink targets and deduplicate by target.
                    $targets = @($entry.Target | Where-Object { $_ })
                    if ($targets.Count -eq 0) { $links.Add($entry.FullName) }
                    foreach ($target in $targets) {
                        try {
                            $target = $target -replace '^\\\?\?\\', ''
                            if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path $entry.Parent.FullName $target }
                            $queue.Enqueue([IO.Path]::GetFullPath($target))
                        } catch { $links.Add($entry.FullName) }
                    }
                    continue
                }
                $queue.Enqueue($entry.FullName)
            } elseif ($entry.Name -match '^(cmake|git|arm-none-eabi-gcc|openocd|STM32CubeMX|ninja)\.exe$') {
                $items.Add($entry.FullName)
                Write-ScanStatus "[CANDIDATE] $($entry.FullName)"
            }
        }
    }
    Write-ScanStatus ("[SCAN DONE {0:0}s] directories={1} candidates={2} denied={3} errors={4}" -f $timer.Elapsed.TotalSeconds, $visited.Count, $items.Count, $denied.Count, $otherErrors.Count)
    [pscustomobject]@{ Items = @($items.ToArray()); Denied = @($denied.ToArray()); Errors = @($otherErrors.ToArray()); Links = @($links.ToArray()) }
}
function Read-Version([string]$File) {
    if (-not $writeAuthorized) { throw 'Executable version checks are forbidden in the read-only scan phase.' }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = New-Object Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName = $File
    $process.StartInfo.WorkingDirectory = $InstallDir
    $process.StartInfo.EnvironmentVariables['TEMP'] = $InstallDir
    $process.StartInfo.EnvironmentVariables['TMP'] = $InstallDir
    $process.StartInfo.Arguments = '--version'
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) { $process.Kill(); return '' }
        if ($process.ExitCode -ne 0) { return '' }
        if (-not $stdout.Wait(1000) -or -not $stderr.Wait(1000)) { return '' }
        return ($stdout.Result + "`n" + $stderr.Result).Trim()
    } catch { return '' } finally { $process.Dispose() }
}
function Find-Tools {
    $script:found = @{}
    $script:obsolete = @{}
    $scanReport.Clear()
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $names) {
        foreach ($cmd in @(Get-Command "$name.exe" -All -CommandType Application -ErrorAction SilentlyContinue)) { $candidates.Add($cmd.Source) }
    }
    # Full-volume discovery is now the default; DeepScan remains a compatible alias.
    $roots = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root }) + $SearchRoot
    if (Test-Path -LiteralPath $InstallDir -PathType Container -ErrorAction SilentlyContinue) { $roots += $InstallDir }
    Banner 'Scanning all mounted filesystem drives; this can take several minutes'
    $scan = Scan-Roots $roots
    if (@($scan.Denied).Count -gt 0) {
        Write-Host 'Permission denied:' -ForegroundColor Yellow
        $scan.Denied | ForEach-Object { Write-Host "  $_" }
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin -and -not [Console]::IsInputRedirected) {
            $consent = Read-Host 'Retry these directories using UAC? Only directory discovery is elevated [y/N]'
            if ($consent -eq 'y') {
                # Memory-only IPC: no temporary input, output or progress files.
                $pipe = $null; $reader = $null; $writer = $null
                try {
                    $pipeName = 'embedded-read-scan-' + [guid]::NewGuid().ToString('N')
                    $security = New-Object IO.Pipes.PipeSecurity
                    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User, (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))) {
                        $security.AddAccessRule((New-Object IO.Pipes.PipeAccessRule($sid, [IO.Pipes.PipeAccessRights]::ReadWrite, [Security.AccessControl.AccessControlType]::Allow)))
                    }
                    if ($PSVersionTable.PSEdition -eq 'Core') {
                        $pipe = [IO.Pipes.NamedPipeServerStreamAcl]::Create($pipeName, [IO.Pipes.PipeDirection]::InOut, 1, [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous, 4096, 4096, $security, [IO.HandleInheritability]::None, ([IO.Pipes.PipeAccessRights]0))
                    } else {
                        $pipe = New-Object IO.Pipes.NamedPipeServerStream($pipeName, [IO.Pipes.PipeDirection]::InOut, 1, [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous, 4096, 4096, $security)
                    }
                    $connection = $pipe.BeginWaitForConnection($null, $null)
                    $helper = "`$ErrorActionPreference = 'Stop'`n" + 'function Scan-Roots {' + ${function:Scan-Roots}.ToString() + "}`n"
                    $helper += "`$pipe = New-Object IO.Pipes.NamedPipeClientStream('.', '$pipeName', [IO.Pipes.PipeDirection]::InOut); `$pipe.Connect(30000); `$reader = New-Object IO.StreamReader(`$pipe); `$writer = New-Object IO.StreamWriter(`$pipe); `$writer.AutoFlush = `$true`n"
                    $helper += "`$roots = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$reader.ReadLine())) | ConvertFrom-Json`n"
                    $helper += "`$result = Scan-Roots -Roots `$roots -ProgressWriter `$writer; `$writer.WriteLine('R' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((`$result | ConvertTo-Json -Depth 5 -Compress)))); `$writer.Flush(); `$pipe.Dispose()"
                    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helper))
                    $child = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) -Verb RunAs -WindowStyle Hidden -PassThru
                    if (-not $connection.AsyncWaitHandle.WaitOne(30000)) { throw 'Read-only scanner did not connect.' }
                    $pipe.EndWaitForConnection($connection)
                    $reader = New-Object IO.StreamReader($pipe)
                    $writer = New-Object IO.StreamWriter($pipe)
                    $writer.AutoFlush = $true
                    $writer.WriteLine([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($scan.Denied) -Compress))))
                    $extra = $null
                    while ($true) {
                        $pendingLine = $reader.ReadLineAsync()
                        while (-not $pendingLine.Wait(5000)) { Write-Host '[SCAN READ ONLY] Still reading the current directory...' }
                        $line = $pendingLine.Result
                        if ($null -eq $line) { break }
                        $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line.Substring(1)))
                        if ($line.StartsWith('P')) { Write-Host $payload } else { $extra = $payload | ConvertFrom-Json; break }
                    }
                    $child.WaitForExit()
                    if ($child.ExitCode -ne 0) { throw "Elevated scanner exit code $($child.ExitCode)" }
                    if ($null -eq $extra -or $null -eq $extra.PSObject.Properties['Items']) { throw 'Elevated scanner returned no valid result.' }
                    $scan.Items = @($scan.Items) + @($extra.Items)
                    $scan.Denied = @($extra.Denied)
                    $scan.Errors = @($scan.Errors) + @($extra.Errors)
                    $scan.Links = @($scan.Links) + @($extra.Links)
                } catch { Write-Host "Permission retry cancelled/failed: $_" -ForegroundColor Yellow }
                finally {
                    if ($pipe) { $pipe.Dispose() }
                }
            }
        }
    }
    foreach ($p in @($scan.Items)) { $candidates.Add($p) }
    foreach ($path in @($scan.Denied)) { Write-Host "[NOT SCANNED: permission] $path" -ForegroundColor Yellow }
    foreach ($errorText in @($scan.Errors)) { Write-Host "[SCAN ERROR] $errorText" -ForegroundColor Yellow }
    foreach ($path in @($scan.Links)) { Write-Host "[DIRECTORY LINK: not followed; use -SearchRoot to scan explicitly] $path" }
    $script:discovered = @($candidates.ToArray() | Select-Object -Unique)
    $script:versionsChecked = $false
    foreach ($path in $discovered) {
        $name = [IO.Path]::GetFileNameWithoutExtension($path)
        if (-not $found.ContainsKey($name)) { $found[$name] = $path }
    }
    Write-Host '[READ ONLY] Discovery complete. No programs executed, files created, ACLs or PATH changed.'
}
function Check-DiscoveredVersions {
    if (-not $writeAuthorized) { throw 'Installation-phase authorization required.' }
    $script:found = @{}; $script:obsolete = @{}
    Banner 'Installation phase: checking versions (not part of the read-only scan)'
    foreach ($path in $discovered) {
        $name = [IO.Path]::GetFileNameWithoutExtension($path)
        $ok = $false
        $version = ''
        if ($name -eq 'STM32CubeMX') {
            $version = 'existing installation; version check disabled'
            $ok = Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue
        } else {
            $version = Read-Version $path
            switch ($name) {
                'cmake' { $ok = $version -match '^cmake version 3\.22\.6(?:\s|$)' }
                'arm-none-eabi-gcc' { $ok = $version -match '13\.3\.rel1' -and $version -match '\b13\.3\.1\b' }
                'git' { $ok = $version -match '^git version \d' }
                'ninja' { $ok = $version -match '^\d+\.\d+' }
                'openocd' { $ok = $version -match 'Open On-Chip Debugger' }
            }
        }
        $label = if ($ok) { 'MATCH' } else { 'MISMATCH / UNKNOWN / UNUSABLE' }
        $firstLine = ($version -split "`r?`n" | Select-Object -First 1)
        $scanReport.Add("[$label] $name | $firstLine | $path")
        Write-Host $scanReport[$scanReport.Count - 1]
        # Keep looking after an incompatible copy; any matching copy is reusable.
        if ($ok -and -not $found.ContainsKey($name)) { $found[$name] = $path }
        if (-not $ok -and $name -ne 'STM32CubeMX') { $obsolete[$name] = @($obsolete[$name]) + @($path) }
    }
    $script:versionsChecked = $true
}
function Show-Plan {
    Banner 'Embedded toolchain | installation plan'
    foreach ($name in $names) {
        if ($found.ContainsKey($name)) {
            $label = if ($versionsChecked -or $name -eq 'STM32CubeMX') { 'FOUND / SKIP' } else { 'FOUND / VERSION CHECK PENDING' }
            Write-Host "[$label] $name : $($found[$name])" -ForegroundColor Green
        }
        else { Write-Host "[INSTALL / REINSTALL] $name (missing, wrong version, or unverifiable)" -ForegroundColor Yellow }
    }
    Write-Host 'Targets: CMake 3.22.6 | Arm 13.3.rel1 | CubeMX 6.18.0 (optional)'
    Write-Host "New portable tools: $InstallDir"
    foreach ($name in $obsolete.Keys) { foreach ($path in @($obsolete[$name])) { if ($path) { Write-Host "[REMOVE AFTER REPLACEMENT] $path" -ForegroundColor Yellow } } }
}
function Remove-OldTool([string]$Name, [string]$NewExecutable) {
    if (-not $NewExecutable -or -not (Test-Path -LiteralPath $NewExecutable -PathType Leaf)) { throw 'No validated replacement; refusing old installation removal.' }
    foreach ($old in @($obsolete[$Name])) {
        if (-not $old -or -not (Test-Path -LiteralPath $old)) { continue }
        $oldDir = Split-Path -Parent $old
        $entries = @(foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
            Get-ItemProperty $key -ErrorAction SilentlyContinue
        })
        $product = switch ($Name) { 'cmake' { 'CMake' }; 'arm-none-eabi-gcc' { 'GNU Arm|Arm GNU|gcc-arm-none-eabi' }; 'git' { '^Git' }; 'ninja' { 'Ninja' }; 'openocd' { 'OpenOCD' } }
        $entry = $entries | Where-Object {
            $_.InstallLocation -and $_.UninstallString -and $_.DisplayName -match $product -and
            $old.StartsWith(([IO.Path]::GetFullPath($_.InstallLocation).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
        if ($entry) {
            $registeredRoot = [IO.Path]::GetFullPath($entry.InstallLocation).TrimEnd('\') + '\'
            if ($NewExecutable.StartsWith($registeredRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Old uninstaller would also own the selected new installation.' }
            Write-Host "Uninstall old package: $($entry.DisplayName) ($old)"
            Confirm-WriteScope "uninstall $($entry.DisplayName) from $registeredRoot and update its installer records"
            if ($entry.WindowsInstaller -eq 1 -and $entry.PSChildName -match '^\{[A-Fa-f0-9-]+\}$') {
                $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $entry.PSChildName, '/norestart') -Wait -PassThru
            } else {
                $command = $entry.UninstallString.Trim()
                if ($command -match '^"([^"]+\.exe)"\s*(.*)$' -or $command -match '^(.+?\.exe)(?:\s+(.*))?$') {
                    $uninstaller = $Matches[1]; $arguments = $Matches[2]
                    $start = @{ FilePath = $uninstaller; Wait = $true; PassThru = $true }
                    if ($arguments) { $start.ArgumentList = $arguments }
                    $process = Start-Process @start
                } else { throw "Unsupported uninstall command; remove this package through Installed apps: $($entry.DisplayName)" }
            }
            if ($process.ExitCode -notin @(0, 3010)) { throw "Old package uninstall failed/cancelled: $($process.ExitCode)" }
        } else {
            # Reuse only an explicit ownership marker, never infer a deletion root
            # from an executable name or blindly remove a shared bin directory.
            $root = ''
            $cursor = $oldDir
            while ($cursor -and (Split-Path -Parent $cursor)) {
                $marker = Join-Path $cursor '.embedded-toolchain-owner.json'
                if (Test-Path -LiteralPath $marker) {
                    $owner = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
                    if ($owner.tool -eq $Name -and $owner.root -eq $cursor) { $root = $cursor; break }
                }
                $cursor = Split-Path -Parent $cursor
            }
            if (-not $root) {
                Write-Host "Unregistered old tool: $old"
                $root = Read-Host "Enter the exact directory belonging ONLY to $Name to permanently remove it (empty = replacement incomplete)"
                if (-not $root) { throw "Old installation not removed: $old" }
            }
            $root = (Get-Item -LiteralPath $root).FullName.TrimEnd('\')
            $boundary = $root + '\'
            $protected = @([IO.Path]::GetPathRoot($root).TrimEnd('\'), $env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, $InstallDir, $PSScriptRoot)
            if ($protected -contains $root -or -not $old.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase) -or
                $NewExecutable.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase) -or
                @($protected | Where-Object { $_ -and $_.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { throw "Unsafe removal boundary: $root" }
            $children = @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop)
            if ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint -or
                @($children | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) { throw "Remove linked installation through its original package manager: $root" }
            if (@($children | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.exe' -and $names -contains $_.BaseName -and $_.BaseName -ne $Name }).Count -gt 0) { throw "Shared tool directory must not be removed recursively: $root" }
            Write-Host "Removing verified old installation directory: $root"
            Confirm-WriteScope "permanently delete this old installation directory: $root"
            Remove-Item -LiteralPath $root -Recurse -Force
        }
        if (Test-Path -LiteralPath $old) { throw "Old executable still exists (possibly pending reboot): $old" }
        # Keep shared system search directories; strip only tool-specific entries.
        if ($oldDir -notin @($env:WINDIR, "$env:WINDIR\System32", $env:ProgramFiles, ${env:ProgramFiles(x86)})) { $removedDirs.Add($oldDir) }
    }
}
function Add-ToolPath([string]$Executable) {
    $dir = Split-Path -Parent $Executable
    if (-not $pathDirs.Contains($dir)) { $pathDirs.Add($dir) }
    $remaining = @($env:PATH -split ';' | Where-Object { $_ -and $removedDirs -notcontains $_ -and $_.TrimEnd('\') -ine $dir.TrimEnd('\') })
    $env:PATH = (@($dir) + $remaining) -join ';'
}
function Save-Path {
    Confirm-WriteScope 'update the current user PATH registry value (machine PATH changes are requested separately)'
    $removedFile = Join-Path $InstallDir 'removed-paths.json'
    if (Test-Path -LiteralPath $removedFile) {
        foreach ($dir in @(Get-Content -LiteralPath $removedFile -Raw | ConvertFrom-Json)) { if ($dir -and -not $removedDirs.Contains($dir)) { $removedDirs.Add($dir) } }
    }
    ConvertTo-Json -InputObject @($removedDirs.ToArray()) | Set-Content -LiteralPath $removedFile -Encoding UTF8
    $old = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($pathDirs.ToArray()) + @($old -split ';' | Where-Object { $_ -and $removedDirs -notcontains $_ -and $pathDirs -notcontains $_ })
    $new = $parts -join ';'
    if ($new -ne $old) { [Environment]::SetEnvironmentVariable('Path', $new, 'User') }
    $env:PATH = ($env:PATH -split ';' | Where-Object { $removedDirs -notcontains $_ }) -join ';'
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $machineNew = ($machine -split ';' | Where-Object { $removedDirs -notcontains [Environment]::ExpandEnvironmentVariables($_) }) -join ';'
    if ($machineNew -ne $machine) {
        Write-Host 'Obsolete tool directories also occur in the machine PATH.'
        $removedDirs | ForEach-Object { Write-Host "  Remove PATH entry: $_" }
        if ((Read-Host 'Use UAC to remove these obsolete PATH entries for all users? [y/N]') -ne 'y') { throw 'Machine PATH cleanup declined; replacement is incomplete.' }
        $dirs64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($removedDirs.ToArray()) -Compress)))
        $helper = "`$ErrorActionPreference='Stop'; `$dirs = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$dirs64')) | ConvertFrom-Json; `$old=[Environment]::GetEnvironmentVariable('Path','Machine'); `$new=(`$old -split ';' | Where-Object { `$dirs -notcontains [Environment]::ExpandEnvironmentVariables(`$_) }) -join ';'; [Environment]::SetEnvironmentVariable('Path',`$new,'Machine')"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helper))
        $child = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) -Verb RunAs -WindowStyle Hidden -Wait -PassThru
        if ($child.ExitCode -ne 0) { throw 'Machine PATH cleanup failed.' }
    }
    # Windows places machine PATH before user PATH. Provide explicit activation
    # without silently modifying the machine environment for every user.
    $activation = Join-Path $InstallDir 'Activate-Toolchain.ps1'
    $lines = @('# Generated by embedded-toolchain. Run in the terminal to activate selected versions.')
    foreach ($dir in $pathDirs) {
        $literal = "'" + $dir.Replace("'", "''") + "'"
        $lines += "`$env:PATH = $literal + ';' + ((`$env:PATH -split ';' | Where-Object { `$_ -and `$_ -ine $literal }) -join ';')"
    }
    Set-Content -LiteralPath $activation -Value $lines -Encoding UTF8
    $machineDirs = @([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' | Where-Object { $_ })
    foreach ($name in $found.Keys) {
        foreach ($dir in $machineDirs) {
            $candidate = Join-Path ([Environment]::ExpandEnvironmentVariables($dir)) "$name.exe"
            if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
                if ($candidate -ine $found[$name]) {
                    Write-Host "[PATH PRIORITY] Machine PATH may select $candidate in a new terminal." -ForegroundColor Yellow
                    Write-Host "Activate the selected tools with: & '$($activation.Replace("'", "''"))'"
                }
                break
            }
        }
    }
}
function Download([string]$Url, [string]$File) {
    if (-not $writeAuthorized) { throw 'Downloads are forbidden before installation-directory write authorization.' }
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
    if (-not $writeAuthorized) { throw 'Installation-directory write authorization required.' }
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
    @{ tool = $Name; root = $dest } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dest '.embedded-toolchain-owner.json') -Encoding UTF8
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
$answer = Read-Host 'Enter I to install/reinstall required tools and repair PATH, R to change destination, or Q to quit'
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
    $blockedRoots = @([IO.Path]::GetPathRoot($InstallDir).TrimEnd('\'), $env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA)
    if ($blockedRoots -contains $InstallDir.TrimEnd('\')) { throw 'Choose a dedicated toolchain subdirectory, not a drive/system/user root.' }
    $cursor = $InstallDir
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Choose a physical installation path instead of a linked directory.' }
        $cursor = Split-Path -Parent $cursor
    }
    if ((Read-Host "Authorize creating/writing ONLY the selected installation directory: $InstallDir ? [y/N]") -ne 'y') { Wait-BeforeExit; exit 0 }
    $writeAuthorized = $true
    try {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        $probe = Join-Path $InstallDir ('.write-test-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe
        break
    } catch {
        Write-Warning "Cannot write to $InstallDir : $_"
        if ((Read-Host "Use UAC to grant this user Modify access ONLY on $InstallDir (no parent or recursive ACL edits)? [y/N]") -eq 'y') {
            try {
                $targetLiteral = "'" + $InstallDir.Replace("'", "''") + "'"
                $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                # The grant helper rejects links and requires an existing parent.
                $grant = "`$ErrorActionPreference='Stop'; `$target=$targetLiteral; `$parent=Split-Path -Parent `$target; if (-not (Test-Path -LiteralPath `$parent -PathType Container)) { throw 'Parent must already exist' }; `$cursor=`$target; while (`$cursor) { if (Test-Path -LiteralPath `$cursor) { if ((Get-Item -LiteralPath `$cursor).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked paths cannot receive this grant' } }; `$cursor=Split-Path -Parent `$cursor }; if (-not (Test-Path -LiteralPath `$target)) { New-Item -ItemType Directory -Path `$target | Out-Null }; `$acl=Get-Acl -LiteralPath `$target; `$rule=New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('$sid')), [Security.AccessControl.FileSystemRights]::Modify, [Security.AccessControl.AccessControlType]::Allow); `$acl.AddAccessRule(`$rule); Set-Acl -LiteralPath `$target -AclObject `$acl"
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($grant))
                $child = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) -Verb RunAs -WindowStyle Hidden -Wait -PassThru
                if ($child.ExitCode -ne 0) { throw 'Directory write grant failed.' }
                $probe = Join-Path $InstallDir ('.write-test-' + [guid]::NewGuid().ToString('N'))
                [IO.File]::WriteAllText($probe, ''); Remove-Item -LiteralPath $probe
                break
            } catch { Write-Warning "Selected-directory grant failed: $_" }
        }
        $writeAuthorized = $false
        $InstallDir = Read-Host 'Specify another absolute directory (empty to cancel)'
        if (-not $InstallDir) { Wait-BeforeExit; exit 1 }
        if (-not [IO.Path]::IsPathRooted($InstallDir)) { throw 'An absolute path is required.' }
        $InstallDir = [IO.Path]::GetFullPath($InstallDir)
        Find-Tools
    }
}
Confirm-WriteScope 'execute discovered command-line tools with --version for installation decisions; external programs are not OS-sandboxed'
Check-DiscoveredVersions
Show-Plan
$failed = $false
foreach ($name in $names) {
    Banner $name
    try {
        if ($found.ContainsKey($name)) {
            Add-ToolPath $found[$name]
            Remove-OldTool $name $found[$name]
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
                Install-Zip $name "https://cmake.org/files/v3.22/$file" '^cmake version 3\.22\.6(?:\s|$)' (($line -split '\s+')[0])
            }
            'arm-none-eabi-gcc' {
                Install-Zip $name 'https://developer.arm.com/-/media/Files/downloads/gnu/13.3.rel1/binrel/arm-gnu-toolchain-13.3.rel1-mingw-w64-i686-arm-none-eabi.zip' '(?s)13\.3\.rel1.*\b13\.3\.1\b'
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
                    $cubeWork = Join-Path $InstallDir ('.staging-cubemx-' + [guid]::NewGuid().ToString('N'))
                    New-Item -ItemType Directory -Path $cubeWork | Out-Null
                    $archive = Join-Path $cubeWork 'CubeMX.zip'
                    try {
                        Download $cubeShareUrl $archive
                        Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $cubeWork 'payload')
                    } catch {
                        Write-Host "Shared download/extraction failed (login, expired link or non-archive response): $_"
                        $localZip = Read-Host 'Local downloaded CubeMX ZIP (empty to skip)'
                        if (-not $localZip) { $status[$name] = 'SKIPPED (shared download unavailable)'; continue }
                        $cubeWork = Join-Path $InstallDir ('.staging-cubemx-' + [guid]::NewGuid().ToString('N'))
                        New-Item -ItemType Directory -Path $cubeWork | Out-Null
                        Expand-Archive -LiteralPath $localZip -DestinationPath (Join-Path $cubeWork 'payload')
                    }
                    $setup = @(Get-ChildItem -LiteralPath (Join-Path $cubeWork 'payload') -Recurse -File -Filter 'SetupSTM32CubeMX*.exe')
                    if ($setup.Count -ne 1) { throw 'Expected exactly one CubeMX setup executable in archive.' }
                    $CubeMXInstaller = $setup[0].FullName
                }
                if (-not $CubeMXInstaller) { $status[$name] = 'SKIPPED (optional ST login/manual download)'; continue }
                $installer = Get-Item -LiteralPath $CubeMXInstaller
                if ($installer.Extension -ne '.exe') { throw 'Supply an extracted official .exe installer.' }
                Write-Host "Launching extracted CubeMX installer. Complete its installation wizard; suggested destination: $InstallDir\STM32CubeMX"
                Confirm-WriteScope "run the CubeMX installer wizard; authorize its chosen destination and OS registration changes separately from scanning"
                $process = Start-Process -FilePath $installer.FullName -WorkingDirectory $installer.DirectoryName -Wait -PassThru
                if ($process.ExitCode -ne 0) { throw "CubeMX installer exit code: $($process.ExitCode)" }
                $cubeRoots = @($InstallDir, "$env:ProgramFiles\STMicroelectronics", "$env:ProgramFiles\STM32CubeMX", "$env:USERPROFILE\STMicroelectronics", "$env:USERPROFILE\STM32CubeMX", 'C:\ST') | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
                $cubeScan = Scan-Roots $cubeRoots
                $exePath = @($cubeScan.Items | Where-Object { [IO.Path]::GetFileName($_) -eq 'STM32CubeMX.exe' } | Select-Object -First 1)
                if ($exePath.Count -gt 0) { $exePath = $exePath[0] } else { $exePath = Read-Host 'Full path to installed STM32CubeMX.exe (empty to skip PATH setup)' }
                if (-not $exePath) { $status[$name] = 'UNVERIFIED (installer finished; PATH not configured)'; continue }
                $exe = Get-Item -LiteralPath $exePath
                if ($exe.Name -ne 'STM32CubeMX.exe') { throw 'Expected STM32CubeMX.exe.' }
                $found[$name] = $exe.FullName
                Add-ToolPath $exe.FullName
            }
        }
        if ($name -ne 'STM32CubeMX') { Remove-OldTool $name $found[$name]; Add-ToolPath $found[$name] }
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
