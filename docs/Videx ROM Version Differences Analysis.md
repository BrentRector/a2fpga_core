# Three Videx Videoterm Firmware ROMs: A Detailed Comparison

## Setting

The Videx Videoterm is an 80-column display card for the Apple II family, introduced 1979 and produced through the mid-1980s. Its 2 KB firmware (a 2716 EPROM) maps into the Apple II's expansion ROM window at `$C800-$CBFF` and contains the entire driver: a Pascal 1.1 firmware preamble, BASIC `COUT`/`KEYIN` handlers, Apple-`GETLN`-aware input, an ESC-sequence interpreter, scroll/cursor/clear routines, plus a one-time `SETUP` block that initializes the on-card 6845 CRTC chip to produce video timing.

We have three 1024-byte ROM dumps from real cards:

- **`Videx Videoterm ROM 2.4.bin`** — the baseline disassembled version, labeled "v2.4 (50 Hz / European)" by the original disassembler. PAL frame rate.
- **`Videx Videoterm ROM VT-FRM-600.bin`** — captured from a physical Videx Videoterm card with a ROM labeled VT-FRM-600 (c) 1982 VIDEX.
- **`Videx Videoterm ROM VT-FRM-602.bin`** — captured from a physical Videx Videoterm card with a ROM labeled VT-FRM-602 (c) 1983 VIDEX.

After meticulous transcription from photographic dumps, cross-checked against valid 6502 disassembly and confirmed byte-by-byte, the diffs are precise: **FRM-600 differs from 2.4 in 17 bytes; FRM-602 differs from 2.4 in 13 bytes**. Every single one of those differences sits within a 13-byte stretch from `$C808` to `$C82D` (the SETUP routine) and a 16-byte stretch from `$C8A1` to `$C8B0` (the CRTC initialization table). Nothing else changes — every other byte of the firmware, all 994+ of them, is byte-identical across all three variants.

That last point is worth restating: from a programmer's point of view, the three ROMs are functionally indistinguishable. The same Pascal entry vectors. The same ESC sequences. The same CR/LF/scroll/cursor behavior. The same Ctrl-S pause and Ctrl-C resume. The same GETLN-aware input handler at `$CB32` that writes through `(BASL),Y` to un-blink the cursor before polling the keyboard. The Videoterm's *behavior* with respect to the Apple II is the same firmware in all three. What differs is purely *the picture it paints* — how the on-card CRTC drives a CRT monitor.

## The two distinct changes

### Change #1: the SETUP loop reorganization (shared by 600 and 602; absent in 2.4)

ROM 2.4 initializes the 16 CRTC registers (R0 through R15) by counting up from index 0:

```asm
$C819:  A2 00            LDX #$00
LOOP:
$C81B:  8A               TXA           ; A = X (register number)
$C81C:  8D B0 C0         STA $C0B0     ; CRTC address reg <- X
$C81F:  BD A1 C8         LDA TABLE,X   ; A = init value for reg X
$C822:  8D B1 C0         STA $C0B1     ; CRTC data reg <- value
$C825:  E8               INX
$C826:  E0 10            CPX #$10      ; reached 16?
$C828:  D0 F1            BNE LOOP      ; no -- loop
SETEXIT:
$C82A:  8D 59 C0         STA $C059     ; assert 80-column mode
```

Both FRM-600 and FRM-602 instead count *down* from 15:

```asm
$C819:  A2 0F            LDX #$0F
LOOP:
$C81B:  8A               TXA
$C81C:  8D B0 C0         STA $C0B0
$C81F:  BD A1 C8         LDA TABLE,X
$C822:  8D B1 C0         STA $C0B1
$C825:  CA               DEX
$C826:  10 F3            BPL LOOP      ; X >= 0?  loop
$C828:  E8               INX           ; restore X to 0 (was $FF)
SETEXIT:
$C829:  8D 59 C0         STA $C059
$C82C:  60               RTS
$C82D:  EA               NOP           ; padding
```

