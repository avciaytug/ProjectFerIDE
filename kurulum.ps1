param(
    [switch]$Autonomous = $false,
    [switch]$Launch = $false
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $AppDir
$env:FERIDE_ROOT = $AppDir

$FerideHome = Join-Path $env:USERPROFILE ".feride"
$SubDirs = @("models", "models\mmproj", "aegis", "skills", "todos", "Chats", "logs", "bin\llama-cpp", "tmp")
foreach ($sd in $SubDirs) {
    $full = Join-Path $FerideHome $sd
    if (!(Test-Path $full)) { New-Item -ItemType Directory -Path $full -Force | Out-Null }
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  FerIDE Beta v5.3.6 — Windows Otonom Kurulum Sihirbazı         " -ForegroundColor Cyan
Write-Host "  Konum: $AppDir" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# 1. Dahili mmproj, Aegis DB, Skills ve MCP yapılandırmasını senkronize et
Write-Host "[1/5] Çalışma dizini (~/.feride), mmproj ve yetenekler hazırlanıyor..." -ForegroundColor Blue
$BundledMmproj = Join-Path $AppDir "models\mmproj"
if (Test-Path $BundledMmproj) {
    Get-ChildItem -Path $BundledMmproj -Filter "*.gguf" | ForEach-Object {
        $dst = Join-Path $FerideHome "models\mmproj\$($_.Name)"
        if (!(Test-Path $dst)) { Copy-Item $_.FullName -Destination $dst -Force }
    }
}

$AegisSrc = Join-Path $AppDir "aegis_data\memory.db"
$AegisDst = Join-Path $FerideHome "aegis\memory.db"
if ((Test-Path $AegisSrc) -and !(Test-Path $AegisDst)) {
    Copy-Item $AegisSrc -Destination $AegisDst -Force
}

$SkillsSrc = Join-Path $AppDir "skills_data"
$SkillsDst = Join-Path $FerideHome "skills"
if (Test-Path $SkillsSrc) {
    Copy-Item "$SkillsSrc\*" -Destination $SkillsDst -Recurse -Force -ErrorAction SilentlyContinue
}

$McpSrc = Join-Path $AppDir "mcp_config.json"
$McpDst = Join-Path $FerideHome "mcp_config.json"
if ((Test-Path $McpSrc) -and !(Test-Path $McpDst)) {
    Copy-Item $McpSrc -Destination $McpDst -Force
}

# 2. WinGet üzerinden eksik sistem araçlarını (Python 3.12, FFmpeg, Aria2) otonom kur
Write-Host "[2/5] Sistem araçları (Python, FFmpeg, Aria2) kontrol ediliyor..." -ForegroundColor Blue
$HasWinget = $null -ne (Get-Command winget -ErrorAction SilentlyContinue)

function Test-RealPython {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return $false }
    if ($cmd.Source -like "*WindowsApps*") {
        $ver = & python --version 2>&1
        return ($LASTEXITCODE -eq 0 -and "$ver" -match "Python 3")
    }
    return $true
}

if (!(Test-RealPython) -and $HasWinget) {
    Write-Host "  -> Python 3.12 WinGet üzerinden kuruluyor..." -ForegroundColor Yellow
    winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements --silent
}
if (($null -eq (Get-Command ffmpeg -ErrorAction SilentlyContinue)) -and $HasWinget) {
    Write-Host "  -> FFmpeg WinGet üzerinden kuruluyor..." -ForegroundColor Yellow
    winget install -e --id Gyan.FFmpeg --accept-package-agreements --accept-source-agreements --silent
}
if (($null -eq (Get-Command aria2c -ErrorAction SilentlyContinue)) -and $HasWinget) {
    Write-Host "  -> Aria2 (16x İndirici) WinGet üzerinden kuruluyor..." -ForegroundColor Yellow
    winget install -e --id aria2.aria2 --accept-package-agreements --accept-source-agreements --silent
}

# PATH yenile
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

# 3. Python Sanal Ortamı (~/.feride/venv) + STT/TTS & Evrensel Dosya Kütüphaneleri
Write-Host "[3/5] Python sanal ortamı ($FerideHome\venv) ve STT/Ofis paketleri kuruluyor..." -ForegroundColor Blue
$VenvPy = Join-Path $FerideHome "venv\Scripts\python.exe"
if (!(Test-Path $VenvPy) -and (Test-RealPython)) {
    & python -m venv (Join-Path $FerideHome "venv")
}
if (Test-Path $VenvPy) {
    & $VenvPy -m pip install --quiet --upgrade pip wheel
    & $VenvPy -m pip install --quiet -r (Join-Path $AppDir "requirements.txt")
    Write-Host "  [OK] Python kütüphaneleri ve çevrimdışı Whisper STT hazır." -ForegroundColor Green
} else {
    Write-Host "  [!] Python bulunamadı; lütfen python.org üzerinden Python 3.11+ kurup kurulum_windows.bat betiğini tekrar çalıştırın." -ForegroundColor Yellow
}

# 4. Windows Vulkan llama-server.exe Otonom Kurulumu
Write-Host "[4/5] Windows llama.cpp (Vulkan GPU / CPU) motoru kontrol ediliyor..." -ForegroundColor Blue
$LlamaDir = Join-Path $FerideHome "bin\llama-cpp"
$LlamaExe = Join-Path $LlamaDir "llama-server.exe"
if (!(Test-Path $LlamaExe)) {
    try {
        $Releases = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=5" -Headers @{ "User-Agent" = "FerIDE-5.3.6" }
        $ChosenAsset = $null
        foreach ($rel in $Releases) {
            foreach ($a in $rel.assets) {
                $n = $a.name.ToLower()
                if ($n.EndsWith(".zip") -and $n.Contains("win-vulkan-x64")) {
                    $ChosenAsset = $a
                    break
                }
            }
            if ($null -ne $ChosenAsset) { break }
        }
        if ($null -eq $ChosenAsset) {
            foreach ($rel in $Releases) {
                foreach ($a in $rel.assets) {
                    $n = $a.name.ToLower()
                    if ($n.EndsWith(".zip") -and $n.Contains("win-") -and $n.Contains("x64") -and !$n.StartsWith("cudart-")) {
                        $ChosenAsset = $a
                        break
                    }
                }
                if ($null -ne $ChosenAsset) { break }
            }
        }
        if ($null -ne $ChosenAsset) {
            $ZipPath = Join-Path $FerideHome "tmp\$($ChosenAsset.name)"
            $ExtDir = Join-Path $FerideHome "tmp\llama_win_ext"
            Write-Host "  -> İndiriliyor: $($ChosenAsset.name)..." -ForegroundColor Cyan
            Invoke-WebRequest -Uri $ChosenAsset.browser_download_url -OutFile $ZipPath -UseBasicParsing
            if (Test-Path $ExtDir) { Remove-Item $ExtDir -Recurse -Force }
            New-Item -ItemType Directory -Path $ExtDir -Force | Out-Null
            Expand-Archive -LiteralPath $ZipPath -DestinationPath $ExtDir -Force
            $Found = Get-ChildItem -Path $ExtDir -Recurse -Filter "llama-server.exe" | Select-Object -First 1
            if ($null -ne $Found) {
                Copy-Item "$($Found.Directory.FullName)\*" -Destination $LlamaDir -Recurse -Force
                Write-Host "  [OK] Windows llama-server.exe başarıyla kuruldu!" -ForegroundColor Green
            }
            Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
            Remove-Item $ExtDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "  [!] llama-server otomatik indirilemedi; FerIDE Ayarlar > Genel sekmesinden tek tıkla kurabilirsiniz." -ForegroundColor Yellow
    }
} else {
    Write-Host "  [OK] Windows llama-server.exe hazır." -ForegroundColor Green
}

# 5. Windows Release İkilisi Kontrolü & Masaüstü Kısayolu
Write-Host "[5/5] FerIDE Windows uygulaması ve Masaüstü kısayolu hazırlanıyor..." -ForegroundColor Blue
$WinExe = Join-Path $AppDir "build\windows\x64\runner\Release\feride_v5_2.exe"
if (!(Test-Path $WinExe) -and ($null -ne (Get-Command flutter -ErrorAction SilentlyContinue))) {
    Write-Host "  -> Flutter algılandı; Windows Release paketi derleniyor..." -ForegroundColor Cyan
    & flutter pub get
    & flutter build windows --release
}

try {
    $DesktopPath = [Environment]::GetFolderPath("Desktop")
    $ShortcutFile = Join-Path $DesktopPath "FerIDE Beta v5.3.6.lnk"
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($ShortcutFile)
    $Shortcut.TargetPath = Join-Path $AppDir "baslat_windows.bat"
    $Shortcut.WorkingDirectory = $AppDir
    $Shortcut.Description = "FerIDE Beta v5.3.6 - Otonom Yerel Yapay Zeka IDE"
    $Shortcut.Save()
    Write-Host "  [OK] Masaüstü kısayolu oluşturuldu: $ShortcutFile" -ForegroundColor Green
} catch {}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  FerIDE Beta v5.3.6 Windows Kurulumu Tamamlandı!               " -ForegroundColor Green
Write-Host "  Başlatmak için 'baslat_windows.bat' dosyasına çift tıklayın.  " -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green

if ($Launch) {
    Start-Process -FilePath (Join-Path $AppDir "baslat_windows.bat")
}
