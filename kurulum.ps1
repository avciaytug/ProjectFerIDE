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

# Her adım bu dosyaya da yazılır; sorun olursa bu günlüğü paylaşın.
$LogFile = Join-Path $FerideHome "logs\kurulum_windows.log"
try { Start-Transcript -Path $LogFile -Append | Out-Null } catch {}

# Tarayıcıdan indirilen zip'ten çıkan dosyalar "İnternetten geldi" işaretlidir;
# Windows bu yüzden .bat/.ps1/.py dosyalarını engelleyebilir ya da uyarı gösterir.
Get-ChildItem -LiteralPath $AppDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike "*\build\*" -and $_.FullName -notlike "*\models\*" } |
    Unblock-File -ErrorAction SilentlyContinue

function Update-SessionPath {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  FerIDE Beta v5.3.8 — Windows Otonom Kurulum Sihirbazı         " -ForegroundColor Cyan
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

Update-SessionPath

# 3. Python Sanal Ortamı (~/.feride/venv) + STT/TTS & Evrensel Dosya Kütüphaneleri
Write-Host "[3/5] Python sanal ortamı ($FerideHome\venv) ve STT/Ofis paketleri kuruluyor..." -ForegroundColor Blue
$VenvPy = Join-Path $FerideHome "venv\Scripts\python.exe"
if (!(Test-Path $VenvPy) -and (Test-RealPython)) {
    & python -m venv (Join-Path $FerideHome "venv")
}
if (Test-Path $VenvPy) {
    & $VenvPy -m pip install --quiet --upgrade pip wheel
    & $VenvPy -m pip install --quiet -r (Join-Path $AppDir "requirements.txt")
    # Feride kadın sesi (Ahenk Cep, yerel)
    & $VenvPy (Join-Path $AppDir "scripts\setup_voice.py")
    if ($LASTEXITCODE -ne 0) { Write-Host "  [!] Kadın ses kurulamadı; erkek ses kullanılacak." -ForegroundColor Yellow }
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
        $Releases = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=5" -Headers @{ "User-Agent" = "FerIDE-5.3.8" }
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

# 5. FerIDE Windows uygulaması (feride_v5_2.exe)
# Flutter masaüstü uygulamaları yalnızca hedef işletim sisteminde derlenebilir;
# bu yüzden .exe bu bilgisayarda bir kez derlenir. Gerekenler: Git, Flutter SDK,
# Visual Studio C++ Build Tools ve Windows Geliştirici Modu (eklenti sembolik bağları).
Write-Host "[5/5] FerIDE Windows uygulaması hazırlanıyor..." -ForegroundColor Blue
$ReleaseDir = Join-Path $AppDir "build\windows\x64\runner\Release"
$WinExe = Join-Path $ReleaseDir "feride_v5_2.exe"
# Zip'teki kaynak sürümü; derlenen uygulamanın yanına da yazılır. Yeni bir zip eski
# klasörün üzerine açıldığında eski .exe'nin çalışmaya devam etmesini önler.
$SourceStamp = Join-Path $AppDir "KAYNAK_SURUMU.txt"
$BuiltStamp = Join-Path $ReleaseDir "KAYNAK_SURUMU.txt"
function Test-AppCurrent {
    if (!(Test-Path $WinExe)) { return $false }
    if (!(Test-Path $SourceStamp)) { return $true }
    if (!(Test-Path $BuiltStamp)) { return $false }
    return ((Get-Content $SourceStamp -Raw).Trim() -eq (Get-Content $BuiltStamp -Raw).Trim())
}

function Confirm-Step([string]$Question) {
    if ($Autonomous) { return $true }
    $ans = Read-Host "  $Question (E/h)"
    return -not ($ans -match '^[hHnN]')
}

function Find-Flutter {
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    foreach ($c in @(
        (Join-Path $env:LOCALAPPDATA "FerIDE\flutter\bin\flutter.bat"),
        (Join-Path $env:USERPROFILE "flutter\bin\flutter.bat"),
        "C:\src\flutter\bin\flutter.bat",
        "C:\flutter\bin\flutter.bat")) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Test-VisualCpp {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (!(Test-Path $vswhere)) { return $false }
    $found = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    return -not [string]::IsNullOrWhiteSpace("$found")
}

function Test-DeveloperMode {
    try {
        $v = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" -Name AllowDevelopmentWithoutDevLicense -ErrorAction Stop
        return $v.AllowDevelopmentWithoutDevLicense -eq 1
    } catch { return $false }
}

function Install-BuildTools {
    if (-not $HasWinget) {
        Write-Host "  [!] winget bulunamadı. Microsoft Store'dan 'Uygulama Yükleyici' (App Installer) kurup tekrar deneyin." -ForegroundColor Yellow
        return $false
    }
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "  -> Git kuruluyor..." -ForegroundColor Cyan
        winget install -e --id Git.Git --accept-package-agreements --accept-source-agreements --silent | Out-Host
        Update-SessionPath
    }
    if (-not (Test-VisualCpp)) {
        Write-Host "  -> Visual Studio 2022 C++ Build Tools kuruluyor (yaklaşık 3-5 GB, 10-20 dk; Windows yönetici onayı isteyebilir)..." -ForegroundColor Cyan
        winget install -e --id Microsoft.VisualStudio.2022.BuildTools --accept-package-agreements --accept-source-agreements `
            --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended" | Out-Host
        if (-not (Test-VisualCpp)) {
            Write-Host "  [!] Visual Studio C++ araçları kurulamadı. Bilgisayarı yeniden başlatıp kurulumu tekrar çalıştırın." -ForegroundColor Red
            return $false
        }
    }
    if ($null -eq (Find-Flutter)) {
        if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
            Write-Host "  [!] Git bulunamadı; Flutter indirilemiyor." -ForegroundColor Red
            return $false
        }
        $FlutterDir = Join-Path $env:LOCALAPPDATA "FerIDE\flutter"
        Write-Host "  -> Flutter SDK (stable) indiriliyor: $FlutterDir" -ForegroundColor Cyan
        New-Item -ItemType Directory -Path (Split-Path $FlutterDir) -Force | Out-Null
        if (Test-Path $FlutterDir) { Remove-Item $FlutterDir -Recurse -Force -ErrorAction SilentlyContinue }
        & git clone --depth 1 -b stable https://github.com/flutter/flutter.git $FlutterDir 2>&1 | ForEach-Object { Write-Host "$_" }
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($userPath -notlike "*$FlutterDir\bin*") {
            [Environment]::SetEnvironmentVariable("Path", "$userPath;$FlutterDir\bin", "User")
        }
    }
    return $null -ne (Find-Flutter)
}

function Enable-DeveloperMode {
    if (Test-DeveloperMode) { return $true }
    Write-Host ""
    Write-Host "  Flutter, Windows'ta eklentileri derlemek için 'Geliştirici Modu'nun açık olmasını ister" -ForegroundColor Yellow
    Write-Host "  (Ayarlar > Sistem > Geliştiriciler için). Bu olmadan derleme 'symlink support' hatasıyla durur." -ForegroundColor Yellow
    if (Confirm-Step "Geliştirici Modu şimdi açılsın mı? Windows yönetici onayı isteyecek") {
        try {
            Start-Process -FilePath "reg.exe" -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList `
                'add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1'
        } catch {}
    }
    if (Test-DeveloperMode) { Write-Host "  [OK] Geliştirici Modu açık." -ForegroundColor Green; return $true }
    Write-Host "  [!] Geliştirici Modu açılamadı. Açılan Ayarlar sayfasında 'Geliştirici Modu'nu açıp kurulumu tekrar çalıştırın." -ForegroundColor Yellow
    Start-Process "ms-settings:developers" -ErrorAction SilentlyContinue
    return $false
}

function Build-FerideWindows {
    $flutter = Find-Flutter
    # Derleme kısa, boşluksuz bir kopyada yapılır: "Downloads\FerIDE Beta v5.3.8.1\FerIDE Beta v5.3.8"
    # gibi uzun/boşluklu yollar CMake ve 260 karakter yol sınırına takılabiliyor.
    $Src = Join-Path $env:LOCALAPPDATA "FerIDE\src"
    New-Item -ItemType Directory -Path $Src -Force | Out-Null
    Write-Host "  -> Kaynak kod derleme klasörüne kopyalanıyor: $Src" -ForegroundColor Cyan
    # Yalnızca kökteki büyük/derlemeyle ilgisiz klasörler hariç (tam yolla: "models" adı lib\models'i de kapsardı).
    $Skip = @("models", "bin", "Chats", "aegis_data", "todos_data", "skills_data", "relay8", "docs", "windows\flutter\ephemeral") |
        ForEach-Object { Join-Path $AppDir $_ }
    & robocopy $AppDir $Src /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 /XD build .dart_tool .git @Skip | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Host "  [!] Kaynak kopyalanamadı (robocopy $LASTEXITCODE)." -ForegroundColor Red; return $false }

    Push-Location $Src
    try {
        & $flutter config --enable-windows-desktop 2>&1 | Out-Null
        Write-Host "  -> flutter pub get" -ForegroundColor Cyan
        & $flutter pub get 2>&1 | ForEach-Object { Write-Host "$_" }
        if ($LASTEXITCODE -ne 0) { Write-Host "  [!] 'flutter pub get' başarısız." -ForegroundColor Red; return $false }
        Write-Host "  -> flutter build windows --release (ilk derleme 5-15 dk sürebilir)" -ForegroundColor Cyan
        & $flutter build windows --release 2>&1 | ForEach-Object { Write-Host "$_" }
        $ok = ($LASTEXITCODE -eq 0) -and (Test-Path (Join-Path $Src "build\windows\x64\runner\Release\feride_v5_2.exe"))
    } finally { Pop-Location }
    if (-not $ok) {
        Write-Host "  [!] Derleme başarısız. Ayrıntı için 'flutter doctor -v' çıktısı:" -ForegroundColor Red
        & $flutter doctor -v 2>&1 | ForEach-Object { Write-Host "$_" }
        return $false
    }
    New-Item -ItemType Directory -Path $ReleaseDir -Force | Out-Null
    & robocopy (Join-Path $Src "build\windows\x64\runner\Release") $ReleaseDir /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
    if (Test-Path $SourceStamp) { Copy-Item $SourceStamp -Destination $BuiltStamp -Force }
    return Test-Path $WinExe
}

