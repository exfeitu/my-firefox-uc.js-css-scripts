#Requires -Version 5.1
<#
.SYNOPSIS
    Firefox UC 脚本一键安装工具
.DESCRIPTION
    自动检测 Firefox 安装路径和配置文件，
    自动安装 UC 脚本加载器 (config.js + defaults)、
    用户脚本 (.uc.js)、用户样式 (userChrome.css)、
    自动配置 about:config 偏好、
    自动安装 Sidebery 扩展、
    自动清除启动缓存。
.NOTES
    仓库: https://github.com/exfeitu/my-firefox-uc.js-css-scripts
    适用: Firefox ESR 128
#>

# ============================================================
#  配置区域
# ============================================================

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# 需要复制到 Firefox 安装目录的文件
$InstallFolder_Files = @("config.js")
$InstallFolder_Dirs  = @("defaults")

# 需要复制到 chrome 文件夹的文件
$Chrome_Files = @("MouseGestures.uc.js", "sidebarResizerAndAutohide.uc.js", "userChrome.css")
$Chrome_Dirs  = @("utils")

# 需要写入 user.js 的偏好设置
$ManagedPrefs = @{
    "toolkit.legacyUserProfileCustomizations.stylesheets" = $true
    "browser.tabs.loadBookmarksInTabs"                    = $true
    "browser.search.openintab"                            = $true
}

# Sidebery 扩展文件名
$SideberyXpi = "sidebery-5.3.3.xpi"

# Firefox 安装包
$FirefoxInstallerZip = "Firefox Setup 128.14.0esr.zip"

# user.js 托管标记
$UserJS_StartMarker = "// ===== UC-INSTALLER-MANAGED-START ====="
$UserJS_EndMarker   = "// ===== UC-INSTALLER-MANAGED-END ====="

# ============================================================
#  工具函数
# ============================================================

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host ">>> $Message" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Message)
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Warn2 {
    param([string]$Message)
    Write-Host "    [!] $Message" -ForegroundColor Yellow
}

function Write-Err2 {
    param([string]$Message)
    Write-Host "    [X] $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "    [i] $Message" -ForegroundColor Gray
}

function Test-IsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-CanWriteToFolder {
    param([string]$Path)
    try {
        $testFile = Join-Path $Path ".uc_write_test_$(Get-Random)"
        [System.IO.File]::WriteAllText($testFile, "test")
        Remove-Item $testFile -Force
        return $true
    } catch {
        return $false
    }
}

# ============================================================
#  Firefox 路径检测
# ============================================================

function Get-FirefoxInstallPath {
    # 方法 1: 注册表 App Paths
    try {
        $reg = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe" -ErrorAction SilentlyContinue
        if ($reg.'(default)') {
            $exePath = $reg.'(default)'
            if (Test-Path $exePath) { return Split-Path -Parent $exePath }
        }
    } catch {}

    # 方法 2: 注册表 Mozilla (64-bit)
    foreach ($root in @("HKLM:\SOFTWARE\Mozilla\Mozilla Firefox", "HKLM:\SOFTWARE\WOW6432Node\Mozilla\Mozilla Firefox")) {
        try {
            if (Test-Path $root) {
                $versions = Get-ChildItem $root -ErrorAction SilentlyContinue
                foreach ($ver in $versions) {
                    $mainKey = Join-Path $ver.PSPath "Main"
                    if (Test-Path $mainKey) {
                        $main = Get-ItemProperty -Path $mainKey -ErrorAction SilentlyContinue
                        if ($main.PathToExe -and (Test-Path $main.PathToExe)) {
                            return Split-Path -Parent $main.PathToExe
                        }
                    }
                }
            }
        } catch {}
    }

    # 方法 3: where.exe
    try {
        $exePath = (where.exe firefox 2>$null | Select-Object -First 1)
        if ($exePath -and (Test-Path $exePath)) {
            $resolved = (Get-Item $exePath -ErrorAction SilentlyContinue).Target
            if ($resolved) { return Split-Path -Parent $resolved }
            return Split-Path -Parent $exePath
        }
    } catch {}

    # 方法 4: 常见安装路径
    $drives = (Get-PSDrive -PSProvider FileSystem).Name
    foreach ($drive in $drives) {
        foreach ($sub in @("\Mozilla Firefox", "\Program Files\Mozilla Firefox", "\Program Files (x86)\Mozilla Firefox")) {
            $candidate = "${drive}:$sub"
            if (Test-Path (Join-Path $candidate "firefox.exe")) { return $candidate }
        }
    }

    return $null
}

