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

Write-Host "FerIDE indiriliyor..." -ForegroundColor Cyan
$releases = Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri "https://api.github.com/repos/$Repo/releases?per_page=20"
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
    $p = Start-Process -FilePath $exe -ArgumentList ($argList -join ' ') -WorkingDirectory $env:TEMP -PassThru
    $null = $p.Handle # çıkış kodunun okunabilmesi için
    $p.WaitForExit()
    $code = $p.ExitCode
} finally {
    for ($i = 0; $i -lt 10 -and (Test-Path $tmp); $i++) {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        if (Test-Path $tmp) { Start-Sleep -Milliseconds 500 }
    }
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

    # Windows 11 Akıllı Uygulama Denetimi açıksa imzasız llama.cpp "Bozuk Görüntü (0xc0e90002)" hatasıyla engellenir.
    $sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
    if ($sac -eq 1) {
        Write-Host ""
        Write-Host "UYARI: Windows Akıllı Uygulama Denetimi (Smart App Control) açık." -ForegroundColor Yellow
        Write-Host "FerIDE'nin model motoru llama.cpp henüz dijital olarak imzalı olmadığı için Windows onu engeller" -ForegroundColor Yellow
        Write-Host '("Bozuk Görüntü 0xc0e90002" hatası). Çözüm:' -ForegroundColor Yellow
        Write-Host "  Windows Güvenlik > Uygulama ve tarayıcı denetimi > Akıllı Uygulama Denetimi ayarları > Kapalı" -ForegroundColor Yellow
        Write-Host "  ardından FerIDE'yi yeniden başlatın. (Windows'un Nisan 2026 ve sonraki güncellemelerinde ayar sonradan yeniden açılabilir.)" -ForegroundColor Yellow
    }
}