The functional outcome is *identical* — both versions write the same 16 init values to the same 16 CRTC registers — but the order of writes is reversed (R15 down to R0 vs. R0 up through R15). The CRTC accepts initialization in any order, so this has no effect on the output picture.

What the rewrite *does* change: the loop tail shrinks from 5 bytes (`E8 E0 10 D0 F1`) to 4 (`CA 10 F3 E8`), saving one byte. That savings is then padded back with a `NOP` at `$C82D` so every address from `$C82E` onward stays at exactly the same position as in 2.4 — preserving binary compatibility with all the rest of the routines, which use absolute addresses to call into each other. Two other small adjustments compensate for the 1-byte shift inside the SETUP block:

- The `BEQ` at `$C807` (which skips the loop entirely if the firmware is already initialized) shifts its operand from `$21` to `$20` to land at the new `SETEXIT` address (`$C829` instead of `$C82A`).
- The `LDX` immediate at `$C81A` changes from `$00` to `$0F` to seed the count-down loop.

Eleven bytes change in total: `$C808`, `$C81A`, and the 9-byte stretch `$C825-$C82D`. **All eleven are bit-for-bit identical between FRM-600 and FRM-602.**

This shared reorganization is the strongest evidence that one of the newer ROMs was derived from the other rather than each being independently re-edited from 2.4. Combined with the copyright dates on the chips — FRM-600 © 1982, FRM-602 © 1983 — the natural reading is that FRM-600 came first as a thorough refresh of ROM 2.4 (refactored SETUP loop, retuned CRTC for NTSC, R0/R7 monitor tweaks), and a year later FRM-602 was derived from the FRM-600 codebase by reverting the NTSC-specific CRTC values back to their 2.4 PAL counterparts.

### Change #2: the CRTC initialization table

The 16-byte `TABLE` at `$C8A1-$C8B0` holds the values written into CRTC registers R0-R15. ROM 2.4's table embodies the standard PAL 50 Hz timing the European Videoterm shipped with. The two newer variants change different subsets of those bytes. Side-by-side:

| CRTC Reg | Function | 2.4 | FRM-602 | FRM-600 | What it does |
|---|---|---|---|---|---|
| R0 | Horizontal Total - 1 | `$7A` (122) | `$7B` (123) | `$7B` (123) | Total char clocks per scan line |
| R1 | Horizontal Displayed | `$50` (80) | `$50` (80) | `$50` (80) | Active char positions |
| R2 | HSync Position | `$5E` (94) | `$5E` (94) | `$5C` (92) | When sync starts (in chars) |
| R3 | HSync Width | `$2F` (15) | `$2F` (15) | `$29` (9) | Sync pulse width (in char clocks) |
| R4 | Vertical Total - 1 | `$22` (34) | `$22` (34) | `$1B` (27) | Total char rows per frame |
| R5 | V-Total Adjust | `$00` (0) | `$00` (0) | `$08` (8) | Extra scanlines after V-total |
| R6 | Vertical Displayed | `$18` (24) | `$18` (24) | `$18` (24) | Active char rows |
| R7 | VSync Position | `$1D` (29) | `$1A` (26) | `$1A` (26) | When V-sync starts (rows) |
| R8 | Interlace | `$00` | `$00` | `$00` | Non-interlaced |
| R9 | Max Raster | `$08` (8) | `$08` (8) | `$08` (8) | 9 scanlines per char cell |
| R10 | Cursor Start | `$E0` | `$E0` | `$E0` | Cursor disabled / blink mode 3 |
| R11 | Cursor End | `$08` | `$08` | `$08` | — |
| R12-R15 | Display/cursor address | `00 00 00 00` | `00 00 00 00` | `00 00 00 00` | Set at runtime by code |

A few patterns jump out:

