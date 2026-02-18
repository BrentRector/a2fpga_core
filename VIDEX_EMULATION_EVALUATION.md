# Videx VideoTerm Full Emulation via Apple IIe 80-Column Path

## Evaluation: What Is Needed to Emulate a Videx on an Apple ][+ Using the Existing IIe 80-Column Implementation

---

## 1. Executive Summary

This document evaluates what is required to build a fully self-contained Videx VideoTerm 80-column card emulation within the A2FPGA, targeting Apple ][+ systems, by reusing the existing Apple IIe 80-column text rendering pipeline (`TEXT80_LINE`). The existing Videx "shadow" support (`VIDEX_LINE`) is a passive monitor that requires an external A2DVI card and is not relevant to this effort.

The proposed approach creates a new virtual slot card that actively emulates the Videx hardware interface (firmware ROM, MC6845 CRTC registers, 2 KB VRAM) and translates all Videx state into the IIe internal representation so that the existing `TEXT80_LINE` rendering pipeline produces the display output. No external Videx or A2DVI card is required.

**Key finding:** The approach is feasible but involves five distinct engineering challenges: (1) active bus response for the card interface, (2) Videx-to-IIe address translation for the scrambled text page layout, (3) character encoding translation between the two different schemes, (4) handling Videx hardware scrolling by re-syncing the full screen, and (5) the 9-vs-8 scanline visual difference. Each is analyzed in detail below.

---

## 2. System Comparison: Videx VideoTerm vs Apple IIe 80-Column

| Aspect | Videx VideoTerm | Apple IIe 80-Column |
|--------|----------------|---------------------|
| **Target machine** | Apple ][, ][+ | Apple IIe, IIc |
| **Physical slot** | Slot 3 (required) | Built-in (no slot) |
| **Display chip** | MC6845 CRTC | Custom IOU/MMU |
| **VRAM** | 2 KB on-card, linear | Aux RAM at $0400-$0BFF, scrambled |
| **VRAM addressing** | Linear: `base + row*80 + col` | Apple II text page: scrambled interleave |
| **Character height** | 9 scanlines (R9=8, lines 0-8) | 8 scanlines (lines 0-7) |
| **Character width** | 7 pixels | 7 pixels |
| **Active display** | 560 x 216 (doubled to 560 x 432) | 560 x 192 (doubled to 560 x 384) |
| **HDMI output region** | 720 x 480, 24 px V border | 720 x 480, 48 px V border |
| **Character encoding** | Direct: $00-$7F normal, $80-$FF inverse | Complex: inverse/flash/normal/alt zones |
| **Character ROM** | Separate 4 KB ROM (videx_charrom.hex) | Apple IIe ROM (video.hex) |
| **Hardware scrolling** | Yes (CRTC R12/R13 display start) | No (software must move bytes) |
| **Cursor** | MC6845 R10-R15 (blink modes, position) | Firmware-driven (flashing character) |
| **Activation** | Firmware in slot 3 ROM + AN0 | COL80 soft switch ($C00D) |
| **Mixed mode** | Not supported | Supported (text + graphics) |
| **Character sets** | Up to 11 (bank-switched) | 2 (standard + alternate/MouseText) |

---

## 3. Current A2FPGA Architecture (Relevant Modules)

### 3.1 Text Memory Shadow (`apple_memory.sv:348-359`)

The IIe text page is stored in a 1024 x 32-bit BSRAM (`text_vram`). Each 32-bit word holds 4 bytes organized as:

```
Byte 0 [7:0]   = main RAM, even address
Byte 1 [15:8]  = aux  RAM, even address
Byte 2 [23:16] = main RAM, odd address
Byte 3 [31:24] = aux  RAM, odd address
```

**Write address** (from Apple II bus):
```verilog
wire [11:0] text_write_offset = {!addr[10], addr[9:0], E1};
// write_addr = text_write_offset[11:2]  (10-bit word address)
// byte_enable = 1 << text_write_offset[1:0]
// where E1 = aux_mem_r || m2b0
```

On an Apple ][+, `E1` is always 0 (no auxiliary memory), so only byte positions 0 and 2 (main bank) are ever written. The aux bank (bytes 1 and 3) remains empty.

**Read address** (from video scanner):
```verilog
wire [9:0] text_read_offset = {!video_address[10], video_address[9:1]};
```

### 3.2 TEXT80 Rendering Pipeline (`apple_video.sv:578-612`)

The TEXT80 pipeline processes 4 characters per 28-pixel cycle:

| Stage | Buffer Position | Source Byte | Screen Column |
|-------|----------------|-------------|---------------|
| TEXT_0 + TEXT80_2 | `[13:7]` | `video_data_r[7:0]` (main, even) | col N+1 |
| TEXT80_1 + TEXT80_3 | `[6:0]` | `video_data_r[15:8]` (aux, even) | col N (leftmost) |
| TEXT80_3 + TEXT80_4 | `[27:21]` | `video_data_r[23:16]` (main, odd) | col N+3 |
| TEXT80_3 + TEXT80_5 | `[20:14]` | `video_data_r[31:24]` (aux, odd) | col N+2 |

Display order (left to right): aux-even, main-even, aux-odd, main-odd.

Each character is mapped through the IIe character ROM (`video.hex`) with the address encoding:
```verilog
viderom_a_r = {1'b0,
    data[7] | (data[6] & flash_clk & ~altchar),  // bit 10: inverse/flash
    data[6] & (altchar | data[7]),                // bit 9: alt charset
    data[5:0],                                    // bits 8-3: char code
    scanline[2:0]};                               // bits 2-0: row within char
```

### 3.3 Video Mode Selection (`apple_video.sv:428-436`)

```verilog
wire [2:0] line_type_w =
    (videx_mode_r & text_mode_r & an0_r) ? VIDEX_LINE :  // Existing shadow path
    (!GR & !col80_r) ? TEXT40_LINE :
    (!GR & col80_r)  ? TEXT80_LINE :                      // Target path
    ...
```

### 3.4 Existing Videx Shadow Support (Passive, Not Reused)

The current `VIDEX_LINE` path (`apple_video.sv:613-643`) and Videx VRAM shadow (`apple_memory.sv:175-262`) implement passive monitoring of a real Videx card. This code:
- Only snoops bus writes (never drives the bus)
- Uses its own separate VRAM (2 KB sdpram32)
- Uses its own character ROM (`videx_charrom.hex`)
- Uses its own rendering pipeline with 9-scanline geometry
- Requires an external A2DVI v4.4 card in slot 3

**This existing code serves a fundamentally different purpose and is not reused by the proposed approach.** The new emulation replaces the need for an external card entirely.

### 3.5 Virtual Card Infrastructure (`slotmaker.sv`, `slot_if.sv`)

The A2FPGA already has a virtual slot system supporting multiple card types (SuperSprite, Mockingboard, Super Serial Card, Disk II). Each card:
- Gets a unique 8-bit card ID
- Implements the `slot_if` interface
- Receives `dev_select_n` (I/O at $C0n0-$C0nF), `io_select_n` (ROM at $Cn00-$CnFF), `io_strobe_n` ($C800-$CFFF)
- Can drive data onto the bus in response to reads
- Is configured via `slots.hex` and the PicoSoC slot manager

---

## 4. Proposed Architecture: Videx Emulation Card

### 4.1 Overview

```
Apple ][+ Bus
  └── Slot 3: A2FPGA Virtual Videx Card (new module)
        ├── Provides Videx firmware ROM ($C300-$C3FF, $C800-$CFFF)
        ├── Emulates MC6845 CRTC registers ($C0B0-$C0BF)
        ├── Provides 2 KB VRAM ($CC00-$CDFF) with read/write
        ├── Translates VRAM content → IIe text_vram (address + char mapping)
        ├── Forces internal COL80=1 when active
        └── Existing TEXT80 pipeline renders the output via HDMI
```

### 4.2 New Module: `videx_card.sv`

A new virtual card module implementing `slot_if`, assigned to slot 3 with a new card ID (e.g., ID=5). Components:

**A. Firmware ROM (read-only, active bus response)**
- 256 bytes at $C300-$C3FF (slot ROM)
- 2 KB at $C800-$CFFF (expansion ROM)
- Source: Videx VideoTerm ROM 2.4 (publicly documented and disassembled)
- Active bus response required: when the CPU reads these addresses, the card must drive `data_o` onto the bus
- This is the same pattern used by `super_serial_card.sv` which already serves ROM from BSRAM

**B. MC6845 CRTC Register File (read/write)**
- 16 registers, accessed via index port ($C0B0) and data port ($C0B1)
- Writes: latch index on even address, write data on odd address
- Reads: must return register data on odd address reads (the firmware reads cursor position, etc.)
- Bank selection: bits [3:2] of the $C0Bx address select the VRAM bank (0-3)
- Need all 16 registers, though only R9-R15 affect display behavior

**C. VRAM (2 KB, read/write)**
- 4 banks x 512 bytes, accessible at $CC00-$CDFF
- Must support CPU reads (unlike the shadow mode which only captures writes)
- Bank selected by the address bits used during CRTC index port access
- Stored in sdpram32 (512 x 32-bit words), same as existing shadow VRAM

**D. Address Translation Engine (VRAM → text_vram sync)**
- Converts Videx linear addresses to IIe scrambled text page addresses
- Handles CRTC R12/R13 display start offset
- Must write to both main and aux byte positions in `text_vram`
- Detailed in Section 5

**E. Character Translation (Videx → IIe encoding)**
- Maps Videx character codes to IIe character codes
- Detailed in Section 6

**F. Soft Switch Override**
- When the Videx card is active, forces `COL80=1` internally
- Also needs to ensure `TEXT_MODE=1` during text display
- May need to set `AN0=1` as a compatibility signal

---

## 5. Challenge: Address Translation (Linear → Scrambled)

### 5.1 The Problem

The Videx uses linear VRAM addressing:
```
vram_address = (display_start + row * 80 + col) mod 2048
```

The Apple IIe text page uses the standard Apple II scrambled layout:
```
iie_address = $0400 + (row / 8) * 40 + (row % 8) * 128 + col / 2
bank = col[0]  (0 = aux, 1 = main)
```

The 24 text rows map to these base addresses:

| Row | Address | Row | Address | Row | Address |
|-----|---------|-----|---------|-----|---------|
| 0 | $0400 | 8 | $0428 | 16 | $0450 |
| 1 | $0480 | 9 | $04A8 | 17 | $04D0 |
| 2 | $0500 | 10 | $0528 | 18 | $0550 |
| 3 | $0580 | 11 | $05A8 | 19 | $05D0 |
| 4 | $0600 | 12 | $0628 | 20 | $0650 |
| 5 | $0680 | 13 | $06A8 | 21 | $06D0 |
| 6 | $0700 | 14 | $0728 | 22 | $0750 |
| 7 | $0780 | 15 | $07A8 | 23 | $07D0 |

### 5.2 Per-Write Translation

When the CPU writes a byte to Videx VRAM at address `A`:

1. Compute position relative to display start:
   `pos = (A - display_start) mod 2048`

2. If `pos >= 1920` (80 * 24), the character is offscreen — skip.

3. Compute row and column:
   `row = pos / 80`, `col = pos % 80`

4. Compute IIe text page word address and byte lane:
   ```
   iie_base = row_base_table[row]  // 24-entry lookup table
   iie_addr = iie_base + col / 2
   byte_lane = col[0]              // 0 → aux (byte 1 or 3), 1 → main (byte 0 or 2)
   ```

5. Translate the character code (Section 6).

6. Write the translated character to `text_vram` at the computed address and byte lane.

### 5.3 Division by 80

Computing `row = pos / 80` and `col = pos % 80` in hardware requires either:
- A lookup table (2048 entries → row/col)
- A multiply-shift approximation: `row = (pos * 13) >> 10` (exact for 0-1919)
- Iterative subtraction (too slow for single-cycle)

The multiply-shift approach is preferred, matching the existing `videx_div9_w` pattern:
```verilog
wire [20:0] div80_product = videx_pos * 11'd13;
wire [4:0] videx_row = div80_product[20:10];
wire [6:0] videx_col = videx_pos - videx_row * 7'd80;
```

### 5.4 The Scroll Problem

When CRTC R12/R13 (display start) changes, the mapping of every VRAM address to screen position changes. A single register write can cause all 1920 characters to need re-translation.

**Options:**

**Option A: Full re-sync on scroll**
- Maintain a state machine that iterates through all 1920 positions
- At ~54 MHz clock, this takes ~1920 cycles ≈ 36 microseconds
- The Videx firmware scrolls by changing R12/R13 and then writing one new line (80 chars)
- 36 µs is well within the vertical blanking interval (~1.3 ms)
- **Recommended approach**

**Option B: Continuous background sync**
- A free-running sync engine that continuously copies VRAM → text_vram
- Cycles through all 1920 positions, taking ~36 µs per full pass
- Handles scrolls automatically without special detection
- Adds slight latency (up to 36 µs) for any VRAM write to appear
- Simpler logic, no need to detect R12/R13 changes
- **Alternative approach — simpler but adds imperceptible latency**

**Option C: Dual-port rendering**
- Instead of syncing to text_vram, add a mux at the video scanner level
- When Videx is active, the TEXT80 pipeline reads from Videx VRAM instead of text_vram
- Requires address translation in the read path (IIe scanner address → Videx linear address)
- This is the reverse translation: given the IIe scanner's scrambled address, compute the Videx VRAM address
- Avoids write-side translation entirely but requires modifying the video scanner
- Partially contradicts the goal of reusing the existing TEXT80 path unmodified

---

## 6. Challenge: Character Encoding Translation

### 6.1 The Two Encoding Schemes

**Videx VideoTerm** (mapped through Videx character ROM):
| Code Range | Display |
|-----------|---------|
| $00-$7F | Normal characters (standard ASCII-mapped glyphs) |
| $80-$FF | Inverse characters (pre-inverted in ROM) |

The Videx firmware writes ASCII-like codes to VRAM. The character ROM maps these directly to pixel patterns.

**Apple IIe** (mapped through IIe character ROM with address encoding logic):
| Code Range | bits [7:6] | Display |
|-----------|-----------|---------|
| $00-$3F | 00 | Inverse (chars @A-Z[\]^_ and space-?) |
| $40-$7F | 01 | Flash (same chars, blinking) or MouseText if ALTCHAR |
| $80-$BF | 10 | Normal (same chars, normal display) |
| $C0-$FF | 11 | Normal (same chars, normal display) |

The IIe ROM address bits 10-9 select the display mode (inverse/flash/normal/alt), while bits 8-3 select the character glyph (6-bit code, 64 unique glyphs).

### 6.2 Translation Table

To display a Videx character correctly through the IIe rendering path, each Videx code must be mapped to the IIe code that produces the same visual output.

For **normal** Videx characters ($00-$7F):
- Videx $00-$1F (control chars/symbols) → IIe $80-$9F (normal, low range)
- Videx $20-$3F (space, digits, punctuation) → IIe $A0-$BF (normal, high range)
- Videx $40-$5F (uppercase letters, @[\]^_) → IIe $C0-$DF (normal)
- Videx $60-$7F (lowercase letters, {|}~) → IIe $E0-$FF (normal) **if alternate charset supports lowercase, otherwise approximation needed**

For **inverse** Videx characters ($80-$FF):
- Videx $80-$9F → IIe $00-$1F (inverse)
- Videx $A0-$BF → IIe $20-$3F (inverse)
- Videx $C0-$DF → IIe $00-$1F (inverse, limited to 64 unique inverse glyphs)
- Videx $E0-$FF → IIe $20-$3F (inverse)

### 6.3 Lowercase Character Problem

The standard Apple IIe character ROM has lowercase support in the normal character range ($E0-$FF), but the **inverse** range only has 64 glyphs ($00-$3F → glyphs for @A-Z[\]^_ and space through ?). There are no inverse lowercase glyphs in the standard IIe ROM.

The Videx has inverse lowercase because its ROM contains pre-inverted versions of all 128 characters.

**Options:**
1. **Accept the limitation**: Inverse lowercase characters display as inverse uppercase (minor visual difference, rarely used)
2. **Custom character ROM**: Modify `video.hex` to include inverse lowercase glyphs in unused ROM regions
3. **Use ALTCHAR mode**: The IIe alternate character set replaces flash characters ($40-$7F) with MouseText, which doesn't help with inverse lowercase

**Recommendation:** Option 1 for initial implementation. Inverse lowercase is rare in practice (most Videx software uses normal text with an inverse cursor).

### 6.4 Character ROM Compatibility

The Videx and IIe use **different character ROMs** with different glyph designs. The Videx ROM has taller characters (9 scanlines vs 8) and its own distinctive font. When rendering through the IIe TEXT80 path, characters will use the IIe font, not the Videx font. This is an acceptable trade-off since the goal is functional 80-column emulation, not pixel-exact Videx reproduction.

If pixel-exact Videx appearance is desired, the IIe character ROM (`video.hex`) could be replaced or augmented with Videx-style glyphs, but this affects all IIe text display.

---

## 7. Challenge: 9 vs 8 Scanlines Per Character

### 7.1 The Difference

| Parameter | Videx | IIe TEXT80 |
|-----------|-------|-----------|
| Scanlines/char | 9 (lines 0-8) | 8 (lines 0-7) |
| Active lines | 216 (24 x 9) | 192 (24 x 8) |
| Doubled height | 432 px | 384 px |
| V border | 24 px each side | 48 px each side |

The IIe TEXT80 path hardcodes `window_y_w[2:0]` (3 bits, values 0-7) as the scanline within each character. The Videx uses 4-bit scanline values 0-8.

### 7.2 Impact

Using the IIe TEXT80 path as-is means each character row is 8 scanlines (16 doubled pixels) instead of 9 scanlines (18 doubled pixels). For most characters, scanline 8 is blank (descender space), so the visual difference is:
- Slightly more compact vertical spacing
- Characters with descenders (g, j, p, q, y) lose their lowest descender line
- Total active area: 384 px instead of 432 px (48 px difference, larger borders)

### 7.3 Options

**Option A: Accept 8-scanline rendering (recommended for initial implementation)**
- No changes to the TEXT80 rendering path
- Minor visual difference — most users won't notice
- Simplest implementation

**Option B: Modify TEXT80 to support 9-scanline mode**
- Add a `videx_active` signal that switches the TEXT80 path to 9-scanline geometry
- Change `window_y_w` calculation to use division by 9 instead of shift by 3
- Change vertical borders from 48 to 24 px
- Adds complexity to the shared rendering path
- Could be controlled by a parameter or runtime flag

**Option C: Keep the VIDEX_LINE rendering path for display, but feed it from text_vram**
- Use the existing 9-scanline Videx rendering geometry
- But read data from text_vram instead of Videx VRAM
- Requires reverse address translation in the read path
- Partially defeats the purpose of using the IIe path

---

## 8. Challenge: Write Port Contention on `text_vram`

### 8.1 The Problem

The existing `text_vram` has a single write port driven by the Apple II bus:
```verilog
sdpram32 #(.ADDR_WIDTH(10)) text_vram (
    .write_addr(text_write_offset[11:2]),
    .write_data(write_word),
    .write_enable(write_strobe && bus_addr_0400_0BFF),
    .byte_enable(4'(1 << text_write_offset[1:0])),
    .read_addr(text_read_offset),
    .read_enable(1'b1),
    .read_data(text_data)
);
```

The Videx translation engine also needs to write to `text_vram`. Two writers to one write port requires arbitration.

### 8.2 Options

**Option A: Time-multiplexed write port**
- The Apple II bus writes occur on `phi1_posedge` with `data_in_strobe`
- The Videx sync engine writes during the other half of the clock cycle
- At 54 MHz, there are many clock cycles between bus transactions (~54 cycles per 1 MHz bus cycle)
- Write port can be muxed between bus writes and Videx sync writes
- **Recommended approach**

**Option B: Replace text_vram with true dual-port RAM**
- Some FPGA architectures support dual-port BSRAM
- Adds a second independent write port for the Videx engine
- More resource-intensive, may not be available on all target FPGAs (Gowin GW2A)

**Option C: Intercept at the bus write level**
- Instead of the Videx card writing to its own VRAM and then syncing, have it directly translate the write address on the fly and write to text_vram as if it were a bus write to $0400-$0BFF
- The Videx card modifies the address/data/E1 signals before they reach text_vram
- Fastest (single-cycle per write) but doesn't handle scrolling

---

## 9. Challenge: Active Bus Response

### 9.1 Current Virtual Card Bus Driving

The existing virtual cards (SuperSprite, Mockingboard, Super Serial) already drive data onto the bus for reads. The pattern from `super_serial_card.sv`:

```verilog
assign a2bus_if.data = (rd_en) ? data_o : 8'bZ;
```

The Videx card needs the same capability for:
- Slot ROM reads ($C300-$C3FF)
- Expansion ROM reads ($C800-$CFFF)
- CRTC register reads ($C0B1)
- VRAM reads ($CC00-$CDFF)

### 9.2 Firmware ROM Source

The Videx VideoTerm ROM 2.4 is required. It is a 2 KB firmware image containing:
- $C300-$C3FF: 256-byte slot ROM (identification and cold-start entry)
- $C800-$CFFF: 2048-byte expansion ROM (full terminal driver)

The ROM patches into the Apple II's character output routine (COUT at $FDED) via the slot 3 entry point, providing:
- Terminal emulation (cursor movement, scrolling, clear screen)
- CRTC initialization
- Character output to VRAM
- Keyboard input handling

The firmware is publicly documented and available from historical archives. It would be stored as a `.hex` file and loaded into BSRAM, similar to the existing `cardrom.hex`.

### 9.3 CRTC Register Read-Back

The Videx firmware reads CRTC registers (notably R14/R15 for cursor position). The MC6845 only allows reads of R14 and R15 (cursor address). Registers R0-R13 are write-only on the real MC6845. The emulation should:
- Return stored values for R14 and R15 on reads
- Return $00 or don't-care for R0-R13 reads (write-only on real hardware)

---

## 10. Implementation Plan

### Phase 1: Virtual Card Shell
1. Create `hdl/videx/videx_card.sv` implementing `slot_if`
2. Add card ID (e.g., ID=5) to the slot system
3. Implement firmware ROM serving ($C300-$C3FF, $C800-$CFFF)
4. Implement basic CRTC register file (write index/data, read R14/R15)
5. Implement VRAM read/write with bank selection
6. Wire into board top-level (initially a2n20v2 only)

### Phase 2: VRAM-to-TextRAM Translation Engine
1. Implement character encoding translation (256-entry lookup table)
2. Implement address translation (Videx linear → IIe scrambled + bank)
3. Implement per-write sync: on each VRAM write, compute the IIe address and write to text_vram
4. Implement write port arbitration (time-multiplexed)
5. Force COL80=1 when Videx card is active

### Phase 3: Scroll Handling
1. Detect CRTC R12/R13 changes
2. Implement full-screen re-sync state machine (iterate 1920 positions)
3. Optimize: only re-sync during vertical blanking to avoid visual tearing

### Phase 4: Testing and Refinement
1. Test with Videx-aware software (Apple Writer II, WordStar, etc.)
2. Verify cursor behavior
3. Test hardware scrolling
4. Validate character display accuracy
5. Test on actual Apple ][+ hardware

### Phase 5: Optional Enhancements
1. 9-scanline character support (modified TEXT80 geometry)
2. Multiple character set support (Videx supported up to 11 sets)
3. Videx-style character ROM option
4. Support for other Videx-compatible cards (Wesper, Vision-80, etc.)

---

## 11. Resource Estimates

| Resource | Size | Notes |
|----------|------|-------|
| Firmware ROM | 2 KB BSRAM | Videx VideoTerm ROM 2.4 |
| CRTC registers | 16 x 8 bits | Flip-flops (128 bits) |
| VRAM | 2 KB BSRAM | 512 x 32-bit sdpram32 (reuse existing pattern) |
| Character translation LUT | 256 x 8 bits | Distributed RAM or ROM |
| Row base address LUT | 24 x 10 bits | IIe text page row addresses |
| Sync state machine | ~200 FFs | Address translation + arbitration |
| Division by 80 | 1 multiplier | 11-bit x 11-bit → 21-bit |

Total additional BSRAM: ~4 KB (ROM + VRAM). This is modest given the A2N20v2 has 41 x 18Kbit BSRAM blocks.

---

## 12. Open Questions and Risks

### 12.1 Firmware ROM Licensing
The Videx VideoTerm ROM is copyrighted software from the 1980s. Distribution as part of the FPGA bitstream may have legal implications. Options:
- User provides their own ROM dump (loaded at configuration time)
- Use a compatible open-source terminal firmware
- Investigate if the ROM is considered abandonware

### 12.2 Apple ][+ Bus Signal Differences
The Apple ][+ lacks the `m2sel_n` and `m2b0` signals present on the IIe bus. The current soft switch decoding in `apple_memory.sv` uses `!a2bus_if.m2sel_n` as a condition. On an Apple ][+:
- `m2sel_n` should be tied low (always selected) or the condition removed for ][+ mode
- `m2b0` should be tied low (no bank switching)
- The A2FPGA bus interface may already handle this, but needs verification

### 12.3 Slot 3 Conflicts
On the Apple IIe, slot 3 is special (SLOTC3ROM controls internal vs external ROM). On the Apple ][+, slot 3 is a normal expansion slot. The virtual Videx card must ensure:
- INTCXROM is not set (would block slot ROM access)
- The slot 3 ROM is accessible without IIe-specific enable logic

### 12.4 Write Port Timing
The time-multiplexed write approach for text_vram requires careful timing analysis to ensure the Videx sync engine's writes don't collide with bus-originated writes. At 54 MHz with a 1 MHz bus, there are ~54 FPGA clock cycles per bus cycle, providing ample time.

### 12.5 Software Compatibility
Some Videx software directly accesses the MC6845 registers or VRAM in non-standard ways. The emulation should handle:
- Direct VRAM manipulation (programs that write to $CC00-$CDFF without using firmware)
- Custom CRTC timing (programs that change R0-R8 for non-standard display modes)
- Bank switching between the 4 VRAM banks

### 12.6 Interaction with Existing Shadow Mode
The existing `VIDEX_SUPPORT` passive monitoring and the new active emulation are mutually exclusive. When the virtual Videx card is active, the shadow monitoring path should be disabled to avoid conflicts. This can be controlled via the card enable/disable mechanism.

---

## 13. Comparison of Approaches

| Approach | Complexity | Visual Fidelity | TEXT80 Reuse | Scroll Handling |
|----------|-----------|----------------|-------------|-----------------|
| **A: Full VRAM→text_vram sync** | Medium-High | Good (8-scanline) | Complete | Re-sync engine needed |
| **B: Continuous background sync** | Medium | Good (8-scanline) | Complete | Automatic |
| **C: Read-path mux (render from Videx VRAM)** | Medium | Excellent (9-scanline possible) | Partial | Not needed |
| **D: Hybrid (sync + modified TEXT80)** | High | Excellent | Mostly | Re-sync + geometry change |

**Recommendation:** Start with Approach B (continuous background sync) for simplicity. The sync engine free-runs at 54 MHz, completing a full pass every ~36 µs. This handles scrolling automatically with imperceptible latency. If the latency proves problematic (unlikely), upgrade to Approach A with explicit scroll detection.

---

## 14. Summary

Emulating a Videx VideoTerm on an Apple ][+ using the existing IIe 80-column path is feasible and architecturally sound. The main components are:

1. **New virtual card** (`videx_card.sv`) — medium effort, follows existing card patterns
2. **Firmware ROM** — needs sourcing/licensing, straightforward to integrate
3. **VRAM with read/write** — straightforward, matches existing sdpram32 usage
4. **Address translation** — moderate complexity, well-defined math
5. **Character translation** — 256-byte lookup table, straightforward
6. **Sync engine** — the key new component, handles VRAM → text_vram mapping
7. **Write port arbitration** — standard time-multiplexing
8. **COL80 override** — minor wiring change in apple_memory.sv

The 9-vs-8 scanline difference is the primary visual compromise. The character ROM difference (IIe font vs Videx font) is secondary. Both can be addressed in later phases if needed.
