# SPDX-License-Identifier: GPL-3.0-only

function Test-FFBAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FFBFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '') }
    finally { $sha256.Dispose(); $stream.Dispose() }
}

function Get-FFBStateDirectory {
    if ($env:FFB_INTERCEPTOR_PACKAGE_TEST -eq '1' -and
        -not [string]::IsNullOrWhiteSpace($env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY)) {
        $override = Get-FFBNormalizedLocalPath -Path $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY
        $temporaryRoot = Get-FFBNormalizedLocalPath -Path ([IO.Path]::GetTempPath())
        if (-not (Test-FFBPathWithinOrEqual -Path $override -Parent $temporaryRoot) -or
            $override -notmatch '(?i)[\\/]ffb-launcher-package-smoke-[a-f0-9]+[\\/]state$') {
            throw "Unsafe isolated package-test state path: $override"
        }
        return $override
    }
    $commonData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($commonData)) { throw 'Common application data is unavailable.' }
    return Join-Path $commonData 'FFBInterceptor'
}

function Get-FFBStatePath {
    return Join-Path (Get-FFBStateDirectory) 'simhub-plugin-state.json'
}

function Get-FFBNormalizedLocalPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]') {
        throw "Only an absolute local drive path is allowed: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        $full = $full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    }
    return $full
}

function Test-FFBPathWithinOrEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )
    if ($Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $parentPrefix = $Parent.TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    return $Path.StartsWith($parentPrefix,
        [StringComparison]::OrdinalIgnoreCase)
}

function Test-FFBPathEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )
    return $Left.Equals($Right, [StringComparison]::OrdinalIgnoreCase)
}

function Get-FFBSimHubExecutablePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    foreach ($name in @('SimHubWPF.exe', 'SimHub.exe')) {
        $candidate = Join-Path $Path $name
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $item = Get-Item -LiteralPath $candidate -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "The SimHub executable cannot be a reparse point: $candidate"
        }
        return $item.FullName
    }
    return ''
}

function Assert-FFBSimHubRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$RequireExecutable
    )
    $full = Get-FFBNormalizedLocalPath -Path $Path
    $root = [IO.Path]::GetPathRoot($full)
    $trimmedFull = $full.TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $trimmedRoot = $root.TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (Test-FFBPathEqual -Left $trimmedFull -Right $trimmedRoot) {
        throw "A drive root cannot be used as the SimHub directory: $full"
    }
    if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { throw 'SystemRoot is unavailable.' }
    $windowsRoot = Get-FFBNormalizedLocalPath -Path $env:SystemRoot
    if (Test-FFBPathWithinOrEqual -Path $full -Parent $windowsRoot) {
        throw "The Windows directory cannot be used as the SimHub directory: $full"
    }
    if (Test-Path -LiteralPath $full) {
        $directoryItem = Get-Item -LiteralPath $full -Force
        if (-not $directoryItem.PSIsContainer -or
            ($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "The SimHub directory cannot be a reparse point: $full"
        }
    }
    if ($RequireExecutable) {
        $simHubExecutable = Get-FFBSimHubExecutablePath -Path $full
        if ([string]::IsNullOrWhiteSpace($simHubExecutable)) {
            throw "SimHubWPF.exe or SimHub.exe was not found in: $full"
        }
    }
    return $full
}