function Get-FirefoxVersion {
    param([string]$InstallPath)
    $exePath = Join-Path $InstallPath "firefox.exe"
    if (-not (Test-Path $exePath)) { return $null }
    try {
        $version = (Get-Item $exePath).VersionInfo.ProductVersion
        return $version
    } catch { return $null }
}

function Get-FirefoxProfiles {
    $profilesIni = Join-Path $env:APPDATA "Mozilla\Firefox\profiles.ini"
    if (-not (Test-Path $profilesIni)) { return @() }

    $content = Get-Content $profilesIni -ErrorAction SilentlyContinue
    if (-not $content) { return @() }

    $firefoxDir = Join-Path $env:APPDATA "Mozilla\Firefox"

    # 解析 INI
    $sections = [ordered]@{}
    $currentSection = $null

    foreach ($line in $content) {
        if ($line -match '^\[(.+)\]$') {
            $currentSection = $matches[1]
            $sections[$currentSection] = @{}
        } elseif ($line -match '^([^=]+)=(.*)$' -and $currentSection) {
            $sections[$currentSection][$matches[1].Trim()] = $matches[2].Trim()
        }
    }

    # 收集 Profile 段落
    $profiles = @()
    foreach ($key in $sections.Keys) {
        if ($key -match '^Profile\d+$') {
            $data = $sections[$key]
            $path = $null
            if ($data.Path) {
                if ($data.IsRelative -eq '1') {
                    $path = Join-Path $firefoxDir $data.Path
                } else {
                    $path = $data.Path
                }
            }
            $profiles += [PSCustomObject]@{
                Name     = $data.Name
                Path     = $data.Path
                FullPath = $path
                Default  = ($data.Default -eq '1')
                IsESR    = ($data.Path -like '*.default-esr')
            }
        }
    }

    return $profiles
}

function Select-FirefoxProfile {
    $profiles = Get-FirefoxProfiles

    if ($profiles.Count -eq 0) {
        return $null
    }

    if ($profiles.Count -eq 1) {
        $p = $profiles[0]
        if ($p.FullPath -and (Test-Path $p.FullPath)) {
            Write-OK "检测到唯一配置文件: $($p.Name)"
            return $p.FullPath
        }
        return $null
    }

    # 多个配置文件: 查找默认
    $default = $profiles | Where-Object { $_.Default } | Select-Object -First 1
    if (-not $default) {
        $default = $profiles | Where-Object { $_.IsESR } | Select-Object -First 1
    }
    if (-not $default) {
        $default = $profiles | Select-Object -First 1
    }

    # 让用户选择
    Write-Step "检测到 $($profiles.Count) 个 Firefox 配置文件，请选择:"
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $p = $profiles[$i]
        $marker = if ($p.Default) { " (默认)" } elseif ($p.IsESR) { " (ESR)" } else { "" }
        $exists = if ($p.FullPath -and (Test-Path $p.FullPath)) { "" } else { " [路径不存在]" }
        Write-Host "  [$i] $($p.Name)$marker$exists"
        Write-Host "      $($p.FullPath)" -ForegroundColor DarkGray
    }

    $defaultIdx = [array]::IndexOf($profiles, $default)
    $choice = Read-Host "`n  请输入序号 (直接回车 = $defaultIdx)"

    if ([string]::IsNullOrWhiteSpace($choice)) {
        $selected = $default
    } else {
        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 0 -and $idx -lt $profiles.Count) {
            $selected = $profiles[$idx]
        } else {
            Write-Err2 "无效的输入"
            return $null
        }
    }

    if (-not $selected.FullPath -or -not (Test-Path $selected.FullPath)) {
        Write-Err2 "配置文件路径不存在: $($selected.FullPath)"
        return $null
    }

    return $selected.FullPath
}