- **R0 and R7 change in both 600 and 602, to the same values** (`$7B` and `$1A`). Just like the SETUP reorganization, this is shared evidence of a common ancestor. The R0 tweak adds one char clock of horizontal blanking; the R7 tweak fires VSync three character-rows earlier, leaving more vertical-blanking porch *after* sync for the monitor to stabilize before the next active field. These are both monitor-friendliness tweaks that don't change the overall format, just polish the timing within it.
- **FRM-602 stops there** — those two register tweaks are the entirety of its CRTC change. It still produces a 24-row, 80-column, 9-scanline-cell, 315-scanline, 50 Hz frame, exactly matching 2.4's format. The output is essentially the same picture, sympathetic to a slightly different monitor.
- **FRM-600 additionally retunes R2, R3, R4, R5** — which are exactly the registers that determine *frame rate*, not just monitor compatibility within a frame rate. This is what converts the variant from PAL 50 Hz to NTSC 60 Hz.

## Frame timing math

The Videoterm's pixel clock is approximately 17.43 MHz, divided by 9 dots per character cell to give a character clock of about 1.937 MHz. Frame rate is then `char_clock / (htotal × vtotal_scanlines)`, where `vtotal_scanlines = (R4 + 1) × (R9 + 1) + R5`.

Plugging in:

| Variant | htotal | V rows × cell + adj | V scanlines | Frame rate |
|---|---|---|---|---|
| 2.4 | 123 | 35 × 9 + 0 | 315 | **50.00 Hz** |
| FRM-602 | 124 | 35 × 9 + 0 | 315 | **49.58 Hz** |
| FRM-600 | 124 | 28 × 9 + 8 | 260 | **60.07 Hz** |

The FRM-600 figure of 60.07 Hz is unmistakably NTSC. The 260-scanline V-total isn't true 525-line interlaced NTSC (which would require interlace mode and proper half-line timing) — it's a 60 Hz progressive frame at slightly fewer scanlines than NTSC odd-field, but most NTSC monitors and many TVs accept it as a near-NTSC composite feed. The HSync width also drops from 15 char clocks (~7.7 µs, suitable for PAL) to 9 char clocks (~4.6 µs, the NTSC HSync spec).

FRM-602's 49.58 Hz is essentially the same as 2.4's 50 Hz, just very slightly slower because of the +1 horizontal blanking char and the resulting longer scan-line period.

## What stays identical

It's easy to lose sight of the scale of what *doesn't* change. All three ROMs share, byte-for-byte:

- The Pascal 1.1 firmware identification block at `$CB05-$CB10` (signature bytes plus the INIT/READ/WRITE/STATUS entry-offset table)
- All four Pascal entry routines and their dispatchers
- The BASIC entry sled at `$CB00` and the V-flag-based first-time installer at `$CB4C` that hooks `CSWL`/`KSWL`
- `BASOUT`, `BASOUT1`, `OUTPT1`, and the `OUTPT1` lead-in counter for ESC/goto-XY sequences
- `BASINP` and the GETLN-aware input handler (including the `STA (BASL),Y` cursor unblink)
- `RDKEY`, `KEYIN`, `KEYSTAT` — keyboard polling and shift-key/Ctrl-key folding
- The CRTC-cursor-position routine (`CSRMOV`)
- All of `VTAB`, `BASCLC1`, `PSNCALC`, `CHRPUT` — base-address and VRAM-bank computation
- Scroll, line-feed, clear-end-of-line, clear-end-of-page, home, backspace, up
- The two ESC dispatch tables (`ESCTBL` at `$CBF2` and `XLTBL` at `$CBFA`)
- The control-character dispatch table (`CTLTBL` at `$CA40`)
- The bell, the stop-list (Ctrl-S/Ctrl-C), the inverse-video flag handlers

In other words: 100% of the code that interacts with the CPU is the same in all three ROMs. The differences live entirely in the half-page of bytes that talks to the on-card 6845 about how to draw scan lines.

## Engineering interpretation

Reading the pattern of shared and unshared bytes alongside the chip copyright dates, the most likely development history is:

