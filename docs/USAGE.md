# Using TSPLAYER

Start `TSPLAYER` from a CP/M drive containing `.PT3` files. The menu lists available files and indicates whether a file is a single-AY module or a TurboSound pair.

## Playback controls

- Press `W` or `S` to move through the list.
- Press `Enter` to play the selected file.
- Press any key during playback to stop and return to the menu.
- Press `Q` from the menu to quit.

## Refresh and LEDs

- Press `R` in the menu to toggle live on-screen meter and elapsed-time refresh. When disabled, playback continues; the screen is not redrawn during playback.
- Press `L` in the menu to toggle the hardware LED meter. Switching it off clears the eight outputs.
- The screen displays separate channel meters for each AY chip. The LED bar shows one combined level per chip, with four LEDs per chip growing from the center outward.

The screen refresh and LED options are independent and both default to enabled. Any key still stops playback, even with screen refresh disabled.

## Supported music

TSPLAYER plays Pro Tracker 3 (`.PT3`) files. A TurboSound file is recognized by its appended footer and contains one module for AY1 and a second for AY2. Other file types, including VGM, are not supported by TSPLAYER.