# ============================================================
#  Firefox 运行检测
# ============================================================

function Test-FirefoxRunning {
    $procs = Get-Process -Name "firefox" -ErrorAction SilentlyContinue
    return ($procs.Count -gt 0)
}

function Stop-Firefox {
    Write-Warn2 "正在关闭 Firefox..."
    try {
        Get-Process -Name "firefox" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-OK "Firefox 已关闭"
    } catch {
        Write-Err2 "无法自动关闭 Firefox: $_"
    }
}

# ============================================================
#  文件复制
# ============================================================

function Copy-InstallFolderFiles {
    param([string]$InstallPath)

    $copied = 0
    $failed = 0

    # 复制文件
    foreach ($file in $InstallFolder_Files) {
        $src = Join-Path $ScriptDir $file
        $dst = Join-Path $InstallPath $file
        if (-not (Test-Path $src)) {
            Write-Warn2 "源文件不存在，跳过: $file"
            continue
        }
        try {
            Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop
            Write-OK "已复制 $file -> $InstallPath"
            $copied++
        } catch {
            Write-Err2 "复制失败 $file : $_"
            $failed++
        }
    }

    # 复制目录
    foreach ($dir in $InstallFolder_Dirs) {
        $src = Join-Path $ScriptDir $dir
        $dst = Join-Path $InstallPath $dir
        if (-not (Test-Path $src)) {
            Write-Warn2 "源目录不存在，跳过: $dir"
            continue
        }
        try {
            # 确保 defaults/pref 目录存在
            if (-not (Test-Path $dst)) {
                New-Item -Path $dst -ItemType Directory -Force | Out-Null
            }
            # 递归复制内容
            Get-ChildItem $src -Recurse | ForEach-Object {
                $relPath = $_.FullName.Substring($src.Length)
                $targetPath = Join-Path $dst $relPath
                if ($_.PSIsContainer) {
                    New-Item -Path $targetPath -ItemType Directory -Force | Out-Null
                } else {
                    $targetDir = Split-Path -Parent $targetPath
                    if (-not (Test-Path $targetDir)) {
                        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
                    }
                    Copy-Item -Path $_.FullName -Destination $targetPath -Force -ErrorAction Stop
                }
            }
            Write-OK "已复制 $dir/ -> $InstallPath\$dir"
            $copied++
        } catch {
            Write-Err2 "复制失败 $dir/ : $_"
            $failed++
        }
    }

    return ($failed -eq 0)
}

function Copy-ChromeFolderFiles {
    param([string]$ProfilePath)

    $chromeDir = Join-Path $ProfilePath "chrome"
    if (-not (Test-Path $chromeDir)) {
        New-Item -Path $chromeDir -ItemType Directory -Force | Out-Null
        Write-OK "已创建 chrome 文件夹: $chromeDir"
    }

    $copied = 0
    $failed = 0

    # 复制文件
    foreach ($file in $Chrome_Files) {
        $src = Join-Path $ScriptDir $file
        $dst = Join-Path $chromeDir $file
        if (-not (Test-Path $src)) {
            Write-Warn2 "源文件不存在，跳过: $file"
            continue
        }
        try {
            Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop
            Write-OK "已复制 $file -> chrome/"
            $copied++
        } catch {
            Write-Err2 "复制失败 $file : $_"
            $failed++
        }
    }

    # 复制目录
    foreach ($dir in $Chrome_Dirs) {
        $src = Join-Path $ScriptDir $dir
        $dst = Join-Path $chromeDir $dir
        if (-not (Test-Path $src)) {
            Write-Warn2 "源目录不存在，跳过: $dir"
            continue
        }
        try {
            if (Test-Path $dst) {
                Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
            }
            Copy-Item -Path $src -Destination $dst -Force -Recurse -ErrorAction Stop
            Write-OK "已复制 $dir/ -> chrome/$dir/"
            $copied++
        } catch {
            Write-Err2 "复制失败 $dir/ : $_"
            $failed++
        }
    }

    return ($failed -eq 0)
}

