#!/usr/bin/env bash
# Скачать xray.exe в assets/xray/ и проверить его целостность.
set -euo pipefail

XRAY_VERSION="v26.3.27"
BASE_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}"
DEST="assets/xray"

# Эталонные SHA-256 для Xray-core v26.3.27 (Xray-windows-64.zip).
# При смене версии ОБА значения нужно обновить из официального .dgst:
#   curl -sfL "${BASE_URL}/Xray-windows-64.zip.dgst"
ZIP_SHA256="d004c39288ce9ada487c6f398c7c545f7d749e44bdfdd59dbc9f865afba4e1ad"
EXE_SHA256="15c2d007954ac53ba69b80ec91242786b3c0b71d52649165b4ca1d5cc96ef8f1"

mkdir -p "$DEST"
TMP_ZIP="$(mktemp)"
trap 'rm -f "$TMP_ZIP"' EXIT

echo "Скачивание Xray-core ${XRAY_VERSION}..."
curl -sfL --fail "${BASE_URL}/Xray-windows-64.zip" -o "$TMP_ZIP"

echo "Проверка SHA-256 архива..."
ACTUAL_ZIP="$(sha256sum "$TMP_ZIP" | cut -d' ' -f1)"
if [ "$ACTUAL_ZIP" != "$ZIP_SHA256" ]; then
  echo "ОШИБКА: архив повреждён или подменён — распаковка отменена." >&2
  echo "  ожидалось: $ZIP_SHA256" >&2
  echo "  получено:  $ACTUAL_ZIP" >&2
  exit 1
fi

echo "Распаковка..."
unzip -o "$TMP_ZIP" xray.exe -d "$DEST"

echo "Проверка SHA-256 xray.exe..."
ACTUAL_EXE="$(sha256sum "$DEST/xray.exe" | cut -d' ' -f1)"
if [ "$ACTUAL_EXE" != "$EXE_SHA256" ]; then
  echo "ОШИБКА: xray.exe не соответствует эталону — файл удалён." >&2
  echo "  ожидалось: $EXE_SHA256" >&2
  echo "  получено:  $ACTUAL_EXE" >&2
  rm -f "$DEST/xray.exe"
  exit 1
fi

echo "Готово: $DEST/xray.exe (SHA-256 подтверждён)"
"$DEST/xray.exe" version
