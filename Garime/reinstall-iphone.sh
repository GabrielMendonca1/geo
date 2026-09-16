#!/bin/bash
# Reinstala o Garime no iPhone (perfil de conta gratuita expira a cada 7 dias).
# Uso: ./reinstall-iphone.sh    — iPhone no cabo e DESBLOQUEADO.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Applications/Xcode-beta.app/Contents/Developer}"
DEVICE="2C856086-CE1B-5E7B-9B09-4F98117576FA"
cd "$(dirname "$0")"
APP="build/resign-device/Build/Products/Debug-iphoneos/Garime.app"

echo "==> build (assinando com perfil novo)"
xcodebuild -project Garime.xcodeproj -scheme Garime -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build/resign-device \
  -allowProvisioningUpdates -skipPackagePluginValidation \
  DEVELOPMENT_TEAM=6RRNRWCXSD build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

echo "==> perfil expira em: $(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw -)"

echo "==> instalando (aguarda ate 60s pelo desbloqueio)"
for i in $(seq 1 12); do
  if OUT=$(xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1) \
     && echo "$OUT" | grep -q installationURL; then
    echo "$OUT" | grep -E "bundleID|installationURL"
    echo "==> OK"; exit 0
  fi
  echo "   tentativa $i falhou (device bloqueado?); retry em 5s"
  sleep 5
done
echo "$OUT" >&2; exit 1
