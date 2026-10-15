#!/usr/bin/env bash
# Скачать ядро Xray для Android (arm64) в jniLibs и geo-базы в assets APK,
# проверить их целостность.
#
# Бинарник кладётся под именем libxray.so: Android 10+ разрешает исполнять
# файлы только из каталога распакованных нативных библиотек, а туда попадают
# лишь файлы с таким префиксом.
#
# Geo-базы идут в assets, потому что ядро читает их из каталога, указанного в
# XRAY_LOCATION_ASSET, а исполняемый каталог для файлов конфига не годится.
# При первом запуске приложение копирует их в filesDir (GeoAssets.kt).
set -euo pipefail

XRAY_VERSION="v26.3.27"
BASE_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}"
ASSET="Xray-android-arm64-v8a.zip"
DEST="android/app/src/main/jniLibs/arm64-v8a"
GEO_DEST="android/app/src/main/assets/geo"

# Эталонные SHA-256 для Xray-core v26.3.27 (Xray-android-arm64-v8a.zip).
# ZIP_SHA256 — из официального .dgst, BIN_SHA256 — распакованный файл `xray`:
#   curl -sfL "${BASE_URL}/${ASSET}.dgst"
# Внимание: .dgst описывает АРХИВ, а не бинарник внутри — это разные значения.
ZIP_SHA256="57149ffd48b629c07bf76938e73ab2729fde5910091497eab3e93d1c190f4c1b"
BIN_SHA256="19101a8191d6d606da975f719c8cdb80b8710b87ab17edc00ef74b9e39588714"

# Geo-базы того же релиза; в архиве Windows значения совпадают.
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

echo "Скачивание Xray-core ${XRAY_VERSION} (android-arm64)..."
curl -sfL --fail "${BASE_URL}/${ASSET}" -o "$TMP_ZIP"

echo "Проверка SHA-256 архива..."
check_sha256 "$TMP_ZIP" "$ZIP_SHA256" "архив"

echo "Распаковка..."
unzip -o -q "$TMP_ZIP" xray geoip.dat geosite.dat -d "$TMP_DIR"

echo "Проверка SHA-256 бинарника..."
check_sha256 "$TMP_DIR/xray" "$BIN_SHA256" "бинарник xray"

cp "$TMP_DIR/xray" "$DEST/libxray.so"
echo "Готово: $DEST/libxray.so (SHA-256 подтверждён)"

echo "Проверка SHA-256 geo-баз..."
check_sha256 "$TMP_DIR/geoip.dat" "$GEOIP_SHA256" "geoip.dat"
check_sha256 "$TMP_DIR/geosite.dat" "$GEOSITE_SHA256" "geosite.dat"

cp "$TMP_DIR/geoip.dat" "$TMP_DIR/geosite.dat" "$GEO_DEST/"

# Манифест читает приложение при установке баз (GeoAssets.kt): суммы лежат
# рядом с файлами и не дублируются в коде.
{
  printf '%s  %s  %s\n' "$GEOIP_SHA256" "geoip.dat" "$(wc -c < "$GEO_DEST/geoip.dat" | tr -d ' ')"
  printf '%s  %s  %s\n' "$GEOSITE_SHA256" "geosite.dat" "$(wc -c < "$GEO_DEST/geosite.dat" | tr -d ' ')"
} > "$GEO_DEST/geo-manifest.txt"

echo "Готово: $GEO_DEST (geoip.dat, geosite.dat, манифест)"
