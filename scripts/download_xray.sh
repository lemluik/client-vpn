#!/usr/bin/env bash
# Скачать xray.exe и geo-базы в assets/xray/ и проверить их целостность.
#
# Geo-базы обязательны: без geoip.dat/geosite.dat любое правило `geoip:`
# или `geosite:` роняет ядро ещё на `run -test` (проверено на 26.3.27).
set -euo pipefail

XRAY_VERSION="v26.3.27"
BASE_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}"
DEST="assets/xray"

# Эталонные SHA-256 для Xray-core v26.3.27 (Xray-windows-64.zip).
# При смене версии ОБА значения нужно обновить из официального .dgst:
#   curl -sfL "${BASE_URL}/Xray-windows-64.zip.dgst"
ZIP_SHA256="d004c39288ce9ada487c6f398c7c545f7d749e44bdfdd59dbc9f865afba4e1ad"
EXE_SHA256="15c2d007954ac53ba69b80ec91242786b3c0b71d52649165b4ca1d5cc96ef8f1"

# Geo-базы из этого же архива (построены из Xray-geoip / Xray-geosite).
# Значения сняты с файлов архива v26.3.27; в архивах Android они совпадают,
# поэтому одна и та же пара сумм закрепляет обе платформы.
GEOIP_SHA256="744c97b74c52bae2ac8664fef6ac481d7765cb8432a0df54f0368a88b9b4a354"
GEOSITE_SHA256="adf92de0cfc70e458b399f04c5f912bf42d115ed7e37281b30e2f1c68605e4e9"

mkdir -p "$DEST"
TMP_ZIP="$(mktemp)"
trap 'rm -f "$TMP_ZIP"' EXIT

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

echo "Скачивание Xray-core ${XRAY_VERSION}..."
curl -sfL --fail "${BASE_URL}/Xray-windows-64.zip" -o "$TMP_ZIP"

echo "Проверка SHA-256 архива..."
check_sha256 "$TMP_ZIP" "$ZIP_SHA256" "архив"

echo "Распаковка..."
unzip -o "$TMP_ZIP" xray.exe geoip.dat geosite.dat -d "$DEST"

echo "Проверка SHA-256 xray.exe..."
check_sha256 "$DEST/xray.exe" "$EXE_SHA256" "xray.exe"

echo "Проверка SHA-256 geo-баз..."
check_sha256 "$DEST/geoip.dat" "$GEOIP_SHA256" "geoip.dat"
check_sha256 "$DEST/geosite.dat" "$GEOSITE_SHA256" "geosite.dat"

echo "Готово: $DEST/xray.exe и geo-базы (SHA-256 подтверждён)"
"$DEST/xray.exe" version
