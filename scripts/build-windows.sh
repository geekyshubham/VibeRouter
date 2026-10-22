#!/bin/bash
# Cross-compile VibeRouter for Windows: a taskbar app plus the local proxy.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

ARCH="${1:-amd64}"
case "$ARCH" in
  amd64|x86_64) GOARCH="amd64" ;;
  arm64) GOARCH="arm64" ;;
  *) echo "Unknown arch: $ARCH (want amd64 or arm64)" >&2; exit 1 ;;
esac

STAGE="dist/VibeRouter-windows-${GOARCH}"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# The proxy name must differ by more than letter case. The zip is built on
# macOS, where VibeRouter.exe and viberouter.exe are one file.
./scripts/build-cliproxy-plus.sh "windows-${GOARCH}" "$STAGE/viberouter-proxy.exe"
file "$STAGE/viberouter-proxy.exe" | grep -q 'PE32+'
file "$STAGE/viberouter-proxy.exe" | grep -q 'console'
grep -a -q 'VibeRouter' "$STAGE/viberouter-proxy.exe"

# Taskbar app. windowsgui keeps it off the console and on the taskbar.
(
  cd windows/tray
  GOOS=windows GOARCH="$GOARCH" CGO_ENABLED=0 \
    go build -ldflags "-H windowsgui -s -w" -o "$PROJECT_DIR/$STAGE/VibeRouter.exe" .
)
file "$STAGE/VibeRouter.exe" | grep -q 'PE32+'
file "$STAGE/VibeRouter.exe" | grep -q 'GUI'

cp src/Sources/Resources/config.yaml "$STAGE/config.yaml"
python3 - "$STAGE/start-viberouter.cmd" <<'PY'
import pathlib, sys
src = pathlib.Path("windows/start-viberouter.cmd").read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
pathlib.Path(sys.argv[1]).write_bytes(src)
PY
cp windows/README.txt "$STAGE/"
# 32x32 PNG wrapped as an ICO. LoadImage on Windows accepts the PNG payload.
sips -z 32 32 icon.png --out "$STAGE/icon-32.png" >/dev/null
python3 - "$STAGE/icon-32.png" "$STAGE/icon.ico" <<'PY'
import pathlib, struct, sys
png = pathlib.Path(sys.argv[1]).read_bytes()
header = struct.pack("<HHH", 0, 1, 1)
entry = struct.pack("<BBBBHHII", 32, 32, 0, 0, 1, 32, len(png), 22)
pathlib.Path(sys.argv[2]).write_bytes(header + entry + png)
PY
rm -f "$STAGE/icon-32.png"

ZIP="dist/VibeRouter-windows-${GOARCH}.zip"
rm -f "$ZIP"
# macOS copies an AppleDouble sidecar next to config.yaml unless resource
# forks are left out. Windows does not want that file.
xattr -cr "$STAGE"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$STAGE" "$ZIP"
echo "Windows package: $ZIP"
ls -lh "$STAGE/VibeRouter.exe" "$STAGE/viberouter-proxy.exe" "$ZIP"
test "$(stat -f %i "$STAGE/VibeRouter.exe")" != "$(stat -f %i "$STAGE/viberouter-proxy.exe")"