function Assert-FFBPluginState {
    param(
        [Parameter(Mandatory = $true)]$State,
        [switch]$RequireSimHubExecutable
    )
    foreach ($property in @('SchemaVersion', 'InstallPath', 'Files')) {
        if ($null -eq $State.PSObject.Properties[$property]) { throw "The plug-in state is missing: $property" }
    }
    if ([string]$State.SchemaVersion -ne '1') { throw 'Unsupported SimHub plug-in state schema.' }

    $installPath = Assert-FFBSimHubRoot -Path ([string]$State.InstallPath) `
        -RequireExecutable:$RequireSimHubExecutable
    if ($env:FFB_INTERCEPTOR_PACKAGE_TEST -eq '1' -and
        -not [string]::IsNullOrWhiteSpace($env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY)) {
        $expectedTestRoot = Get-FFBNormalizedLocalPath -Path `
            (Join-Path (Split-Path -Parent (Get-FFBStateDirectory)) 'fake-simhub')
        if (-not (Test-FFBPathEqual -Left $installPath -Right $expectedTestRoot)) {
            throw "The isolated package test cannot manage this SimHub directory: $installPath"
        }
    }
    $expected = @{}
    foreach ($name in @('FFBInterceptor.SimHub.dll', 'FFBInterceptor.Core.dll')) {
        $expected[$name.ToLowerInvariant()] = Get-FFBNormalizedLocalPath -Path (Join-Path $installPath $name)
    }

    $files = @($State.Files)
    if ($files.Count -ne $expected.Count) { throw 'The plug-in state must contain exactly two managed files.' }
    $seen = @{}
    $validated = New-Object System.Collections.ArrayList
    foreach ($file in $files) {
        foreach ($property in @('Destination', 'Backup', 'BackupSha256', 'InstalledSha256', 'Changed')) {
            if ($null -eq $file.PSObject.Properties[$property]) { throw "A managed-file record is missing: $property" }
        }
        if ($file.Changed -isnot [bool]) { throw 'A managed-file Changed value is not Boolean.' }
        $destination = Get-FFBNormalizedLocalPath -Path ([string]$file.Destination)
        $nameKey = [IO.Path]::GetFileName($destination).ToLowerInvariant()
        if (-not $expected.ContainsKey($nameKey) -or
            -not (Test-FFBPathEqual -Left $destination -Right $expected[$nameKey]) -or
            $seen.ContainsKey($nameKey)) {
            throw "The plug-in state contains an unexpected or duplicate destination: $destination"
        }
        $seen[$nameKey] = $true

        $hash = ([string]$file.InstalledSha256).ToUpperInvariant()
        if ($hash -notmatch '^[A-F0-9]{64}$') { throw "The plug-in state contains an invalid SHA-256: $destination" }
        $changed = [bool]$file.Changed
        $backup = [string]$file.Backup
        if (-not $changed -and -not [string]::IsNullOrWhiteSpace($backup)) {
            throw "An unmanaged file cannot have a recorded backup: $destination"
        }
        if (-not [string]::IsNullOrWhiteSpace($backup)) {
            $backup = Get-FFBNormalizedLocalPath -Path $backup
            $backupPrefix = [regex]::Escape($destination + '.ffb-interceptor-backup')
            if ($backup -notmatch "^$backupPrefix(?:\.[1-9][0-9]*)?$") {
                throw "The plug-in state contains an unsafe backup path: $backup"
            }
        }
        $backupHash = ([string]$file.BackupSha256).ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($backup)) {
            if (-not [string]::IsNullOrWhiteSpace($backupHash)) {
                throw "A missing backup cannot have a recorded SHA-256: $destination"
            }
        }
        elseif ($backupHash -notmatch '^[A-F0-9]{64}$') {
            throw "The plug-in state contains an invalid backup SHA-256: $backup"
        }

        [void]$validated.Add([pscustomobject][ordered]@{
            Destination = $destination
            Backup = $backup
            BackupSha256 = $backupHash
            InstalledSha256 = $hash
            Changed = $changed
        })
    }
    if ($seen.Count -ne $expected.Count) { throw 'The plug-in state is incomplete.' }
    $installedAt = ''
    if ($null -ne $State.PSObject.Properties['InstalledAtUtc']) { $installedAt = [string]$State.InstalledAtUtc }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        InstalledAtUtc = $installedAt
        InstallPath = $installPath
        Files = @($validated)
    }
}

function Get-FFBAclIdentifiers {
    return [pscustomobject]@{
        Administrators = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
        System = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
        Users = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::BuiltinUsersSid, $null)
        CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent().User
    }
}

function Set-FFBProtectedDirectoryAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $isAdministrator = Test-FFBAdministrator
    $isolatedTest = $env:FFB_INTERCEPTOR_PACKAGE_TEST -eq '1'
    if (-not $isAdministrator -and -not $isolatedTest) {
        throw 'Administrator rights are required to protect installation state.'
    }
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "The state directory is not a regular directory: $Path"
        }
    }
    [IO.Directory]::CreateDirectory($Path) | Out-Null
    $ids = Get-FFBAclIdentifiers
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $none = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($(if ($isAdministrator) { $ids.Administrators } else { $ids.CurrentUser }))
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $ids.Administrators, [Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance, $none, $allow))
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $ids.System, [Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance, $none, $allow))
    if (-not $isAdministrator) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $ids.CurrentUser, [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance, $none, $allow))
    }
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $ids.Users, [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        $inheritance, $none, $allow))
    [IO.Directory]::SetAccessControl($Path, $security)
}

