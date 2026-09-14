# claude-pack

Sample pack for using the EP-2350 as a push-to-talk mic for Claude.

- chirp.wav: 17 + 18.5 kHz dual tone, 0.15 s, one-shot on all four slots.
  Every press gives the same short chirp. Tap, double tap, and triple tap are told apart by timing. The sample-select button no longer matters.
- config.json: four identical dry presets, so the FX button cannot color the voice. Samples are not ducked.
- Load: copy chirp.wav and config.json to FX MIC DISK, eject, power off with the small button, squeeze to start.
- Restore the party sounds: delete config.json and any 1.wav to 4.wav from the disk, restart. Factory copy in factory-pack/.
- Recovery if the mic will not start: hold sample-select + play while starting, then fix or delete config.json.