if (Test-AppCurrent) {
    Write-Host "  [OK] FerIDE Windows uygulaması hazır." -ForegroundColor Green
} else {
    if (Test-Path $WinExe) { Write-Host "  Kaynak kod güncellenmiş; uygulama yeniden derlenecek." -ForegroundColor Yellow }
    Write-Host "  FerIDE uygulaması bu bilgisayarda bir kez derlenecek. Eksikse Git, Flutter SDK ve" -ForegroundColor Yellow
    Write-Host "  Visual Studio C++ Build Tools kurulur (toplam ~6-8 GB indirme, yalnızca ilk sefer)." -ForegroundColor Yellow
    $ready = (Test-VisualCpp) -and ($null -ne (Find-Flutter))
    if (-not $ready -and (Confirm-Step "Eksik derleme araçları şimdi kurulsun mu?")) { $ready = Install-BuildTools }
    if ($ready -and (Enable-DeveloperMode)) {
        if (Build-FerideWindows) {
            Write-Host "  [OK] FerIDE Windows uygulaması derlendi: $WinExe" -ForegroundColor Green
        } else {
            Write-Host "  [!] Uygulama derlenemedi. Günlük: $LogFile" -ForegroundColor Red
        }
    }
}

if (Test-Path $WinExe) {
    try {
        $DesktopPath = [Environment]::GetFolderPath("Desktop")
        $ShortcutFile = Join-Path $DesktopPath "FerIDE.lnk"
        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut($ShortcutFile)
        $Shortcut.TargetPath = Join-Path $AppDir "baslat_windows.bat"
        $Shortcut.WorkingDirectory = $AppDir
        $Shortcut.IconLocation = "$WinExe,0"
        $Shortcut.WindowStyle = 7
        $Shortcut.Description = "FerIDE - Yerel Yapay Zeka Asistanı"
        $Shortcut.Save()
        Write-Host "  [OK] Masaüstü kısayolu: $ShortcutFile" -ForegroundColor Green
    } catch {}
}

Write-Host ""
if (Test-Path $WinExe) {
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "  FerIDE Windows kurulumu tamamlandı.                            " -ForegroundColor Green
    Write-Host "  Başlatmak için: Masaüstündeki 'FerIDE' kısayolu ya da          " -ForegroundColor Green
    Write-Host "  bu klasördeki 'baslat_windows.bat'.                            " -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Green
} else {
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  Kurulum bitti ama FerIDE uygulaması henüz derlenmedi.          " -ForegroundColor Yellow
    Write-Host "  Yukarıdaki [!] satırlarına bakın; düzeltip kurulumu tekrar     " -ForegroundColor Yellow
    Write-Host "  çalıştırın. Günlük: $LogFile" -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
}
try { Stop-Transcript | Out-Null } catch {}

if ($Launch -and (Test-Path $WinExe)) {
    Start-Process -FilePath $WinExe -WorkingDirectory $AppDir
}
if (-not (Test-Path $WinExe)) { exit 1 }