# ============================================================
#  user.js 偏好设置
# ============================================================

function Update-UserJS {
    param([string]$ProfilePath)

    $userJSPath = Join-Path $ProfilePath "user.js"

    # 构建托管配置内容
    $managedLines = @($UserJS_StartMarker)
    foreach ($key in $ManagedPrefs.Keys) {
        $value = $ManagedPrefs[$key]
        if ($value -is [bool]) {
            $valueStr = if ($value) { 'true' } else { 'false' }
        } elseif ($value -is [string]) {
            $valueStr = "`"$value`""
        } else {
            $valueStr = $value.ToString()
        }
        $managedLines += "user_pref(`"$key`", $valueStr);"
    }
    $managedLines += $UserJS_EndMarker
    $managedBlock = $managedLines -join "`n"

    # 读取现有 user.js
    $existingContent = ""
    if (Test-Path $userJSPath) {
        $existingContent = [System.IO.File]::ReadAllText($userJSPath)
    }

    # 移除旧的托管段落 (如果存在)
    if ($existingContent) {
        $pattern = "(?s)`r?`n?" + [regex]::Escape($UserJS_StartMarker) + ".*?" + [regex]::Escape($UserJS_EndMarker) + "`r?`n?"
        $existingContent = [regex]::Replace($existingContent, $pattern, "")
        $existingContent = $existingContent.TrimEnd()
    }

    # 合并写入
    if ($existingContent) {
        $finalContent = $existingContent + "`n`n" + $managedBlock + "`n"
    } else {
        $finalContent = $managedBlock + "`n"
    }

    try {
        [System.IO.File]::WriteAllText($userJSPath, $finalContent, [System.Text.UTF8Encoding]::new($false))
        Write-OK "已写入 user.js ($($ManagedPrefs.Count) 项偏好设置)"
    } catch {
        Write-Err2 "写入 user.js 失败: $_"
    }
}

# ============================================================
#  Sidebery 扩展安装
# ============================================================

function Get-ExtensionId {
    param([string]$XpiPath)
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($XpiPath)
        $entry = $zip.GetEntry('manifest.json')
        if ($entry) {
            $reader = New-Object System.IO.StreamReader($entry.Open())
            $manifest = $reader.ReadToEnd() | ConvertFrom-Json
            $reader.Close()

            if ($manifest.browser_specific_settings.gecko.id) {
                return $manifest.browser_specific_settings.gecko.id
            }
            if ($manifest.applications.gecko.id) {
                return $manifest.applications.gecko.id
            }
        }
        $zip.Dispose()
    } catch {
        Write-Warn2 "读取扩展 ID 失败: $_"
    }
    return $null
}

function Install-Sidebery {
    param([string]$ProfilePath)

    $xpiSource = Join-Path $ScriptDir $SideberyXpi
    if (-not (Test-Path $xpiSource)) {
        Write-Warn2 "未找到 $SideberyXpi，跳过 Sidebery 扩展安装"
        Write-Info "请手动安装 Sidebery 扩展"
        return
    }

    # 提取扩展 ID
    $extensionId = Get-ExtensionId -XpiPath $xpiSource
    if (-not $extensionId) {
        Write-Warn2 "无法确定 Sidebery 扩展 ID，跳过自动安装"
        Write-Info "请手动将 $SideberyXpi 拖入 Firefox 窗口安装"
        return
    }

    # 复制到 extensions 文件夹
    $extDir = Join-Path $ProfilePath "extensions"
    if (-not (Test-Path $extDir)) {
        New-Item -Path $extDir -ItemType Directory -Force | Out-Null
    }

    $xpiDest = Join-Path $extDir "$extensionId.xpi"
    try {
        Copy-Item -Path $xpiSource -Destination $xpiDest -Force -ErrorAction Stop
        Write-OK "已安装 Sidebery 扩展 (ID: $extensionId)"
        Write-Info "如扩展未自动启用，请在 about:addons 中手动启用"
    } catch {
        Write-Err2 "Sidebery 安装失败: $_"
    }
}

