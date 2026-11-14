#!/usr/bin/env bash
# Construit build/Supervox.app (compilation release, icône, Info.plist, signature).
#
# Signature : avec l'identité nommée par SUPERVOX_SIGN_IDENTITY si elle est définie (par exemple un
# certificat auto-signé du trousseau de connexion) ; sinon ad hoc, et alors le système redemande le
# micro et l'Accessibilité après chaque compilation.
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release --product Supervox
binary="$(swift build -c release --show-bin-path)/Supervox"

app="build/Supervox.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Supervox"

# Icône : dessinée par le code (BrandMark), puis assemblée en .icns. Aucune image n'est suivie dans le dépôt.
iconset="$(mktemp -d)/Supervox.iconset"
swift run -c release supervox-snapshots --iconset "$iconset" >/dev/null
iconutil -c icns "$iconset" -o "$app/Contents/Resources/Supervox.icns"
rm -rf "$(dirname "$iconset")"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>fr</string>
    <key>CFBundleExecutable</key>
    <string>Supervox</string>
    <key>CFBundleIconFile</key>
    <string>Supervox</string>
    <key>CFBundleIdentifier</key>
    <string>dev.supervox.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Supervox</string>
    <key>CFBundleDisplayName</key>
    <string>Supervox</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Supervox écoute le micro pendant une dictée ou un entretien, pour transcrire ce que vous dites.</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null

if [[ -n "${SUPERVOX_SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp=none --sign "$SUPERVOX_SIGN_IDENTITY" "$app"
    echo "Signé avec l'identité « $SUPERVOX_SIGN_IDENTITY »."
else
    codesign --force --sign - "$app"
    echo "Attention : signature ad hoc (SUPERVOX_SIGN_IDENTITY n'est pas définie)." >&2
    echo "Le micro et l'Accessibilité seront redemandés après chaque compilation." >&2
fi

codesign --verify --strict "$app"
echo "Exigence désignée :"
codesign --display --requirements - "$app" 2>&1 | sed -n -E 's/^(# )?designated => /  /p'
echo "Bundle : $app"
