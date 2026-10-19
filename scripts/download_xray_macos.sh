#!/usr/bin/env bash
# Скачать Xray-core для macOS и geo-базы в macos/xray/ и проверить целостность.
#
# Mac-1 работает «как Windows»: ядро — отдельный процесс, поэтому нужен сам
# бинарник. Из двух официальных архивов (Intel и Apple Silicon) собирается
# один универсальный файл: `lipo` детерминирован, и его сумма закреплена
# в lib/desktop_core.dart. Сборка Xcode кладёт ядро в Contents/MacOS, а
# geo-базы — в Contents/Resources/xray (фаза «Embed Xray core»).
set -euo pipefail

XRAY_VERSION="v26.3.27"
BASE_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}"
DEST="macos/xray"

# Эталонные SHA-256 для Xray-core v26.3.27. При смене версии все значения
# обновляются из официальных .dgst:
#   curl -sfL "${BASE_URL}/Xray-macos-64.zip.dgst"
#   curl -sfL "${BASE_URL}/Xray-macos-arm64-v8a.zip.dgst"
ZIP_X64_SHA256="f5b0471d3459eff1b82e48af0aeac186abcc3298210070afbbbd8437a4e8b203"
ZIP_ARM64_SHA256="2e93a67e8aa1936ecefb307e120830fcbd4c643ab9b1c46a2d0838d5f8409eaf"
BIN_X64_SHA256="afd0eaebb77994a18f29b00c5f50a4f7fbb77da06e24352d43035f3cad3c3786"
BIN_ARM64_SHA256="5d9dd24c0aba4b6cfcc6a33a5d67f854816ee17f392bf932ec8176da46f7e404"
# Универсальный бинарник из двух файлов выше (lipo -create x86_64 arm64).
# Это же значение — DesktopCore._expectedSha256Macos.
UNIVERSAL_SHA256="0a97edc89d6ba2c0080958e915373be2c46e8b4900a685b8182ea2c28c536f6d"

# Geo-базы в архивах macOS совпадают с Windows и Android.
GEOIP_SHA256="744c97b74c52bae2ac8664fef6ac481d7765cb8432a0df54f0368a88b9b4a354"
GEOSITE_SHA256="adf92de0cfc70e458b399f04c5f912bf42d115ed7e37281b30e2f1c68605e4e9"

if ! command -v lipo >/dev/null; then
  echo "ОШИБКА: нужен lipo (Xcode Command Line Tools)." >&2
  exit 1
fi

mkdir -p "$DEST"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

check_sha256() {
  local file="$1" expected="$2" label="$3"
  local actual
  actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  if [ "$actual" != "$expected" ]; then
    echo "ОШИБКА: $label не соответствует эталону." >&2
    echo "  ожидалось: $expected" >&2
    echo "  получено:  $actual" >&2
    rm -f "$file"
    exit 1
  fi
}

fetch() {
  local asset="$1" zip_sha="$2" bin_sha="$3" out="$4"
  echo "Скачивание ${asset}..."
  curl -sfL --fail "${BASE_URL}/${asset}" -o "$TMP_DIR/$asset"
  check_sha256 "$TMP_DIR/$asset" "$zip_sha" "$asset"
  mkdir -p "$out"
  unzip -o -q "$TMP_DIR/$asset" xray geoip.dat geosite.dat -d "$out"
  check_sha256 "$out/xray" "$bin_sha" "xray из $asset"
}

fetch "Xray-macos-64.zip" "$ZIP_X64_SHA256" "$BIN_X64_SHA256" "$TMP_DIR/x64"
fetch "Xray-macos-arm64-v8a.zip" "$ZIP_ARM64_SHA256" "$BIN_ARM64_SHA256" "$TMP_DIR/arm64"

echo "Сборка универсального бинарника..."
lipo -create -output "$DEST/xray" "$TMP_DIR/x64/xray" "$TMP_DIR/arm64/xray"
chmod 755 "$DEST/xray"
check_sha256 "$DEST/xray" "$UNIVERSAL_SHA256" "универсальный xray"

echo "Проверка SHA-256 geo-баз..."
check_sha256 "$TMP_DIR/arm64/geoip.dat" "$GEOIP_SHA256" "geoip.dat"
check_sha256 "$TMP_DIR/arm64/geosite.dat" "$GEOSITE_SHA256" "geosite.dat"
cp "$TMP_DIR/arm64/geoip.dat" "$TMP_DIR/arm64/geosite.dat" "$DEST/"

echo "Готово: $DEST/xray (x86_64 + arm64) и geo-базы (SHA-256 подтверждён)"
"$DEST/xray" version | head -1
