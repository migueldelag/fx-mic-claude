#!/bin/zsh
# Install (or remove) the handle-marker setup on the mic's disk while "FX MIC DISK" is mounted on the Mac.
#   tools/install_disk.sh install   copies main.py (boot stub), fxmic.py (startup script), and the marker pack
#   tools/install_disk.sh remove    deletes main.py and fxmic.py so TE's built-in startup runs again
# Afterwards eject the disk, unplug, power off with the small button (or pull the batteries), squeeze to start.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISK="$(ls -d /Volumes/*[Ff][Xx]*[Mm][Ii][Cc]* 2>/dev/null | head -1)"
[ -n "$DISK" ] && [ -d "$DISK" ] || { echo "FX MIC DISK is not mounted (mic on, USB-C data cable in)."; exit 1; }
case "${1:-}" in
  install)
    [ -f "$ROOT/firmware/fxmic/main.py" ] || { echo "firmware/fxmic/main.py is missing: build it from your mic first with tools/build_fxmic_script.py --from-device"; exit 1; }
    cp "$ROOT/firmware/fxmic/main.py" "$DISK/fxmic.py"
    cp "$ROOT/firmware/fxmic/boot_main.py" "$DISK/main.py"
    cp "$ROOT/packs/marker-pack/chirp.wav" "$ROOT/packs/marker-pack/cancel.wav" "$ROOT/packs/marker-pack/press.wav" "$ROOT/packs/marker-pack/release.wav" "$ROOT/packs/marker-pack/config.json" "$DISK/"
    sync; echo "installed:"; ls -la "$DISK" | grep -E "main.py|fxmic.py|chirp|press|release|config"
    ;;
  remove)
    rm -f "$DISK/main.py" "$DISK/fxmic.py"; sync; echo "removed main.py and fxmic.py; TE's startup runs at the next boot"
    ;;
  *) sed -n '2,5p' "$0"; exit 2 ;;
esac
