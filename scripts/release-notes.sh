#!/usr/bin/env bash
# Sürüm sayfası notu: kurulum talimatı + CHANGELOG.md'deki ilgili bölüm.
#   scripts/release-notes.sh v5.4.0-beta.4 > release-notes.md
set -euo pipefail
TAG="${1:?kullanım: release-notes.sh <etiket>}"
VER="${TAG#v}"
REPO="avciaytug/ProjectFerIDE"
CHANGELOG="$(dirname "$0")/../CHANGELOG.md"

cat <<EOF
## Kurulum

**Windows 10/11** — PowerShell'i açıp şu satırı yapıştırın (yönetici izni gerekmez):

\`\`\`powershell
irm https://raw.githubusercontent.com/$REPO/main/scripts/install.ps1 | iex
\`\`\`

Ya da aşağıdan \`feride-windows-x64.zip\` dosyasını indirip bir klasöre çıkarın ve \`feride.exe\`'yi çalıştırın.
Windows "Bilgisayarınız korundu" uyarısı gösterirse: **Ek bilgi → Yine de çalıştır** (uygulama henüz imzalı değil).

**Linux (x64) / macOS (Apple Silicon):**

\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash
\`\`\`

İlk açılışta kurulum sihirbazı gerekenleri (llama.cpp, Git, uv, Node.js) kendisi kurar; ardından **Model Merkezi**'nden
bir model indirip başlatın. Ayrıntılar: [README](https://github.com/$REPO#kurulum). Her dosyanın yanındaki \`.sha256\`
ile indirmeyi doğrulayabilirsiniz.

EOF

# CHANGELOG'da "(5.4.0-beta.4)" içeren başlıktan bir sonraki "## " başlığına kadar.
awk -v ver="($VER)" '
  index($0, "## ") == 1 { if (found) exit; if (index($0, ver)) { found = 1; sub(/^## /, "## Bu sürümde: ") } }
  found
' "$CHANGELOG"
