# Building TSPLAYER

## Toolchain

TSPLAYER is Z80 assembly source for TASM 3.x / TASM32. The source uses the RomWBW build define `WBW` and the TASM options shown below. Use a TASM build compatible with your Windows or DOS environment; older TASM32 packages may require a compatible runtime environment.

## Assemble

From the directory containing `TSPLAYER.ASM`:

```text
tasm -t80 -g3 -fFF -dWBW TSPLAYER.ASM TSPLAYER.COM TSPLAYER.LST
```

This produces `TSPLAYER.COM` and the assembler listing `TSPLAYER.LST`. Keep the listing for debugging if needed; it is generated output and does not need to be committed for normal use.

## Install on CP/M

Transfer `TSPLAYER.COM` to a CP/M drive and place the `.PT3` music files there. Start it from the CP/M prompt with:

```text
TSPLAYER
```

Use the transfer method appropriate to the target system (for example, serial transfer). The target needs RomWBW HBIOS console and AY sound support.

## Hardware configuration

For single-chip playback, configure the AY device through HBIOS as required by the target. For the TurboSound board, both chips use the same AY port pair and are selected in software with `$F8` / `$F9`; no second AY entry in HBIOS is expected. LED output uses Digital I/O port 0. Hardware adaptation values are defined by the `LEDPORT`, `LEDXOR`, and `TSBOARD` constants in `TSPLAYER.ASM`.
