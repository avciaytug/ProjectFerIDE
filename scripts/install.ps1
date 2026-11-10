# FerIDE kurulumu (Windows). Yönetici izni GEREKTİRMEZ: her şey kullanıcı klasörüne kurulur.
#   irm https://raw.githubusercontent.com/avciaytug/ProjectFerIDE/main/scripts/install.ps1 | iex
# İlk açılışta FerIDE kurulum sihirbazı llama.cpp, Git Bash, uv, Node.js gibi bağımlılıkları kendisi kurar.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Repo = 'avciaytug/ProjectFerIDE'
$Dest = Join-Path $env:LOCALAPPDATA 'Programs\FerIDE'
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$AssetName = "feride-windows-$Arch.zip"

Write-Host "FerIDE kuruluyor..." -ForegroundColor Cyan
$headers = @{ 'User-Agent' = 'FerIDE-installer' }
$releases = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repo/releases?per_page=10"
$release = $releases | Where-Object { $_.assets.name -contains $AssetName } | Select-Object -First 1
if (-not $release) { throw "Bu platform için sürüm bulunamadı ($AssetName)." }
$asset = $release.assets | Where-Object { $_.name -eq $AssetName }
$sumAsset = $release.assets | Where-Object { $_.name -eq "$AssetName.sha256" }

$tmp = Join-Path $env:TEMP "feride-install-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $tmp | Out-Null
$zip = Join-Path $tmp $AssetName
Write-Host "İndiriliyor: $($release.tag_name) ($([math]::Round($asset.size / 1MB, 1)) MB)"
Invoke-WebRequest -Headers $headers -Uri $asset.browser_download_url -OutFile $zip

if ($sumAsset) {
    $expected = ((Invoke-WebRequest -Headers $headers -Uri $sumAsset.browser_download_url).Content -split '\s+')[0]
    if ($expected -is [byte[]]) { $expected = [Text.Encoding]::ASCII.GetString($expected) }
    $actual = (Get-FileHash -Algorithm SHA256 $zip).Hash
    if ($actual -ne $expected.Trim().ToUpper()) { throw "İndirme doğrulanamadı (SHA-256 uyuşmuyor)." }
    Write-Host "SHA-256 doğrulandı." -ForegroundColor Green
}

# Çalışıyorsa kapat (dosyalar kilitli olmasın).
Get-Process feride -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Dest*" } | Stop-Process -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Dest | Out-Null
Expand-Archive -Force $zip $Dest
Remove-Item -Recurse -Force $tmp

$exe = Join-Path $Dest 'feride.exe'
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
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$Dest", 'User')
}

Write-Host "FerIDE $($release.tag_name) kuruldu: $Dest" -ForegroundColor Green
Write-Host "Başlat menüsü ve masaüstüne kısayol eklendi. Açılıyor..."
Start-Process $exe
