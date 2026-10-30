#!/bin/zsh
# Compile Island.app.
#   ./build.sh           → build/Island.app
#   ./build.sh install   → copie dans /Applications et lance l'app
#   ./build.sh dist      → build/Island.zip, signé ad hoc, prêt à publier
set -euo pipefail
cd "${0:A:h}"

# Assemblé hors du dossier (synchronisé par iCloud, qui ajoute des attributs que codesign refuse).
STAGE=$(mktemp -d)
APP="$STAGE/Island.app"
trap 'rm -rf "$STAGE"' EXIT

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Island"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -X "$BIN" "$APP/Contents/MacOS/Island"
cp -X Resources/Info.plist "$APP/Contents/Info.plist"
cp -X Bridge/bridge.pl "$APP/Contents/Resources/"
clang -fobjc-arc -O2 -dynamiclib -framework Foundation \
  Bridge/NowPlayingBridge.m -o "$APP/Contents/Resources/NowPlayingBridge.dylib"

xattr -cr "$APP"

# Signature stable : macOS garde les autorisations d'une compilation à l'autre.
# Sans certificat, ou pour une version publiée (le certificat personnel n'a pas à voyager) : signature ad hoc.
IDENTITY=""
if [[ "${1:-}" != dist ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
fi
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/Resources/NowPlayingBridge.dylib"
codesign --force --sign "${IDENTITY:--}" "$APP"

rm -rf build/Island.app
mkdir -p build
ditto "$APP" build/Island.app
echo "→ build/Island.app"

if [[ "${1:-}" == dist ]]; then
  rm -f build/Island.zip
  ditto -c -k --keepParent "$APP" build/Island.zip
  echo "→ build/Island.zip"
fi

if [[ "${1:-}" == install ]]; then
  pkill -x Island || true
  rm -rf /Applications/Island.app
  ditto "$APP" /Applications/Island.app
  open /Applications/Island.app
  echo "→ /Applications/Island.app lancée"
fi
