#!/bin/zsh
# One disk-mode session on the EP-2350.
#   tools/disk_session.sh backup        copy everything on "fx-mic disk" into factory-pack/ (only if empty) and list it
#   tools/disk_session.sh load <dir>    copy <dir>/1.wav..4.wav (and config.json if present) onto the disk
#   tools/disk_session.sh eject         eject the disk so the mic restarts with the new sounds
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISK="$(ls -d /Volumes/*[Ff][Xx]*[Mm][Ii][Cc]* 2>/dev/null | head -1)"
[ -n "$DISK" ] && [ -d "$DISK" ] || { echo "no FX MIC DISK volume. Put the mic in disk mode: hold the handle and double-click the small button above the USB port."; exit 1; }
case "${1:-}" in
  backup)
    if [ -n "$(ls -A "$ROOT/factory-pack" 2>/dev/null)" ]; then echo "factory-pack/ already has files, not overwriting"; else
      rsync -a --exclude '.Spotlight-V100' --exclude '.fseventsd' --exclude '.Trashes' --exclude '._*' "$DISK/" "$ROOT/factory-pack/"
      echo "backed up to factory-pack/"; fi
    echo "--- disk contents ---"; ls -la "$DISK"; df -h "$DISK" | tail -1
    [ -f "$DISK/config.json" ] && { echo "--- config.json ---"; cat "$DISK/config.json"; } || echo "(no config.json on the disk)"
    ;;
  load)
    SRC="${2:?usage: load <dir>}"
    for n in 1 2 3 4; do [ -f "$SRC/$n.wav" ] && cp "$SRC/$n.wav" "$DISK/$n.wav" && echo "wrote $n.wav"; done
    [ -f "$SRC/config.json" ] && cp "$SRC/config.json" "$DISK/config.json" && echo "wrote config.json"
    [ -f "$SRC/chirp.wav" ] && cp "$SRC/chirp.wav" "$DISK/chirp.wav" && echo "wrote chirp.wav"
    sync; ls -la "$DISK"
    ;;
  eject)
    diskutil eject "$DISK" && echo "ejected, the mic restarts with the new sounds"
    ;;
  *) sed -n '2,6p' "$0"; exit 2 ;;
esac
