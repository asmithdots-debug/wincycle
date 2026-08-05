#!/bin/sh
# Сборка WinCycle.
#
# Подпись ставится постоянным самодельным сертификатом из отдельной связки
# ключей, а не «на лету» — так отпечаток подписи не меняется от пересборки
# к пересборке (сейчас приложению это не критично: оно не запрашивает
# никаких разрешений, но постоянный отпечаток всё равно избавляет Gatekeeper
# от вопросов при каждом новом запуске).
#
# Связка: ~/Library/Keychains/wincycle.keychain-db (пароль wincycle)
# Сертификат и ключ: ~/.local/src/wincycle/signing/

set -e
cd "$(dirname "$0")"

APP="$HOME/Applications/WinCycle.app"
KEYCHAIN="$HOME/Library/Keychains/wincycle.keychain-db"

if [ ! -f "$KEYCHAIN" ]; then
    echo "Связки для подписи ещё нет. Сначала запустите ./setup-signing.sh"
    exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp WinCycle.icns "$APP/Contents/Resources/WinCycle.icns"

echo "сборка…"
swiftc -O main.swift -o WinCycle -framework AppKit

echo "остановка старой копии…"
osascript -e 'tell application "WinCycle" to quit' 2>/dev/null || true
pkill -x WinCycle 2>/dev/null || true
sleep 1

echo "установка и подпись…"
cp WinCycle "$APP/Contents/MacOS/WinCycle"
security unlock-keychain -p wincycle "$KEYCHAIN"
codesign --force --keychain "$KEYCHAIN" --sign "WinCycle Local Signing" "$APP"

echo "запуск…"
open -a "$APP"
sleep 3
pgrep -l WinCycle || echo "не запустился"
