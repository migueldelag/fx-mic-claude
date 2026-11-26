#!/bin/zsh
# Install (or remove) the handle-marker setup on the mic's disk while "FX MIC DISK" is mounted on the Mac.
#   tools/install_disk.sh install [pack]   copies main.py (boot stub), fxmic.py (startup script), and a marker pack
#                                          (default marker-pack; marker-pack-lowband for adapters that cut above ~7 kHz)
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
    PACK="$ROOT/packs/${2:-marker-pack}"
    [ -f "$PACK/config.json" ] || { echo "no marker pack at $PACK"; exit 1; }
    cp -X "$PACK/chirp.wav" "$PACK/cancel.wav" "$PACK/press.wav" "$PACK/release.wav" "$PACK/config.json" "$DISK/"
    sync; echo "installed $(basename "$PACK"):"; ls -la "$DISK" | grep -E "main.py|fxmic.py|chirp|cancel|press|release|config"
    if [ -f "$PACK/pitches.json" ]; then
      echo "this pack uses other pitches; point FXMic at them, then restart FXMic:"
      python3 -c "import json,sys; [print('  defaults write com.miguel.fxmic', k, '-array', *v) for k, v in json.load(open(sys.argv[1])).items()]" "$PACK/pitches.json"
    else
      echo "FXMic's built-in pitches match this pack; if you changed them: defaults delete com.miguel.fxmic chirpFreqs (and cancelFreqs, pressFreqs, releaseFreqs)"
    fi
    ;;
  remove)
    rm -f "$DISK/main.py" "$DISK/fxmic.py"; sync; echo "removed main.py and fxmic.py; TE's startup runs at the next boot"
    ;;
  *) sed -n '2,6p' "$0"; exit 2 ;;
esac
