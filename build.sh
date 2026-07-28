#!/bin/sh
# Сборка WinCycle.
#
# Подпись ставится постоянным самодельным сертификатом из отдельной связки
# ключей, а не «на лету». Это принципиально: разрешение «Универсальный доступ»
# macOS привязывает к отпечатку подписи, и при подписи на лету отпечаток
# меняется от каждой правки кода — система считает приложение новым и требует
# выдавать доступ заново. С постоянным сертификатом отпечаток не плавает.
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
mkdir -p "$APP/Contents/MacOS"
if [ ! -f "$APP/Contents/Info.plist" ]; then
    cp "$(dirname "$0")/Info.plist" "$APP/Contents/Info.plist"
fi

echo "сборка…"
swiftc -O main.swift -o WinCycle -framework AppKit -framework Carbon

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
