#!/bin/zsh
# Install (or remove) the handle-marker setup on the mic's disk while "FX MIC DISK" is mounted on the Mac.
#   tools/install_disk.sh install [pack]   boot stub as main.py; fxmic.py, config.json and a marker pack in claude/
#                                          (default marker-pack; marker-pack-lowband for adapters that cut above ~7 kHz)
#   tools/install_disk.sh remove           deletes main.py and claude/ so TE's built-in startup runs again
# Afterwards eject the disk, unplug, power off with the small button (or pull the batteries), squeeze to start.
# Once installed, with the mic on hold orange (FX) 3 s for Claude mode or white (sample) 3 s for stock (factory
# effects and sounds, for example with a K.O. II), then restart the mic. The mode is saved in claude/mode.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISK="$(ls -d /Volumes/*[Ff][Xx]*[Mm][Ii][Cc]* 2>/dev/null | grep -v -i boot | head -1)"
[ -n "$DISK" ] && [ -d "$DISK" ] || { echo "FX MIC DISK is not mounted (mic on, USB-C data cable in)."; exit 1; }
# Files earlier versions put at the disk root; at the root they would override the factory sounds in stock mode.
OLD_ROOT_FILES=(fxmic.py config.json chirp.wav cancel.wav press.wav release.wav)
case "${1:-}" in
  install)
    [ -f "$ROOT/firmware/fxmic/main.py" ] || { echo "firmware/fxmic/main.py is missing: build it from your mic first with tools/build_fxmic_script.py --from-device"; exit 1; }
    grep -q "/fat/claude" "$ROOT/firmware/fxmic/main.py" || { echo "firmware/fxmic/main.py predates the claude/ folder: rebuild it with tools/build_fxmic_script.py"; exit 1; }
    PACK="$ROOT/packs/${2:-marker-pack}"
    [ -f "$PACK/config.json" ] || { echo "no marker pack at $PACK"; exit 1; }
    mkdir -p "$DISK/claude"
    cp -X "$ROOT/firmware/fxmic/main.py" "$DISK/claude/fxmic.py"
    cp -X "$PACK/chirp.wav" "$PACK/cancel.wav" "$PACK/press.wav" "$PACK/release.wav" "$PACK/config.json" "$DISK/claude/"
    [ -f "$DISK/claude/mode" ] || printf claude > "$DISK/claude/mode"
    for f in $OLD_ROOT_FILES; do rm -f "$DISK/$f" "$DISK/._$f"; done
    cp -X "$ROOT/firmware/fxmic/boot_main.py" "$DISK/main.py"          # last: the stub expects claude/ to be complete
    sync; echo "installed $(basename "$PACK") (mode: $(cat "$DISK/claude/mode")):"; ls -la "$DISK" "$DISK/claude" | grep -vE "^total|\.\.?$|/\._"
    if [ -f "$PACK/pitches.json" ]; then
      echo "this pack uses other pitches; point FXMic at them, then restart FXMic:"
      python3 -c "import json,sys; [print('  defaults write com.miguel.fxmic', k, '-array', *v) for k, v in json.load(open(sys.argv[1])).items()]" "$PACK/pitches.json"
    else
      echo "FXMic's built-in pitches match this pack; if you changed them: defaults delete com.miguel.fxmic chirpFreqs (and cancelFreqs, pressFreqs, releaseFreqs)"
    fi
    ;;
  remove)
    rm -f "$DISK/main.py" "$DISK/._main.py"; rm -rf "$DISK/claude"
    for f in $OLD_ROOT_FILES; do rm -f "$DISK/$f" "$DISK/._$f"; done
    sync; echo "removed main.py and claude/; TE's startup runs at the next boot"
    ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac
