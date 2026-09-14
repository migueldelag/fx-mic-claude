# firmware

Nothing from Teenage Engineering ships in this repository. The mic's own startup script is read from **your**
device and patched locally.

- `tools/build_fxmic_script.py --from-device` reads `/rom/main.py` from the mic over its serial console and writes
  `firmware/fxmic/main.py` (git-ignored): TE's startup plus handle markers, shake-to-cancel, and the play button
  pinned to slot 1. It is installed on the mic's disk as `fxmic.py` by `tools/install_disk.sh install`.
- `fxmic/boot_main.py` is the two-line boot stub installed as `main.py` on the disk: clear the tick callback, add
  `/fat` to the module path, import `fxmic`. The order matters, see PLAN.md, "Firmware route".
- `te/escape_blank_disk.uf2` (regenerate with `tools/make_escape_uf2.py`) blanks the disk's first 8 KB so the
  firmware reformats it at the next start. Enter the bootloader with the handle held and a double-click on the small
  button above the USB port; a drive called "FX MIC BOOT" appears; drag the file onto it.
- TE's firmware for OS 1.1.2 is at https://teenage.engineering/downloads/ep-2350 if you ever need to reflash. Its
  UF2 covers the program and the script partition, not the disk.
- Never run `mpremote` against the mic's serial port: it toggles DTR/RTS and resets the device. Use `tools/mp_exec.py`.
