#!/bin/zsh
# Builds a release binary and packages dist/WeChat Duo.app and dist/WeChatDuo-<version>.dmg (ad-hoc signed).
set -euo pipefail
cd "${0:A:h}/.."

VERSION=${VERSION:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo 0.1.0)}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+ ]] || VERSION=0.1.0
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
NAME="WeChat Duo"
APP="dist/$NAME.app"
DMG="dist/WeChatDuo-$VERSION.dmg"

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/WeChatDuo

rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WeChatDuo"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Support/Info.plist > "$APP/Contents/Info.plist"
"$APP/Contents/MacOS/WeChatDuo" --cli make-icon "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$APP"

# dmg: drag into Applications to install
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -format UDZO "$DMG"
rm -rf "$STAGE"
(cd dist && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")

echo "built $APP ($VERSION) and $DMG"
