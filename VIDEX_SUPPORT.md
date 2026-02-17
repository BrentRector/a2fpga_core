# Videx VideoTerm 80-Column Passive Monitoring

## Overview

A2FPGA supports passive monitoring of Videx VideoTerm 80-column text output on Apple II and Apple II+ systems. When an A2DVI v4.4 card in slot 3 actively emulates a Videx VideoTerm (providing ROM, CRTC registers, and 2 KB VRAM), A2FPGA in another slot passively snoops bus writes to shadow the Videx state and render the 80-column text on its HDMI output.

This is purely passive — A2FPGA never drives the bus for Videx support. The A2DVI handles all active bus responses (ROM reads, register reads, RAM reads). A2FPGA only watches writes go by, using the same bus snooping infrastructure it already uses for Apple II main/aux memory.

### Prerequisites

- Apple II or Apple II+ (Apple IIe has native 80-column support and does not need Videx)
- A2DVI v4.4 card in slot 3 with Videx emulation enabled
- A2FPGA (A2N20v2) in another slot
- `VIDEX_SUPPORT` parameter set to 1 in the board's `top.sv` (enabled by default on a2n20v2)

---

## Architecture

```
Apple II/II+ Bus
  ├── Slot 3: A2DVI v4.4 (bidirectional)
  │     ├── Provides Videx firmware ROM at $C300-$C3FF
  │     ├── Emulates MC6845 CRTC registers at $C0B0-$C0B1
  │     └── Provides 2 KB video RAM at $CC00-$CDFF
  │
  └── Slot N: A2FPGA (A2N20v2)
        ├── Snoops CRTC register writes at $C0B0-$C0B1
        ├── Shadows Videx VRAM writes at $CC00-$CDFF
        ├── Renders Videx 80-column text from shadowed state
        └── Outputs via HDMI
```

---

## Bus Monitoring Protocol

### Address Ranges

| Address Range | Trigger | Action |
|---|---|---|
| `$C0B0` (even) | Slot 3 device I/O | Latches CRTC register index |
| `$C0B1` (odd) | Slot 3 device I/O | Writes data to selected CRTC register |
| `$C300-$C3FF` | Slot 3 ROM access | Sets slot 3 as expansion ROM owner (`SLOTROM == 3`) |
| `$CC00-$CDFF` | Expansion ROM area | VRAM write (only when slot 3 owns $C800-$CFFF) |

### Mode Detection

Videx mode is detected automatically when:
1. Writes to `$C0B0-$C0B1` (CRTC registers) are observed, **and**
2. The `AN0` annunciator is set (the Videx card sets AN0 to signal it is active)

The rendering pipeline activates `VIDEX_LINE` mode when `videx_mode_r && text_mode_r && an0_r`.

### CRTC Register Capture

The MC6845 CRT Controller uses a two-port register interface:
- **Even address** (`$C0B0`): Written data byte is the register index
- **Odd address** (`$C0B1`): Written data byte goes to the selected register

Captured in `apple_memory.sv` and exposed to the renderer via `a2mem_if`.

### Video RAM Shadowing

Videx VRAM (2 KB at `$CC00-$CDFF`) is shadowed in FPGA block RAM. The existing `SLOTROM[2:0]` tracking in `apple_memory.sv` determines when slot 3 owns the `$C800-$CFFF` expansion ROM space. Writes to `$CC00-$CDFF` are captured only when `SLOTROM == 3`.

The 2 KB VRAM is organized as 4 × 512-byte banks. Bank selection is controlled through the CRTC register index port.

---

## Rendering Pipeline

### Display Geometry

| Parameter | Apple II Text | Videx VideoTerm |
|-----------|--------------|-----------------|
| Columns | 40 (or 80 on IIe) | 80 |
| Rows | 24 | 24 |
| Character width | 7 pixels | 7 pixels |
| Character height | 8 scanlines | 9 scanlines |
| Active pixels | 560 × 192 | 560 × 216 |
| Doubled | 560 × 384 | 560 × 432 |
| HDMI output | 720 × 480 | 720 × 480 |
| H border | 80 px each side | 80 px each side |
| V border | 48 px each side | 24 px each side |

### Pipeline Stages

The Videx pipeline processes 4 characters per 28-pixel cycle (same structure as TEXT80):

| Stage | Action |
|-------|--------|
| VIDEX_0 | Issue character ROM lookup for char 0 |
| VIDEX_1 | Issue character ROM lookup for char 1 |
| VIDEX_2 | Capture char 0 pixels (7 bits), issue ROM lookup for char 2 |
| VIDEX_3 | Capture char 1 pixels, issue ROM lookup for char 3 |
| VIDEX_4 | Capture char 2 pixels |
| VIDEX_5 | Capture char 3 pixels |

### VRAM Address Computation

