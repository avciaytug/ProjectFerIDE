# FerIDE kurulumu (Windows). Yönetici izni GEREKTİRMEZ.
#   irm https://raw.githubusercontent.com/avciaytug/ProjectFerIDE/main/scripts/install.ps1 | iex
# Paketi indirip doğrular ve FerIDE kurulum sihirbazını açar: programın ve verilerin (modeller, sohbetler)
# nereye kurulacağını siz seçersiniz (C:, D: ya da istediğiniz bir klasör). FerIDE zaten kuruluysa bulunduğu
# yerde sessizce güncellenir. İlk açılışta FerIDE llama.cpp, Git Bash, uv, Node.js gibi bağımlılıkları kendisi kurar.
# Kaldırmak için: Windows Ayarlar > Uygulamalar > FerIDE > Kaldır (ya da FerIDE'de Ayarlar > Genel > Kaldır).
#
# Sihirbazsız (otomatik) kurulum için isteğe bağlı ortam değişkenleri:
#   FERIDE_INSTALL_DIR   program klasörü (bu ya da FERIDE_DATA_DIR verilirse sihirbaz açılmaz)
#   FERIDE_DATA_DIR      veri klasörü: modeller, sohbetler, ayarlar (varsayılan: %USERPROFILE%\.feride)
#   FERIDE_NO_SHORTCUTS  1 ise Başlat menüsü/masaüstü kısayolu oluşturulmaz ve PATH'e eklenmez
#   FERIDE_NO_LAUNCH     1 ise kurulumdan sonra FerIDE açılmaz

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Eski Windows 10 kurulumlarında PowerShell 5.1 varsayılan olarak TLS 1.2 kullanmayabilir (GitHub gerektirir).
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repo = 'avciaytug/ProjectFerIDE'
$headers = @{ 'User-Agent' = 'FerIDE-installer' }

# Komut satırı argümanı olarak tırnaklı yol (sondaki \ işaretleri tırnağı kaçırmasın diye ikilenir).
function Format-PathArg([string]$p) { '"' + ($p -replace '(\\+)$', '$1$1') + '"' }

# Windows Akıllı Uygulama Denetimi / Uygulama Denetimi programı engelledi mi? (Start-Process hatası; 4551:
# "Uygulama Denetimi ilkesi bu dosyayı engelledi", 4556-4559 ve 4580-4582: itibar denetimi.)
function Test-PolicyBlock($err) {
    $e = $err.Exception
    while ($e) {
        if ($e -is [System.ComponentModel.Win32Exception] -and @(4551, 4556, 4557, 4558, 4559, 4580, 4581, 4582) -contains $e.NativeErrorCode) { return $true }
        $e = $e.InnerException
    }
    return "$($err.Exception.Message)" -match 'Uygulama Denetimi|Application Control|Akıllı Uygulama|Smart App'
}

function Show-PolicyBlockHelp {
    Write-Host ""
    Write-Host "Windows Akıllı Uygulama Denetimi (Smart App Control) FerIDE'yi engelledi." -ForegroundColor Yellow
    Write-Host "Neden: FerIDE henüz dijital olarak imzalı değil ve Windows bu yeni sürümü henüz tanımıyor. Bu, FerIDE'de" -ForegroundColor Yellow
    Write-Host "virüs bulunduğu anlamına gelmez; Windows imzasız ve tanımadığı programları çalıştırmıyor." -ForegroundColor Yellow
    Write-Host "Bilgisayarınızda bir değişiklik yapılmadı." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Bu bilgisayara kurmak için:"
    Write-Host "  1. Windows Güvenlik > Uygulama ve tarayıcı denetimi > Akıllı Uygulama Denetimi ayarları > Kapalı"
    Write-Host "  2. Bu komutu yeniden çalıştırın:"
    Write-Host "     irm https://raw.githubusercontent.com/$Repo/main/scripts/install.ps1 | iex" -ForegroundColor Cyan
    Write-Host "(Windows'un Nisan 2026 ve sonraki güncellemelerinde bu ayar sonradan yeniden açılabilir.)"
    if ([Environment]::UserInteractive) {
        Write-Host ""
        Write-Host "Windows Güvenlik'in ilgili sayfası açılıyor..."
        try { Start-Process 'windowsdefender://appbrowser' } catch { }
    }
}

Write-Host "FerIDE indiriliyor..." -ForegroundColor Cyan
$releases = Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri "https://api.github.com/repos/$Repo/releases?per_page=20"
# GitHub listeyi sürüm adına göre sıralayabiliyor ("beta.9" > "beta.10"); en yeni yayın en başta olsun.
$releases = @($releases | Sort-Object { [datetime]$_.published_at } -Descending)
# ARM64 Windows x64 uygulamalarını da çalıştırır: ARM64 paketi yoksa x64 kullanılır.
$names = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { @('feride-windows-arm64.zip', 'feride-windows-x64.zip') } else { @('feride-windows-x64.zip') }
$release = $null
$AssetName = $null
foreach ($n in $names) {
    $release = $releases | Where-Object { $_.assets.name -contains $n } | Select-Object -First 1
    if ($release) { $AssetName = $n; break }
}
if (-not $release) { throw "Windows için FerIDE sürümü bulunamadı: https://github.com/$Repo/releases" }
$asset = $release.assets | Where-Object { $_.name -eq $AssetName }
$sumAsset = $release.assets | Where-Object { $_.name -eq "$AssetName.sha256" }