# ============================================================
#  清除启动缓存
# ============================================================

function Clear-StartupCache {
    param([string]$ProfilePath)

    $cacheDir = Join-Path $ProfilePath "startupCache"
    if (Test-Path $cacheDir) {
        try {
            Remove-Item $cacheDir -Recurse -Force -ErrorAction Stop
            Write-OK "已清除启动缓存"
        } catch {
            Write-Err2 "清除启动缓存失败: $_"
            Write-Info "可手动在 about:support 页面点击「清除启动缓存」"
        }
    } else {
        Write-OK "启动缓存不存在 (无需清除)"
    }

    # 同时清除 prefs.js 中的启动缓存标记
    # (确保下次启动时重新加载所有自定义脚本)
}

# ============================================================
#  Firefox 安装 (可选)
# ============================================================

function Find-SevenZip {
    # 常见 7-Zip 安装路径
    $paths = @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        "$env:LOCALAPPDATA\Programs\7-Zip\7z.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    # where.exe
    try {
        $found = (where.exe 7z 2>$null | Select-Object -First 1)
        if ($found -and (Test-Path $found)) { return $found }
    } catch {}
    return $null
}

function Get-SplitZipParts {
    # 查找分卷压缩包的所有部分 (z01, z02, ..., zip)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FirefoxInstallerZip)
    $parts = @()

    # 查找 .z01, .z02, ... 格式的分卷
    $splitFiles = Get-ChildItem -Path $ScriptDir -Filter "$baseName.z??" -ErrorAction SilentlyContinue |
        Sort-Object Name
    foreach ($f in $splitFiles) {
        $parts += $f.FullName
    }

    # 主 .zip 文件 (分卷格式的最后一个部分)
    $mainZip = Join-Path $ScriptDir $FirefoxInstallerZip
    if (Test-Path $mainZip) {
        $parts += $mainZip
    }

    return $parts
}