function Set-FFBProtectedFileAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "The state file is not a regular file: $Path"
    }
    $ids = Get-FFBAclIdentifiers
    $isAdministrator = Test-FFBAdministrator
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($(if ($isAdministrator) { $ids.Administrators } else { $ids.CurrentUser }))
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $ids.Administrators, [Security.AccessControl.FileSystemRights]::FullControl, $allow))
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $ids.System, [Security.AccessControl.FileSystemRights]::FullControl, $allow))
    if (-not $isAdministrator) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $ids.CurrentUser, [Security.AccessControl.FileSystemRights]::FullControl, $allow))
    }
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $ids.Users, [Security.AccessControl.FileSystemRights]::ReadAndExecute, $allow))
    [IO.File]::SetAccessControl($Path, $security)
}

function Test-FFBProtectedAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('File', 'Directory')][string]$Kind
    )
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            ($Kind -eq 'File' -and $item.PSIsContainer) -or
            ($Kind -eq 'Directory' -and -not $item.PSIsContainer)) { return $false }
        $security = if ($Kind -eq 'File') { [IO.File]::GetAccessControl($Path) } else { [IO.Directory]::GetAccessControl($Path) }
        if (-not $security.AreAccessRulesProtected) { return $false }
        $ids = Get-FFBAclIdentifiers
        $isolatedTest = $env:FFB_INTERCEPTOR_PACKAGE_TEST -eq '1'
        $owner = $security.GetOwner([Security.Principal.SecurityIdentifier])
        if (-not $owner.Equals($ids.Administrators) -and -not $owner.Equals($ids.System) -and
            (-not $isolatedTest -or -not $owner.Equals($ids.CurrentUser))) { return $false }
        $dangerous = [Security.AccessControl.FileSystemRights]::Write -bor
            [Security.AccessControl.FileSystemRights]::Delete -bor
            [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
            [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
            [Security.AccessControl.FileSystemRights]::TakeOwnership
        $rules = $security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
        foreach ($rule in $rules) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            $sid = [Security.Principal.SecurityIdentifier]$rule.IdentityReference
            if ($sid.Equals($ids.Administrators) -or $sid.Equals($ids.System)) { continue }
            if ($isolatedTest -and $sid.Equals($ids.CurrentUser)) { continue }
            if (($rule.FileSystemRights -band $dangerous) -ne 0) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Test-FFBStateProtection {
    $directory = Get-FFBStateDirectory
    $path = Get-FFBStatePath
    return (Test-Path -LiteralPath $directory -PathType Container) -and
        (Test-Path -LiteralPath $path -PathType Leaf) -and
        (Test-FFBProtectedAcl -Path $directory -Kind Directory) -and
        (Test-FFBProtectedAcl -Path $path -Kind File)
}

function Read-FFBPluginState {
    param([switch]$AllowMissing, [switch]$RequireSimHubExecutable)
    $path = Get-FFBStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if ($AllowMissing) { return $null }
        throw "No managed SimHub plug-in installation was found: $path"
    }
    if (-not (Test-FFBStateProtection)) { throw "The SimHub plug-in state is not administrator-protected: $path" }
    $item = Get-Item -LiteralPath $path
    if ($item.Length -gt 65536) { throw "The SimHub plug-in state is too large: $path" }
    try { $state = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { throw "The SimHub plug-in state is invalid: $path" }
    return Assert-FFBPluginState -State $state -RequireSimHubExecutable:$RequireSimHubExecutable
}

function Save-FFBPluginState {
    param([Parameter(Mandatory = $true)]$State)
    $validated = Assert-FFBPluginState -State $State -RequireSimHubExecutable
    $directory = Get-FFBStateDirectory
    $path = Get-FFBStatePath
    if (Test-Path -LiteralPath $path) { throw "Refusing to overwrite existing plug-in state: $path" }
    Set-FFBProtectedDirectoryAcl -Path $directory
    $temporary = Join-Path $directory ('.simhub-plugin-state-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, ($validated | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        Set-FFBProtectedFileAcl -Path $temporary
        [IO.File]::Move($temporary, $path)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}