$tmp = Join-Path $env:TEMP "feride-install-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $tmp | Out-Null
$code = 1
$blocked = $false
try {
    $zip = Join-Path $tmp $AssetName
    Write-Host "İndiriliyor: $($release.tag_name) ($([math]::Round($asset.size / 1MB, 1)) MB)"
    Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $asset.browser_download_url -OutFile $zip

    if ($sumAsset) {
        # Özet dosyası application/octet-stream olarak gelir; .Content bayt dizisi olur. Diske indirip metin okunur.
        $sumFile = Join-Path $tmp "$AssetName.sha256"
        Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $sumAsset.browser_download_url -OutFile $sumFile
        $expected = ((Get-Content -Raw $sumFile).Trim() -split '\s+')[0].ToUpper()
        $actual = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToUpper()
        if ($expected.Length -ne 64 -or $actual -ne $expected) { throw "İndirme doğrulanamadı (SHA-256 uyuşmuyor). Tekrar deneyin." }
        Write-Host "SHA-256 doğrulandı." -ForegroundColor Green
    }

    $pkg = Join-Path $tmp 'paket'
    Expand-Archive -Force $zip $pkg
    $exe = Join-Path $pkg 'feride.exe'
    if (-not (Test-Path $exe)) { throw "Pakette feride.exe bulunamadı." }

    # Kurulumu FerIDE'nin kendisi yapar: program/veri klasörü, kısayollar, PATH ve "Uygulamalar" kaydı.
    $argList = @('install')
    if ($env:FERIDE_INSTALL_DIR -or $env:FERIDE_DATA_DIR) {
        $argList += '--yes'
        if ($env:FERIDE_INSTALL_DIR) { $argList += '--dir', (Format-PathArg $env:FERIDE_INSTALL_DIR) }
        if ($env:FERIDE_DATA_DIR) { $argList += '--data', (Format-PathArg $env:FERIDE_DATA_DIR) }
        if ($env:FERIDE_NO_SHORTCUTS -eq '1') { $argList += '--no-shortcuts', '--no-path' }
        Write-Host "Kuruluyor..."
    } else {
        # Kuruluysa yerinde güncellenir; değilse kurulum sihirbazı açılır.
        $argList += '--update'
        Write-Host "Kurulum sihirbazı açılıyor: FerIDE'nin ve verilerinin kurulacağı yeri seçin..." -ForegroundColor Cyan
        Write-Host "(FerIDE zaten kuruluysa sihirbaz açılmadan güncellenir.)"
    }
    if ($env:FERIDE_NO_LAUNCH -eq '1') { $argList += '--no-launch' }

    # "Start-Process -Wait" açılan FerIDE'yi de bekler; burada yalnızca kurulum sürecinin bitmesi beklenir.
    try {
        $p = Start-Process -FilePath $exe -ArgumentList ($argList -join ' ') -WorkingDirectory $env:TEMP -PassThru
    } catch {
        if (Test-PolicyBlock $_) { $blocked = $true } else { throw }
    }
    if (-not $blocked) {
        $null = $p.Handle # çıkış kodunun okunabilmesi için
        $p.WaitForExit()
        $code = $p.ExitCode
        # Program başlayıp "Bozuk Görüntü" (0xC0E90002) koduyla kapatıldıysa da Akıllı Uygulama Denetimi engellemiştir.
        if ($code -eq -1058471934) { $blocked = $true }
    }
} finally {
    for ($i = 0; $i -lt 10 -and (Test-Path $tmp); $i++) {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        if (Test-Path $tmp) { Start-Sleep -Milliseconds 500 }
    }
}

if ($blocked) {
    Show-PolicyBlockHelp
    return
}

if ($code -eq 2) {
    Write-Host "Kurulum iptal edildi; bilgisayarınızda bir değişiklik yapılmadı." -ForegroundColor Yellow
} elseif ($code -ne 0) {
    throw "Kurulum başarısız oldu (çıkış kodu $code). Ayrıntılar: $(Join-Path $env:TEMP 'feride-kurulum.log')"
} else {
    Write-Host "FerIDE $($release.tag_name) kuruldu." -ForegroundColor Green
    $ptr = Join-Path $env:LOCALAPPDATA 'FerIDE\install.json'
    if (Test-Path $ptr) {
        $info = Get-Content -Raw -Encoding UTF8 $ptr | ConvertFrom-Json
        Write-Host "  Program: $($info.install_dir)"
        Write-Host "  Veriler: $($info.data_dir)"
    }
    Write-Host "Kaldırmak için: Ayarlar > Uygulamalar > FerIDE > Kaldır"

    # Windows 11 Akıllı Uygulama Denetimi açıksa imzasız bileşenlerden bazılarını (llama.cpp, ses motoru) engelleyebilir.
    $sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
    if ($sac -eq 1) {
        Write-Host ""
        Write-Host "Not: Windows Akıllı Uygulama Denetimi (Smart App Control) açık. FerIDE'nin bileşenleri henüz dijital" -ForegroundColor Yellow
        Write-Host "olarak imzalı olmadığından Windows bazılarını engelleyebilir; engellerse FerIDE nedenini ve çözümünü gösterir." -ForegroundColor Yellow
    }
}