function Install-Firefox {
    $mainZip = Join-Path $ScriptDir $FirefoxInstallerZip
    if (-not (Test-Path $mainZip)) {
        Write-Err2 "未找到 Firefox 安装包: $FirefoxInstallerZip"
        return $false
    }

    Write-Step "准备安装 Firefox ESR 128..."

    $extractDir = Join-Path $env:TEMP "uc-installer-ff-setup"
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    New-Item -Path $extractDir -ItemType Directory -Force | Out-Null

    # 检查是否有分卷文件
    $parts = Get-SplitZipParts
    $isSplit = ($parts.Count -gt 1)

    $extractSuccess = $false

    if ($isSplit) {
        Write-Info "检测到分卷压缩包 ($($parts.Count) 个部分)"

        # 方法 1: 尝试 7-Zip
        $sevenZip = Find-SevenZip
        if ($sevenZip) {
            Write-Info "使用 7-Zip 解压: $sevenZip"
            try {
                # 7z 能直接处理分卷，只需指向最后一个 .zip 文件
                & $sevenZip x $mainZip "-o$extractDir" -y -aoa 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $extractSuccess = $true
                    Write-OK "7-Zip 解压成功"
                }
            } catch {
                Write-Warn2 "7-Zip 解压失败: $_"
            }
        }

        # 方法 2: 合并分卷后用 Expand-Archive
        if (-not $extractSuccess) {
            Write-Info "尝试合并分卷文件..."
            $combinedZip = Join-Path $env:TEMP "uc-installer-firefox-combined.zip"
            try {
                # 按 z01, z02, ..., zip 顺序合并
                $sortedParts = $parts | Sort-Object {
                    $ext = [System.IO.Path]::GetExtension($_)
                    if ($ext -match '\.z(\d+)') { [int]$matches[1] }
                    else { [int]::MaxValue }  # .zip 排最后
                }

                # 使用 .NET FileStream 合并 (比 copy /b 更可靠)
                $outStream = [System.IO.File]::Create($combinedZip)
                $buffer = New-Object byte[] 1048576  # 1MB buffer
                foreach ($part in $sortedParts) {
                    Write-Info "  合并: $(Split-Path -Leaf $part)"
                    $inStream = [System.IO.File]::OpenRead($part)
                    while ($inStream.Position -lt $inStream.Length) {
                        $read = $inStream.Read($buffer, 0, $buffer.Length)
                        $outStream.Write($buffer, 0, $read)
                    }
                    $inStream.Close()
                    $inStream.Dispose()
                }
                $outStream.Close()
                $outStream.Dispose()

                Write-Info "合并完成，正在解压..."
                Expand-Archive -Path $combinedZip -DestinationPath $extractDir -Force
                $extractSuccess = $true
                Write-OK "分卷合并解压成功"

                # 清理合并文件
                Remove-Item $combinedZip -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Err2 "合并分卷失败: $_"
                Write-Info "请安装 7-Zip 后重试: https://7-zip.org/"
            }
        }
    } else {
        # 普通单文件 ZIP
        try {
            Expand-Archive -Path $mainZip -DestinationPath $extractDir -Force
            $extractSuccess = $true
        } catch {
            Write-Err2 "解压安装包失败: $_"
        }
    }

    if (-not $extractSuccess) {
        Write-Err2 "无法解压 Firefox 安装包"
        Write-Info "请手动安装 Firefox ESR 128: https://www.mozilla.org/en-US/firefox/all/#product-desktop-esr"
        return $false
    }

    # 查找安装程序
    $installer = Get-ChildItem $extractDir -Filter "*.exe" -Recurse | Select-Object -First 1
    if (-not $installer) {
        Write-Err2 "安装包中未找到 .exe 安装程序"
        return $false
    }

    Write-Host ""
    Write-Host "    即将启动 Firefox 安装向导，请按提示完成安装。" -ForegroundColor Yellow
    Write-Host "    安装完成后，本脚本将继续配置 UC 脚本。" -ForegroundColor Yellow
    Write-Host ""

    Start-Process -FilePath $installer.FullName -Wait

    # 清理临时文件
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

    # 重新检测
    $newPath = Get-FirefoxInstallPath
    if ($newPath) {
        Write-OK "Firefox 安装完成: $newPath"
        return $true
    } else {
        Write-Err2 "安装后未检测到 Firefox，请确认安装是否成功"
        return $false
    }
}

# ============================================================
#  主流程
# ============================================================

