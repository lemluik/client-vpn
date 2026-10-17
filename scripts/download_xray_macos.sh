#!/usr/bin/env bash
# Скачать ядро Xray для macOS (universal) и geo-базы.
set -euo pipefail

XRAY_VERSION="v26.3.27"
BASE_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}"
ASSET="Xray-macos.zip"
DEST="macos/Runner/Resources"
GEO_DEST="macos/Runner/Resources/geo"

GEOIP_SHA256="744c97b74c52bae2ac8664fef6ac481d7765cb8432a0df54f0368a88b9b4a354"
GEOSITE_SHA256="adf92de0cfc70e458b399f04c5f912bf42d115ed7e37281b30e2f1c68605e4e9"

mkdir -p "$DEST" "$GEO_DEST"
TMP_ZIP="$(mktemp)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_ZIP" "$TMP_DIR"' EXIT

check_sha256() {
  local file="$1" expected="$2" label="$3"
  local actual
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  if [ "$actual" != "$expected" ]; then
    echo "ОШИБКА: $label не соответствует эталону." >&2
    echo "  ожидалось: $expected" >&2
    echo "  получено:  $actual" >&2
    rm -f "$file"
    exit 1
  fi
}

echo "Скачивание Xray-core ${XRAY_VERSION} (macos-universal)..."
curl -sfL --fail "${BASE_URL}/${ASSET}" -o "$TMP_ZIP"

echo "Распаковка..."
unzip -o -q "$TMP_ZIP" xray geoip.dat geosite.dat -d "$TMP_DIR"

cp "$TMP_DIR/xray" "$DEST/xray"
chmod +x "$DEST/xray"
echo "Готово: $DEST/xray"

echo "Проверка SHA-256 geo-баз..."
check_sha256 "$TMP_DIR/geoip.dat" "$GEOIP_SHA256" "geoip.dat"
check_sha256 "$TMP_DIR/geosite.dat" "$GEOSITE_SHA256" "geosite.dat"

cp "$TMP_DIR/geoip.dat" "$TMP_DIR/geosite.dat" "$GEO_DEST/"

{
  printf '%s  %s  %s\n' "$GEOIP_SHA256" "geoip.dat" "$(wc -c < "$GEO_DEST/geoip.dat" | tr -d ' ')"
  printf '%s  %s  %s\n' "$GEOSITE_SHA256" "geosite.dat" "$(wc -c < "$GEO_DEST/geosite.dat" | tr -d ' ')"
} > "$GEO_DEST/geo-manifest.txt"

echo "Готово: $GEO_DEST (geoip.dat, geosite.dat, манифест)"
