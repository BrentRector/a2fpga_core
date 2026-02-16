# Claude Code Prompt: Passive Videx Video Monitoring for A2FPGA

## Mission

You are tasked with creating a comprehensive implementation plan for adding **passive Videx VideoTerm monitoring** to the A2FPGA Apple II FPGA coprocessor. This will allow the A2FPGA to display 80-column text on its HDMI output by snooping bus traffic from an A2DVI v4.4 card (installed in slot 3) that is actively emulating a Videx VideoTerm.

This is a multi-phase research and planning task. Use parallel agents wherever possible to maximize efficiency. The final deliverable is a detailed, file-level implementation plan ready for coding.

---

## Architecture Overview

### The Scenario

```
Apple II/II+ Bus
  ├── Slot 3: A2DVI v4.4 (bidirectional) — actively emulates Videx VideoTerm
  │     ├── Provides Videx firmware ROM at $C300-$C3FF
  │     ├── Emulates MC6845 CRTC registers at $C0B0-$C0B1
  │     ├── Provides 2 KB video RAM at $CC00-$CDFF
  │     └── Produces its own HDMI output (ignored by us)
  │
  └── Slot 7 (or other): A2FPGA (A2N20v2, Tang Nano 20K)
        ├── Passively snoops ALL bus writes (already does this)
        ├── Shadows Apple II video RAM (already does this)
        ├── NEW: Also shadows Videx CRTC register writes at $C0B0-$C0B1
        ├── NEW: Also shadows Videx video RAM writes at $CC00-$CDFF
        ├── NEW: Renders Videx 80-column text from shadowed state
        └── Outputs via HDMI (existing pipeline)
```

### Why This Works

When the CPU writes to the emulated Videx card in slot 3, those writes appear on the shared Apple II bus. A2FPGA in another slot sees every bus write. The A2DVI handles all the hard parts (ROM reads, register reads, RAM reads — anything requiring active bus response). A2FPGA only needs to **watch writes go by** — the same passive snooping it already does for main/aux memory.

---

## Existing A2FPGA Codebase Context

### Repository: `BrentRector/a2fpga_core` (fork of `edanuff/a2fpga_core`)

### FPGA Resource Budget (GW2AR-18C, from PnR report)

| Resource | Used | Total | % Used | Available |
|----------|------|-------|--------|-----------|
| **Logic (LUT/ALU)** | 5,494 | 20,736 | **27%** | 15,242 |
| **Registers** | 2,421 | 15,750 | **16%** | 13,329 |
| **CLS** | 3,800 | 10,368 | **37%** | 6,568 |
| **BSRAM** | ~41 blocks | ~46 blocks | **~90%** | **~5 blocks (10 KB)** |
| **DSP** | 5 units | ~52 units | **9%** | ~47 |
| **PLL** | 2 | 2 | **100%** | 0 |
| **OSER10** | 3 | ~8 | **38%** | ~5 |

**CRITICAL CONSTRAINT: BSRAM is at ~90%.** Only ~5 BSRAM blocks (~10 KB) remain free. The Videx module needs:
- 2 KB video RAM shadow (1 BSRAM block)
- 2-4 KB character ROM (1-2 BSRAM blocks)
- CRTC registers: 18 bytes (fits in LUT RAM, no BSRAM needed)
- **Total: 2-3 BSRAM blocks** — feasible but tight. Must NOT waste BSRAM.

All other resources (logic, registers, DSP) have ample headroom.

### Key Source Files

**Bus snooping & memory**: `hdl/memory/apple_memory.sv` (387 lines)
- Captures soft switches at $C000-$C00F and $C050-$C05F
- Shadows text VRAM ($0400-$07FF) and hires VRAM ($2000-$5FFF) in BSRAM
- Already tracks INTC8ROM and SLOTROM[2:0] for expansion ROM space ownership
- `write_strobe = !a2bus_if.rw_n && a2bus_if.data_in_strobe` — the write detection signal
- `phi1_posedge` — valid address phase for soft switch capture

**Video rendering**: `hdl/video/apple_video.sv` (643 lines)
- State machine processes 28 pixels per cycle (STEP_LENGTH = 28)
- Line types: TEXT40_LINE(0), TEXT80_LINE(1), LORES40(4), LORES80(5), HIRES40(6), HIRES80(7)
- Character ROM: 4 KB `video.hex`, addressed as `viderom_r[{3-bit-mode, 6-bit-char, 3-bit-row}]`
- Each character: 7 pixels wide, 8 scanlines tall
- Display window: 560×384 active pixels centered in 720×480 HDMI frame
- 80-pixel H borders, 48-pixel V borders
- line_type_w selects rendering pipeline based on soft switches
- `lineaddr()` function generates Apple II scrambled row addresses

