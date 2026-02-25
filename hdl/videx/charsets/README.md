# Videx VideoTerm Alternate Character Set ROMs

Alternate character generator ROMs for the Videx VideoTerm 80-column card.
The physical card has two EPROM sockets: U-20 (standard ASCII, always present)
and U-17 (optional alternate character set). These files are for U-17.

## Source

All ROMs sourced from [btb/80ColumnCard](https://github.com/btb/80ColumnCard/tree/main/character_roms)
(Apache 2.0 license). Original provenance per that repository:

- **Videx Videoterm Utilities disk 1.3** (extracted from disk image):
  french, german, katakana, norsk, russian, epson, super_subscript, symbol
- **Apple II Documentation Project** (hand-copied from manual by Marc S. Ressl):
  apl, spanish
- **ftp.apple.asimov.net mirror**:
  graphics (line drawing + Japanese characters)

## Format

Each file is 2048 lines of hex bytes (one byte per line), matching the format
used by `$readmemh` in SystemVerilog. Each ROM contains 128 characters x 16
scanlines = 2048 bytes. Inverse characters (0x80-0xFF) are generated at runtime
by XOR, same as the standard character ROM.

**Bit order**: All bytes have been bit-reversed from the original hardware ROM
dumps. The physical Videx uses a 74LS166 shift register (MSB-first, bit 7 =
leftmost pixel). The FPGA rendering pipeline shifts LSB-first (bit 0 = leftmost
pixel). The bit reversal ensures correct visual rendering without pipeline changes.

## Character Sets

| File | Characters | Notes |
|------|-----------|-------|
| `videx_charrom_french.hex` | French accented | e-acute, c-cedilla, etc. replace punctuation |
| `videx_charrom_german.hex` | German umlauts | a/o/u-umlaut, eszett replace punctuation |
| `videx_charrom_spanish.hex` | Spanish accented | n-tilde, inverted punctuation, etc. |
| `videx_charrom_norsk.hex` | Norwegian | ae, oe, aa ligatures |
| `videx_charrom_russian.hex` | Cyrillic | Russian alphabet |
| `videx_charrom_katakana.hex` | Japanese Katakana | Phonetic Japanese characters |
| `videx_charrom_apl.hex` | APL symbols | APL programming language operators |
| `videx_charrom_epson.hex` | Epson printer | Matches Epson dot-matrix character set |
| `videx_charrom_graphics.hex` | Line drawing | Box-drawing, semigraphics, some Japanese |
| `videx_charrom_super_subscript.hex` | Super/subscript | Mathematical superscript and subscript |
| `videx_charrom_symbol.hex` | Symbol | Various symbols (**BAD_DUMP** per MAME) |

## Usage

Not currently integrated into the build. To use an alternate character set as
the primary charrom, copy the desired file over `hdl/video/videx_charrom.hex`
(or modify `videx_card.sv` to reference a different filename). See
VIDEX_IMPLEMENTATION_SPEC.md section 27.2 for the gap analysis on alternate
character set support.

## Caveats

- The **symbol** ROM is flagged as `BAD_DUMP` in MAME — some characters may be
  inaccurate (reconstructed from manual screenshots, not chip dump).
- The **graphics** ROM layout "doesn't seem to correspond" with the manual's
  Figure 5 per the btb README. It also contains Japanese characters.
- The standard ASCII charrom (`hdl/video/videx_charrom.hex`) is NOT in this
  directory — it remains in its original location for the build system.