1. **ROM 2.4** is the original European/PAL release (no copyright date observed in this study; the "v2.4" version label and its un-refactored SETUP loop place it before the FRM-6xx family).
2. **VT-FRM-600 ships in 1982** as a substantial refresh aimed at the North American market: the SETUP loop is rewritten in the more compact DEX/BPL form (saving one byte, padded with NOP for binary address compatibility), the CRTC table is retuned for NTSC 60 Hz timing (R2, R3, R4, R5), and two further CRTC tweaks (R0 +1 char of horizontal blanking, R7 firing VSync 3 rows earlier) are applied for monitor-friendliness on whatever new monitor Videx was qualifying against.
3. **VT-FRM-602 ships in 1983** as the European counterpart of FRM-600. It takes the 1982 FRM-600 codebase and reverts the four NTSC-specific CRTC values (R2, R3, R4, R5) back to their ROM 2.4 PAL values, while keeping the SETUP refactor and the R0/R7 monitor tweaks. The result is essentially "FRM-600's improvements, but for European 50 Hz monitors."

The naming hints at this lineage too: "FRM" presumably stands for "firmware," with the trailing digits encoding the chip's intended scan rate — `-600` for 60 Hz, `-602` for the 50 Hz variant of the same revision family. ROM 2.4 sits outside the FRM-6xx family entirely, predating the SETUP refactor and the R0/R7 polish.

## Practical implications

- **A program that writes legal Apple I/O won't notice** which ROM is in the slot. All three present the same firmware ABI. A binary dependency check based on the Pascal identification bytes will hit the identical signature in all three.
- **A tool that reads the CRTC table** (e.g., a video-mode introspector, or an FPGA replica of the Videoterm) needs to know *which* ROM it has, because the CRTC programming is what determines the output video format. This is exactly the use case driving the interest here — for an FPGA Videoterm replica, the CRTC behavior is what has to match.
- **Mixing variants** is harmless from the Apple II side: a card with FRM-600 in one slot and FRM-602 in another would coexist without firmware conflicts. The picture quality would just differ between the two cards' outputs.
- **For an FPGA replica**, only one of the three needs to be implemented for any given target market — but if you want a "monitor-region" toggle, you have a remarkably small surface area to switch: 13 bytes of SETUP code (or just the 2-6 CRTC init values) is all that varies. Everything else is one shared ROM image.

The bottom line: three almost-identical 1 KB firmwares, fundamentally the same driver, differing only in how they tell the CRTC chip to paint the screen. ROM 2.4 is the original PAL release; FRM-600 (1982) is the next-generation NTSC firmware with refactored SETUP and monitor-friendliness tweaks; FRM-602 (1983) is FRM-600 backported to PAL by reverting just four CRTC timing values.

## Relevance to the A2FPGA implementation

For the A2FPGA virtual Videoterm card in this repository, none of the CRTC differences described above have any effect on the rendered output. The A2FPGA produces HDMI video at a fixed digital timing (a 720×480 frame on the standard a2n20 board), and the renderer scans the on-card VRAM at clk_pixel rate to compose the visible 640×432 active region — 80 chars wide × 24 rows × 9 scanlines per cell × 2× line doubling. That pipeline is independent of whatever the firmware writes into the 6845's horizontal-/vertical-sync registers; nothing in the rendering path consumes R0, R2, R3, R4, R5, or R7. The CRTC register file does still capture every write so that programs which read back R14/R15 (cursor position) or R12/R13 (display start address) get correct values — but the *timing-defining* registers, the exact ones that distinguish ROM 2.4 from FRM-602 from FRM-600, are effectively no-ops on HDMI. Whichever of the three firmware ROMs is loaded, the on-screen picture is identical: 80×24 text at the HDMI sink's native refresh rate, with PAL/NTSC scan rates simply not part of the equation.

This means the choice of firmware ROM for the A2FPGA replica is governed entirely by *firmware behavior* (cursor handling, ESC sequences, GETLN compatibility) — and since all three ROMs are byte-identical outside the SETUP/CRTC region, the choice is essentially arbitrary. The repository defaults to ROM 2.4 because that's the variant with the full annotated disassembly, but FRM-600 or FRM-602 would produce visually identical results when loaded into `videx_rom.hex`.