**Memory interface**: `hdl/memory/a2mem_if.sv` (142 lines)
- SystemVerilog interface with master/slave modports
- Exposes all soft switches: TEXT_MODE, COL80, STORE80, PAGE2, etc.
- Also exposes INTC8ROM, SLOTROM[2:0] (expansion ROM space tracking)

**Bus interface**: `hdl/bus/a2bus_if.sv` (121 lines)
- Bus signals: addr[15:0], data[7:0], rw_n, phi1_posedge, data_in_strobe, m2sel_n

**Top-level (A2N20v2)**: `boards/a2n20v2/hdl/top.sv` (683 lines)
- Instantiates: apple_memory → apple_video → vgc → SuperSprite → hdmi
- Video pipeline: apple_video RGB → vgc overlay → SuperSprite overlay → scanline dimming → debug overlay → HDMI
- Virtual slot system: SuperSprite(slot 7), Mockingboard(slot 4), SuperSerial(slot 2)

**Expansion ROM tracking** (already in apple_memory.sv lines 133-144):
```systemverilog
always @(posedge a2bus_if.clk_logic or negedge a2bus_if.device_reset_n) begin
    if (!a2bus_if.device_reset_n) begin
        INTC8ROM <= 1'b0;
        SLOTROM <= 3'b0;
    end else if ((a2bus_if.phi1_posedge) && (a2bus_if.addr == 16'hCFFF) && !a2bus_if.m2sel_n) begin
        INTC8ROM <= 1'b0;
        SLOTROM <= 3'b0;
    end else if ((a2bus_if.phi1_posedge) && (a2bus_if.addr >= 16'hC100) && (a2bus_if.addr < 16'hC800) && !a2bus_if.m2sel_n) begin
        if (!a2mem_if.SLOTC3ROM && (a2bus_if.addr[15:8] == 8'hC3)) INTC8ROM <= 1'b1;
        SLOTROM <= a2bus_if.addr[10:8];
    end
end
```
This means A2FPGA **already tracks which slot owns the $C800-$CFFF space** via SLOTROM[2:0]. When SLOTROM == 3'd3, slot 3 owns the expansion ROM space, and writes to $CC00-$CDFF are Videx video RAM writes.

### Other Relevant Modules

**slotmaker.sv** (232 lines): Virtual slot dispatcher, manages address decoding for virtual cards
**video_control_if.sv** (162 lines): Video mode control interface
**sdpram32.sv**: Simple dual-port RAM primitive used for all shadow VRAM
**rom.v**: ROM primitive for character ROM storage

---

## A2DVI Open-Source Firmware Reference

### Repository: `ThorstenBr/A2DVI-Firmware` (GitHub)

The open-source A2DVI firmware implements **passive** Videx monitoring (the active/bidirectional Videx emulation in v4.4 is closed-source, but the passive monitoring code tells us exactly what bus traffic to expect).

### Key A2DVI Videx Files

| File | Purpose |
|------|---------|
| `firmware/videx/videx_vterm.h` | Constants, VRAM buffer, CRTC register array |
| `firmware/videx/videx_vterm.c` | Bus monitoring logic, CRTC write capture, VRAM shadowing |
| `firmware/render/render_videx.c` | Videx text rendering (character ROM lookup, cursor, scanlines) |
| `firmware/fonts/videx/` | 11 Videx character set ROM files |

### A2DVI Videx Implementation Details

**Address Constants:**
```c
#define VIDEX_SLOT          3
#define VIDEX_ROM_ADDR      (0xC000 | (VIDEX_SLOT << 8))    // = $C300
#define VIDEX_REG_ADDR      (0xC080 | (VIDEX_SLOT << 4))    // = $C0B0
```

**Data Structures:**
```c
uint8_t videx_vram[2048];           // 2 KB video RAM shadow
uint8_t videx_crtc_regs[18];       // MC6845 register file (18 registers)
uint8_t videx_crtc_idx;            // Currently selected CRTC register index
uint8_t videx_vterm_mem_selected;   // Whether slot 3 owns $C800-$CFFF
uint_fast16_t videx_bankofs;        // Bank offset within video RAM
```

