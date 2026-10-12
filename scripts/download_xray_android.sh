#!/usr/bin/env bash
# Скачать ядро Xray для Android (arm64) в jniLibs и проверить его целостность.
#
# Бинарник кладётся под именем libxray.so: Android 10+ разрешает исполнять
# файлы только из каталога распакованных нативных библиотек, а туда попадают
# лишь файлы с таким префиксом.
set -euo pipefail

XRAY_VERSION="v26.3.27"
BASE_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}"
ASSET="Xray-android-arm64-v8a.zip"
DEST="android/app/src/main/jniLibs/arm64-v8a"

# Эталонные SHA-256 для Xray-core v26.3.27 (Xray-android-arm64-v8a.zip).
# ZIP_SHA256 — из официального .dgst, BIN_SHA256 — распакованный файл `xray`:
#   curl -sfL "${BASE_URL}/${ASSET}.dgst"
# Внимание: .dgst описывает АРХИВ, а не бинарник внутри — это разные значения.
ZIP_SHA256="57149ffd48b629c07bf76938e73ab2729fde5910091497eab3e93d1c190f4c1b"
BIN_SHA256="19101a8191d6d606da975f719c8cdb80b8710b87ab17edc00ef74b9e39588714"

mkdir -p "$DEST"
TMP_ZIP="$(mktemp)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_ZIP" "$TMP_DIR"' EXIT

echo "Скачивание Xray-core ${XRAY_VERSION} (android-arm64)..."
curl -sfL --fail "${BASE_URL}/${ASSET}" -o "$TMP_ZIP"

echo "Проверка SHA-256 архива..."
ACTUAL_ZIP="$(sha256sum "$TMP_ZIP" | cut -d' ' -f1)"
if [ "$ACTUAL_ZIP" != "$ZIP_SHA256" ]; then
  echo "ОШИБКА: архив повреждён или подменён — распаковка отменена." >&2
  echo "  ожидалось: $ZIP_SHA256" >&2
  echo "  получено:  $ACTUAL_ZIP" >&2
  exit 1
fi

echo "Распаковка..."
unzip -o -q "$TMP_ZIP" xray -d "$TMP_DIR"

echo "Проверка SHA-256 бинарника..."
ACTUAL_BIN="$(sha256sum "$TMP_DIR/xray" | cut -d' ' -f1)"
if [ "$ACTUAL_BIN" != "$BIN_SHA256" ]; then
  echo "ОШИБКА: бинарник не соответствует эталону — файл не установлен." >&2
  echo "  ожидалось: $BIN_SHA256" >&2
  echo "  получено:  $ACTUAL_BIN" >&2
  exit 1
fi

cp "$TMP_DIR/xray" "$DEST/libxray.so"
echo "Готово: $DEST/libxray.so (SHA-256 подтверждён)"