function Show-Banner {
    Write-Host ""
    Write-Host "  ===============================================" -ForegroundColor Cyan
    Write-Host "    Firefox UC 脚本一键安装工具" -ForegroundColor Cyan
    Write-Host "    仓库: github.com/exfeitu/my-firefox-uc.js-css-scripts" -ForegroundColor DarkCyan
    Write-Host "  ===============================================" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Summary {
    param(
        [string]$InstallPath,
        [string]$ProfilePath,
        [bool]$InstallFilesOK,
        [bool]$ChromeFilesOK,
        [bool]$SideberyOK
    )

    Write-Host ""
    Write-Host "  ===============================================" -ForegroundColor Cyan
    Write-Host "    安装摘要" -ForegroundColor Cyan
    Write-Host "  ===============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    Firefox 安装路径:" -NoNewline; Write-Host " $InstallPath" -ForegroundColor Gray
    Write-Host "    配置文件路径:    " -NoNewline; Write-Host " $ProfilePath" -ForegroundColor Gray
    Write-Host ""
    Write-Host "    config.js + defaults/  -> 安装目录  " -NoNewline
    if ($InstallFilesOK) { Write-Host "[OK]" -ForegroundColor Green } else { Write-Host "[失败]" -ForegroundColor Red }
    Write-Host "    utils/ + .uc.js + .css -> chrome/   " -NoNewline
    if ($ChromeFilesOK) { Write-Host "[OK]" -ForegroundColor Green } else { Write-Host "[失败]" -ForegroundColor Red }
    Write-Host "    user.js 偏好设置      -> profile/   " -NoNewline
    Write-Host "[OK]" -ForegroundColor Green
    Write-Host "    Sidebery 扩展         -> extensions/" -NoNewline
    if ($SideberyOK) { Write-Host "[OK]" -ForegroundColor Green } else { Write-Host "[跳过]" -ForegroundColor Yellow }
    Write-Host "    启动缓存清除           -> 完成       " -NoNewline
    Write-Host "[OK]" -ForegroundColor Green
    Write-Host ""
    Write-Host "  下一步: 启动 (或重启) Firefox 即可生效" -ForegroundColor Yellow
    Write-Host ""
}

function Main {
    Show-Banner

    # --------------------------------------------------------
    # 1. 检查脚本目录中的文件
    # --------------------------------------------------------
    Write-Step "检查脚本文件完整性..."

    $missingFiles = @()
    $allNeeded = @("config.js") + $Chrome_Files + $Chrome_Dirs + @($SideberyXpi)
    foreach ($f in $allNeeded) {
        if (-not (Test-Path (Join-Path $ScriptDir $f))) {
            $missingFiles += $f
        }
    }
    # defaults 目录
    if (-not (Test-Path (Join-Path $ScriptDir "defaults\pref\config-prefs.js"))) {
        $missingFiles += "defaults\pref\config-prefs.js"
    }

    if ($missingFiles.Count -gt 0) {
        Write-Warn2 "缺少以下文件:"
        foreach ($f in $missingFiles) { Write-Host "      - $f" -ForegroundColor Yellow }
        Write-Host ""
        Write-Host "    请确保本脚本与仓库文件在同一目录下运行。" -ForegroundColor Yellow
        Write-Host "    克隆仓库: git clone https://github.com/exfeitu/my-firefox-uc.js-css-scripts" -ForegroundColor DarkGray
        return
    }
    Write-OK "所有文件就绪"

    # --------------------------------------------------------
    # 2. 检测 Firefox 安装路径
    # --------------------------------------------------------
    Write-Step "检测 Firefox 安装路径..."

    $installPath = Get-FirefoxInstallPath

    if (-not $installPath) {
        Write-Warn2 "未检测到已安装的 Firefox"
        $installerZip = Join-Path $ScriptDir $FirefoxInstallerZip
        if (Test-Path $installerZip) {
            $choice = Read-Host "    是否使用附带的安装包安装 Firefox ESR 128? (y/n)"
            if ($choice -eq 'y' -or $choice -eq 'Y') {
                if (Install-Firefox) {
                    $installPath = Get-FirefoxInstallPath
                }
            }
        }
        if (-not $installPath) {
            Write-Err2 "无法继续: 未找到 Firefox 安装"
            Write-Info "请先安装 Firefox ESR 128: https://www.mozilla.org/en-US/firefox/all/#product-desktop-esr"
            return
        }
    }

    Write-OK "安装路径: $installPath"

    # 检查版本
    $version = Get-FirefoxVersion -InstallPath $installPath
    if ($version) {
        Write-Info "版本: $version"
        if ($version -notmatch '128\.' -and $version -notmatch 'esr') {
            Write-Warn2 "当前版本可能不是 ESR 128，UC 脚本可能无法正常工作"
            Write-Info "推荐使用 Firefox ESR 128 版本"
            $continue = Read-Host "    是否继续? (y/n)"
            if ($continue -ne 'y' -and $continue -ne 'Y') { return }
        }
    }

    # --------------------------------------------------------
    # 3. 权限检查 & 提权
    # --------------------------------------------------------
    Write-Step "检查安装目录写入权限..."

    if (-not (Test-CanWriteToFolder -Path $installPath)) {
        Write-Warn2 "安装目录需要管理员权限: $installPath"
        if (-not (Test-IsAdmin)) {
            Write-Info "正在请求管理员权限 (UAC)..."
            try {
                $psi = New-Object Diagnostics.ProcessStartInfo
                $psi.FileName = "powershell.exe"
                $psi.Arguments = "-ExecutionPolicy Bypass -NoProfile -File `"$PSCommandPath`""
                $psi.Verb = "RunAs"
                $psi.UseShellExecute = $true
                $proc = [Diagnostics.Process]::Start($psi)
                $proc.WaitForExit()
                return
            } catch {
                Write-Err2 "管理员权限请求失败: $_"
                Write-Info "请右键点击脚本 -> 「以管理员身份运行」"
                return
            }
        } else {
            Write-OK "已具有管理员权限"
        }
    } else {
        Write-OK "安装目录可写入 (无需管理员权限)"
    }

    # --------------------------------------------------------
    # 4. 检测配置文件
    # --------------------------------------------------------
    Write-Step "检测 Firefox 配置文件..."

    $profilePath = Select-FirefoxProfile
    if (-not $profilePath) {
        Write-Err2 "未找到 Firefox 配置文件"
        Write-Info "请先至少启动一次 Firefox 以创建配置文件"
        return
    }
    Write-OK "配置文件: $profilePath"

    # --------------------------------------------------------
    # 5. 检查 Firefox 是否正在运行
    # --------------------------------------------------------
    Write-Step "检查 Firefox 运行状态..."

    if (Test-FirefoxRunning) {
        Write-Warn2 "Firefox 正在运行，需要关闭才能修改配置文件"
        $choice = Read-Host "    是否立即关闭 Firefox? (y/n)"
        if ($choice -eq 'y' -or $choice -eq 'Y') {
            Stop-Firefox
        } else {
            Write-Warn2 "未关闭 Firefox，部分文件可能被锁定"
            Write-Info "如果复制失败，请手动关闭 Firefox 后重新运行本脚本"
        }
    } else {
        Write-OK "Firefox 未运行"
    }

    # --------------------------------------------------------
    # 6. 复制安装目录文件 (config.js + defaults)
    # --------------------------------------------------------
    Write-Step "安装 UC 脚本加载器到 Firefox 安装目录..."

    $installOK = Copy-InstallFolderFiles -InstallPath $installPath

    # --------------------------------------------------------
    # 7. 复制 chrome 文件夹文件 (utils + uc.js + css)
    # --------------------------------------------------------
    Write-Step "安装用户脚本和样式到 chrome 文件夹..."

    $chromeOK = Copy-ChromeFolderFiles -ProfilePath $profilePath

    # --------------------------------------------------------
    # 8. 写入 user.js 偏好设置
    # --------------------------------------------------------
    Write-Step "配置 about:config 偏好设置..."

    Update-UserJS -ProfilePath $profilePath

    # --------------------------------------------------------
    # 9. 安装 Sidebery 扩展
    # --------------------------------------------------------
    Write-Step "安装 Sidebery 扩展..."

    Install-Sidebery -ProfilePath $profilePath

    $sideberyOK = $false
    $extId = Get-ExtensionId -XpiPath (Join-Path $ScriptDir $SideberyXpi)
    if ($extId) {
        $xpiDest = Join-Path $profilePath "extensions\$extId.xpi"
        $sideberyOK = Test-Path $xpiDest
    }

    # --------------------------------------------------------
    # 10. 清除启动缓存
    # --------------------------------------------------------
    Write-Step "清除启动缓存..."

    Clear-StartupCache -ProfilePath $profilePath

    # --------------------------------------------------------
    # 11. 显示摘要
    # --------------------------------------------------------
    Show-Summary -InstallPath $installPath -ProfilePath $profilePath `
                 -InstallFilesOK $installOK -ChromeFilesOK $chromeOK -SideberyOK $sideberyOK

    # --------------------------------------------------------
    # 12. 询问是否启动 Firefox
    # --------------------------------------------------------
    $launch = Read-Host "  是否现在启动 Firefox? (y/n)"
    if ($launch -eq 'y' -or $launch -eq 'Y') {
        $exePath = Join-Path $installPath "firefox.exe"
        Start-Process -FilePath $exePath
        Write-OK "Firefox 已启动"
    }

    Write-Host ""
    if (Test-IsAdmin) {
        Write-Host "  按任意键退出..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
}

# ============================================================
#  入口
# ============================================================

Main