Videx uses linear addressing (not the scrambled Apple II text page layout):
- `line_start = (text_base + row × 80) mod 2048`
- `char_addr = (line_start + column) mod 2048`

Where `text_base` comes from CRTC registers R12/R13 (display start address, used for hardware scrolling).

### Row/Scanline Computation

Division by 9 is computed using a multiply-shift: `row = (content_y × 57) >> 9`, which is exact for the 0–215 range (24 rows × 9 scanlines). The scanline within the row is `content_y - row × 9`.

### Character ROM

The Videx character ROM (`videx_charrom.hex`) contains 256 characters × 16 bytes/character = 4096 entries:
- Characters `$00-$7F`: Normal glyphs
- Characters `$80-$FF`: Inverse glyphs (pre-inverted in ROM)

Only 9 of the 16 bytes per character are used (matching the MC6845 R9 setting of 8, meaning scanlines 0–8). The ROM is stored in distributed SSRAM (not block RAM) and gated by the `VIDEX_SUPPORT` parameter.

### Cursor Rendering

The MC6845 cursor is implemented using CRTC registers R10–R15:
- **R10**: Cursor start scanline + blink mode (bits [6:5])
- **R11**: Cursor end scanline
- **R14/R15**: Cursor position in VRAM

Blink modes:
| R10[6:5] | Mode |
|----------|------|
| `00` | Always visible |
| `01` | Hidden |
| `10` | Blink at 1/16 field rate |
| `11` | Blink at 1/32 field rate |

Cursor is rendered as an XOR mask (`^ 7'h7F`) on the affected character's pixel data for scanlines between `cursor_start` and `cursor_end`.

---

## MC6845 CRTC Register Reference

Default initialization values from the Videx VideoTerm ROM 2.4:

| Reg | Value | Function |
|-----|-------|----------|
| R0 | $7A | Horizontal Total (123 char times) |
| R1 | $50 | Horizontal Displayed (80 characters) |
| R2 | $5E | Horizontal Sync Position |
| R3 | $2F | Horizontal/Vertical Sync Width |
| R4 | $22 | Vertical Total (35 rows) |
| R5 | $00 | Vertical Total Adjust |
| R6 | $18 | Vertical Displayed (24 rows) |
| R7 | $1D | Vertical Sync Position |
| R8 | $00 | Interlace Mode (off) |
| R9 | $08 | Max Scan Line (9 scanlines/row: 0–8) |
| R10 | $E0 | Cursor Start (line 0, blink) |
| R11 | $08 | Cursor End (line 8) |
| R12 | $00 | Display Start Address (high) |
| R13 | $00 | Display Start Address (low) |
| R14 | $00 | Cursor Address (high) |
| R15 | $00 | Cursor Address (low) |

Registers captured by A2FPGA: R10–R15 (cursor and display address). R0–R9 define timing that is handled by the A2DVI emulator and don't affect A2FPGA's rendering.

---

## Files

| File | Purpose |
|------|---------|
| `hdl/video/apple_video.sv` | Videx rendering pipeline, character ROM, cursor logic |
| `hdl/video/videx_charrom.hex` | Videx character ROM (256 chars × 16 bytes) |
| `hdl/memory/apple_memory.sv` | CRTC register capture, VRAM shadow (2 KB BSRAM) |
| `hdl/memory/a2mem_if.sv` | VIDEX_MODE signal, CRTC register interface |
| `tools/gen_videx_rom.py` | Script to generate videx_charrom.hex from A2DVI font data |
| `boards/a2n20v2/hdl/top.sv` | VIDEX_SUPPORT=1, Videx VRAM port wiring |

### Board Support

| Board | VIDEX_SUPPORT |
|-------|---------------|
| a2n20v2 | 1 (enabled) |
| a2n20v2-Enhanced | 0 |
| a2n20v1 | 0 |
| a2mega | 0 |
| a2n9 | 0 |
| a2p25 | 0 |

---

## Known Limitations

1. **Passive only** — Requires a real Videx card (or A2DVI v4.4 emulating one) in slot 3 to handle active bus responses
2. **Single character set** — Currently includes normal + inverse glyphs only (not the full 11 Videx character sets available in A2DVI)
3. **Fixed 9-scanline geometry** — Assumes R9=8 (standard Videx initialization); non-standard CRTC timing is not supported
4. **No VRAM read-back verification** — A2FPGA cannot verify captured VRAM against the actual Videx card state

---

## References

- [A2DVI Firmware](https://github.com/ThorstenBr/A2DVI-Firmware) — Open-source passive Videx monitoring reference
- [Videx VideoTerm ROM 2.4 Disassembly](https://btb.github.io/80ColumnCard/firmware/html/Videx%20Videoterm%20ROM%202.4.bin.html)
- [MC6845 CRTC Reference](http://www.tinyvga.com/6845)
