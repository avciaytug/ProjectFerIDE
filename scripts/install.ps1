# FerIDE kurulumu (Windows). Yönetici izni GEREKTİRMEZ: her şey kullanıcı klasörüne kurulur.
#   irm https://raw.githubusercontent.com/avciaytug/ProjectFerIDE/main/scripts/install.ps1 | iex
# İlk açılışta FerIDE kurulum sihirbazı llama.cpp, Git Bash, uv, Node.js gibi bağımlılıkları kendisi kurar.
#
# İsteğe bağlı ortam değişkenleri:
#   FERIDE_INSTALL_DIR   kurulum klasörü (varsayılan: %LOCALAPPDATA%\Programs\FerIDE)
#   FERIDE_NO_SHORTCUTS  1 ise Başlat menüsü/masaüstü kısayolu ve PATH eklenmez (taşınabilir kurulum)
#   FERIDE_NO_LAUNCH     1 ise kurulumdan sonra FerIDE açılmaz

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Eski Windows 10 kurulumlarında PowerShell 5.1 varsayılan olarak TLS 1.2 kullanmayabilir (GitHub gerektirir).
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repo = 'avciaytug/ProjectFerIDE'
$Dest = if ($env:FERIDE_INSTALL_DIR) { $env:FERIDE_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\FerIDE' }
$headers = @{ 'User-Agent' = 'FerIDE-installer' }

Write-Host "FerIDE kuruluyor..." -ForegroundColor Cyan
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

    # Çalışıyorsa kapat (dosyalar kilitli olmasın).
    Get-Process feride -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Dest*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $Dest | Out-Null
    Expand-Archive -Force $zip $Dest
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

$exe = Join-Path $Dest 'feride.exe'
if ($env:FERIDE_NO_SHORTCUTS -ne '1') {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($dir in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop'))) {
        $lnk = $shell.CreateShortcut((Join-Path $dir 'FerIDE.lnk'))
        $lnk.TargetPath = $exe
        $lnk.WorkingDirectory = $Dest
        $lnk.Description = 'FerIDE — yerel yapay zeka geliştirme ortamı'
        $lnk.Save()
    }
    # Komut satırından "feride doctor" vb. için kullanıcı PATH'ine ekle.
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not ($userPath -split ';' | Where-Object { $_ -eq $Dest })) {
        $newPath = (@($userPath, $Dest) | Where-Object { $_ }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    }
    Write-Host "Başlat menüsü ve masaüstüne kısayol eklendi."
}

Write-Host "FerIDE $($release.tag_name) kuruldu: $Dest" -ForegroundColor Green
if ($env:FERIDE_NO_LAUNCH -ne '1') {
    Write-Host "Açılıyor... İlk açılışta kurulum sihirbazı eksikleri kendisi kurar."
    Start-Process $exe
}