**CRTC Register Write Handling (`videx_reg_write`):**
- Even address ($C0B0): Sets `videx_crtc_idx` (which register to access)
- Odd address ($C0B1): Writes data to `videx_crtc_regs[videx_crtc_idx]` (limited to registers 0-15)

**Video RAM Write Handling (`videx_c8xx_write`):**
- Only active when `videx_vterm_mem_selected == 1` (slot 3 owns expansion ROM space)
- Addresses $CC00-$CDFF: Write to `videx_vram[addr & 0x7FF]` with bank offset
- Addresses $CE00-$CFFF: Access clears `videx_vterm_mem_selected` (deactivates card memory)
- Bank selection: Address bits select which 512-byte bank within the 2 KB

**Rendering (`render_videx.c`):**
- 80 columns × 24 rows
- Each character: 8 pixels wide × 9 scanlines tall (R9 = $08, meaning max scanline = 8, so 0-8 = 9 lines)
- Characters < 0x80: Normal ROM lookup
- Characters >= 0x80: Inverse ROM lookup (high bit = inverse flag)
- Glyph indexed as: `(ch << 4) + glyph_line` (16 bytes per glyph, only 9 used)
- Cursor: XOR mask from CRTC registers R10/R11 (cursor start/end line), with blink
- 24 rows × 9 lines = 216 active scanlines (vs Apple II's 192)

### Videx MC6845 CRTC Register Initialization

From the Videx VideoTerm ROM 2.4 disassembly:

| Reg | Value | Function |
|-----|-------|----------|
| R0 | $7A | Horizontal Total (122+1=123 char times) |
| R1 | $50 | Horizontal Displayed (80 characters) |
| R2 | $5E | Horizontal Sync Position |
| R3 | $2F | Horizontal/Vertical Sync Width |
| R4 | $22 | Vertical Total (34+1=35 rows) |
| R5 | $00 | Vertical Total Adjust |
| R6 | $18 | Vertical Displayed (24 rows) |
| R7 | $1D | Vertical Sync Position |
| R8 | $00 | Interlace Mode (off) |
| R9 | $08 | Maximum Scan Line (9 scanlines per row: 0-8) |
| R10 | $E0 | Cursor Start (line 0, blink mode) |
| R11 | $08 | Cursor End (line 8) |
| R12 | $00 | Display Start Address (high) |
| R13 | $00 | Display Start Address (low) |
| R14 | $00 | Cursor Address (high) |
| R15 | $00 | Cursor Address (low) |

**Key registers for rendering:**
- **R6** ($18 = 24): Number of visible character rows
- **R9** ($08 = 8): Max scan line address (0-8 = 9 lines per row)
- **R10/R11**: Cursor start/end scanline + blink mode
- **R12/R13**: Display start address (for hardware scrolling)
- **R14/R15**: Cursor position in video RAM

### Videx Character Sets (from A2DVI fonts/videx/)

11 character sets available:
1. videx_normal.c (US ASCII)
2. videx_inverse.c
3. videx_uppercase.c
4. videx_french.c
5. videx_german.c
6. videx_spanish.c
7. videx_katakana.c
8. videx_apl.c (APL programming language symbols)
9. videx_epson.c
10. videx_super_sub.c (superscript/subscript)
11. videx_symbol.c

Each character set is 2 KB (128 characters × 16 bytes/char, only 9 scanlines used).

**For initial implementation:** Start with just normal + inverse (4 KB total = 2 BSRAM blocks). Additional character sets can be added later.

---

## Agent Team Structure

Create the following specialized agents. They should research in parallel and then collaborate to produce the final plan.

### Agent 1: Bus Monitoring Architect

**Responsibilities:**
1. Analyze `apple_memory.sv` to determine exactly how to add Videx bus snooping with minimal changes
2. Design the CRTC register capture logic (writes to $C0B0/$C0B1)
3. Design the Videx VRAM shadow capture logic (writes to $CC00-$CDFF when SLOTROM == 3)
4. Determine how to use the existing SLOTROM[2:0] and INTC8ROM tracking
5. Design the Videx "active mode" detection signal (how does the system know Videx mode is active vs. normal IIe text mode?)
6. Specify the interface between the bus monitoring module and the video renderer

**Key Questions to Answer:**
- Should Videx VRAM be stored in a separate BSRAM block or integrated into the existing text_vram?
- How should the 2 KB Videx VRAM be organized for efficient read access by the renderer?
- What signals need to cross from apple_memory.sv to apple_video.sv?
- How to handle the Videx bank selection (the 4 × 512-byte banks within the 2 KB)?
- Should we add a new `VIDEX_MODE` signal to `a2mem_if`?

### Agent 2: Video Rendering Architect

**Responsibilities:**
1. Analyze `apple_video.sv` to determine how to add a VIDEX_LINE rendering pipeline
2. Design the Videx text rendering pipeline (9 scanlines × 8 pixels per character)
3. Design the character ROM addressing scheme (separate from the IIe video.hex ROM)
4. Handle the display geometry difference: Videx = 80×24 × 8×9 = 640×216 pixels vs Apple II = 560×384
5. Design cursor rendering (XOR mask, blink modes from CRTC R10/R11)
6. Specify how Videx mode detection switches the line_type_w selection
7. Address the scanline mapping: 216 Videx scanlines → 480 HDMI output (with appropriate scaling/centering)

**Key Questions to Answer:**
- How to map 640 Videx pixels into the 720-pixel HDMI frame? (80-pixel borders = centered, same as current)
- How to map 216 Videx scanlines into the 480-pixel HDMI frame? (each line doubled = 432, + 48 border = 480... that's 432+48=480, perfect!)
- Actually: 216 × 2 = 432. (480 - 432) / 2 = 24-pixel borders top and bottom. Different from current 48-pixel borders. How to handle?
- What triggers the switch from normal Apple II rendering to Videx rendering?
- How to handle the linear Videx RAM addressing vs. Apple II scrambled addressing?
- Should the Videx pipeline reuse the existing `viderom_a_r`/`viderom_d_r` ROM lookup, or use a separate ROM instance?
- Can the 9-scanline-per-row rendering fit within the existing 28-pixel-per-cycle timing?
- How does CRTC R12/R13 (display start address) affect the VRAM read offset?

### Agent 3: FPGA Resource & Integration Architect

**Responsibilities:**
1. Analyze the BSRAM budget in detail — enumerate every existing BSRAM block and its purpose
2. Determine if 2-3 additional BSRAM blocks can fit
3. Analyze timing constraints — can the Videx ROM lookup fit within the existing pixel clock pipeline?
4. Evaluate whether the character ROM should use BSRAM (pROM) or distributed RAM (LUT RAM)
5. Review `top.sv` to determine integration points (where in the pipeline does Videx output plug in?)
6. Determine if any existing BSRAM usage can be optimized to free up blocks
7. Assess impact on synthesis timing closure at 27 MHz pixel clock and 54 MHz logic clock

**Key Questions to Answer:**
- Exact BSRAM block count: 28 SDPB + 8 DPB + 2 DPX9B + 3 pROM = 41 used. GW2AR-18C has 46 blocks. Confirm 5 blocks free.
- Can the 2 KB character ROM fit in distributed RAM (145 SSRAM already used) instead of BSRAM to save blocks?
- Is there an option to store Videx character ROM in the SPI flash and load on demand?
- Does adding the Videx pipeline affect the critical path timing?
- What changes are needed in `top.sv` to wire up the Videx signals?

### Agent 4: A2DVI Firmware Analyst

**Responsibilities:**
1. Study the A2DVI open-source firmware's passive Videx implementation in detail
2. Document the exact bus monitoring protocol (what addresses, what timing, what data)
3. Document the rendering algorithm (character ROM format, cursor behavior, blink timing)
4. Identify any edge cases or subtleties in the Videx protocol
5. Determine what Videx-specific soft switches or signals exist beyond the CRTC registers
6. Document the Videx video RAM bank selection mechanism in detail
7. Compare A2DVI's passive approach with what we need for A2FPGA

**Key Files to Analyze (from GitHub repo `ThorstenBr/A2DVI-Firmware`):**
- `firmware/videx/videx_vterm.h` — All constants and data structures
- `firmware/videx/videx_vterm.c` — Bus monitoring logic
- `firmware/render/render_videx.c` — Rendering algorithm
- `firmware/fonts/videx/videx_normal.c` — Character ROM format
- `firmware/fonts/videx/videx_inverse.c` — Inverse character ROM
- `firmware/applebus/buffers.h` — Buffer declarations and Videx-related flags

**Key Questions to Answer:**
- How does A2DVI detect that the user wants Videx mode (vs normal Apple II display)?
- How does A2DVI handle the transition between normal text mode and Videx mode?
- What is the exact format of the Videx character ROM data?
- How does the bank selection mechanism work (4 banks × 512 bytes)?
- What cursor blink modes are supported and how are they timed?
- Are there any writes outside $C0B0-$C0B1 and $CC00-$CDFF that we need to capture?

---

## Collaboration Protocol

After all agents complete their research, they should collaborate to produce:

### Deliverable 1: Architecture Decision Record

Resolve all the "Key Questions" above with concrete decisions:
1. BSRAM allocation plan
2. Module boundary decisions (new module vs. modifications to existing)
3. Signal interface between modules
4. Display geometry and scaling
5. Mode detection mechanism
6. Character ROM storage strategy

### Deliverable 2: Detailed Implementation Plan

For each file that needs to be created or modified, specify:
1. **File path**
2. **Nature of change** (new file / modify existing)
3. **Detailed description** of what to add/change
4. **Estimated BSRAM/logic impact**
5. **Dependencies** (what must be done first)

**Expected file changes:**

| File | Change Type | Description |
|------|-------------|-------------|
| `hdl/memory/a2mem_if.sv` | Modify | Add VIDEX_MODE signal, Videx CRTC register outputs |
| `hdl/memory/apple_memory.sv` | Modify | Add Videx CRTC register capture, Videx VRAM shadow BSRAM |
| `hdl/video/apple_video.sv` | Modify | Add VIDEX_LINE type, Videx rendering pipeline, Videx character ROM |
| `hdl/video/videx_charrom.hex` | New | Videx character ROM (normal + inverse) |
| `boards/a2n20v2/hdl/top.sv` | Modify | Wire Videx signals between modules |
| `hdl/video/video_control_if.sv` | Possibly modify | Add Videx mode control if needed |

### Deliverable 3: Risk Assessment

1. BSRAM overflow risk and mitigation
2. Timing closure risk
3. Regression risk to existing video modes
4. Testing strategy (what software to test with, what to look for)

### Deliverable 4: Phase Plan

- **Phase 1**: Bus monitoring only (capture CRTC registers + VRAM, expose via debug overlay for verification)
- **Phase 2**: Static Videx rendering (render captured VRAM to HDMI, no cursor)
- **Phase 3**: Full Videx rendering (cursor, blink, display start address scrolling)
- **Phase 4**: Multiple character set support (if BSRAM permits)

---

## Important Constraints

1. **Do not modify any existing functionality.** Videx support must be purely additive. All existing Apple II/IIe/IIgs video modes must continue to work unchanged.

2. **BSRAM is the bottleneck.** Every BSRAM block matters. Use distributed RAM (LUT RAM / SSRAM) wherever possible. The character ROM is a candidate for distributed RAM if the data is small enough.

3. **The A2DVI in slot 3 handles all active bus responses.** A2FPGA never needs to drive the bus for Videx support. This is purely passive snooping.

4. **Mode detection must be automatic.** The user should not need to flip a DIP switch to enable Videx mode. The system should detect Videx activity on the bus and switch rendering modes automatically. Consider: if SLOTROM == 3 and writes to $C0B0-$C0B1 are detected, Videx is active.

5. **The Videx display geometry differs from Apple IIe.** Videx: 80 cols × 24 rows × 8×9 pixels = 640×216. Apple IIe: 80 cols × 24 rows × 7×8 pixels = 560×192. The HDMI output is 720×480. Both need to be centered properly.

6. **Focus on the A2N20v2 board variant** (the production board). Other boards can follow later.

7. **Character ROM format**: The A2DVI uses 16 bytes per character (padded to power-of-2), with only 9 bytes used. For FPGA, we can pack to 9 or 16 bytes per character depending on addressing convenience vs BSRAM savings.

---

## Reference Links

- A2DVI Firmware: https://github.com/ThorstenBr/A2DVI-Firmware
- A2DVI Hardware: https://github.com/rallepalaveev/A2DVI
- Videx VideoTerm ROM 2.4 Disassembly: https://btb.github.io/80ColumnCard/firmware/html/Videx%20Videoterm%20ROM%202.4.bin.html
- Videx VideoTerm Manual: https://archive.org/stream/Videx_Videoterm_Installation_and_Operation_Manual
- MC6845 CRTC Reference: http://www.tinyvga.com/6845
- A2FPGA Repository: https://github.com/BrentRector/a2fpga_core
- Existing A2FPGA Analysis: See `80COL_TEXT_VIDEO_REPORT.md` in repository root
