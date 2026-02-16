# 80-Column Text Video Support: A2FPGA vs A2DVI v4.x

**Date:** 2026-02-16
**Repository:** `BrentRector/a2fpga_core` (fork of `edanuff/a2fpga_core`)

---

## Executive Summary

This report evaluates how A2DVI version 4.x implements 80-column text video and what A2FPGA would need to achieve parity. The findings are:

1. **Apple IIe native 80-column text mode is already fully implemented in A2FPGA.** The codebase includes complete soft switch tracking, auxiliary memory banking, interleaved main/aux text VRAM, and a dedicated 5-stage 80-column text rendering pipeline.

2. **A2DVI v4.x adds Videx VideoTerm 80-column emulation for Apple II/II+.** This feature is NOT present in A2FPGA and would require bidirectional bus capabilities (active response to CPU reads), a Videx-compatible character ROM, CRTC register emulation, and slot 3 address decoding. A2FPGA has the hardware infrastructure (PicoSoC, bus write capability via SuperSprite) that could potentially support this, but it would be a significant new feature.

3. **Difficulty assessment:** Apple IIe 80-column is already done (difficulty: 0). Videx emulation would be a moderate-to-hard project, primarily because of the need for active bus response in the FPGA to emulate the Videx ROM and RAM.

---

## Table of Contents

1. [Background: What Is 80-Column Text on Apple II?](#1-background)
2. [How A2DVI v4.x Implements 80-Column Text](#2-a2dvi-implementation)
3. [Current A2FPGA 80-Column Support](#3-a2fpga-current-state)
4. [Gap Analysis: A2FPGA vs A2DVI v4.x](#4-gap-analysis)
5. [Feasibility of Videx Emulation in A2FPGA](#5-videx-feasibility)
6. [Recommendations](#6-recommendations)
7. [Appendix: Technical Details](#7-appendix)

---

## 1. Background: What Is 80-Column Text on Apple II? <a name="1-background"></a>

There are two fundamentally different approaches to 80-column text on the Apple II platform:

### 1a. Apple IIe Native 80-Column Mode

The Apple IIe has built-in 80-column support through its auxiliary memory architecture. An 80-column card plugs into the dedicated auxiliary slot and provides 64 KB of additional RAM. In 80-column text mode:

- **Auxiliary memory** at `$0400-$07FF` holds even-column characters (0, 2, 4, ... 78)
- **Main memory** at `$0400-$07FF` holds odd-column characters (1, 3, 5, ... 79)
- Soft switches control the mode: `COL80` ($C00C/$C00D) enables 80-column display, `80STORE` ($C000/$C001) redirects `PAGE2` to select aux/main bank instead of page 1/page 2

This mode is controlled entirely by the Apple IIe's internal hardware. A bus-snooping card like A2FPGA or A2DVI merely needs to observe memory writes and soft switch changes to render the correct output.

### 1b. Videx VideoTerm 80-Column Mode (Apple II/II+)

The original Apple II and Apple II+ lack native 80-column support. The **Videx VideoTerm** card (installed in slot 3) provides this by adding:

- A **Motorola MC6845 CRTC** (CRT Controller) for timing and cursor
- **2 KB of dedicated video RAM** (not Apple II main/aux memory)
- **Character generator ROM** (2716 EPROM, multiple character sets available)
- An independent video output that replaces the Apple II's composite signal

A Videx card is a fully active bus device: it responds to CPU reads from its ROM space ($C300-$C3FF), exposes memory-mapped registers, and provides its own RAM for the CPU to read and write. A bus-snooping card cannot emulate Videx without **bidirectional bus capabilities** -- it must actively respond to the CPU when the CPU reads from the Videx address space.

---

## 2. How A2DVI v4.x Implements 80-Column Text <a name="2-a2dvi-implementation"></a>

### Version Clarification

The "v4.x" designation refers to the **hardware PCB revision** (v4.1, v4.4), not the firmware version. The firmware releases are numbered v0.7 through v1.7. The critical distinction:

| Hardware Version | Bus Direction | 80-Column Support |
|------------------|--------------|-------------------|
| **v3 (passive)** | Read-only (snoop) | IIe native: yes. Videx: passive only (real Videx card required) |
| **v4.1/v4.4 (bidirectional)** | Read and write | IIe native: yes. Videx: **full emulation** (no real Videx needed) |

### 2a. IIe Native 80-Column (All A2DVI Versions)

A2DVI's approach is identical in concept to A2FPGA's:

1. **PIO state machine** captures every Apple II bus cycle synchronized to PHI0
2. **ARM Core #1** processes bus cycles, tracking soft switch writes at `$C000-$C00F` and `$C050-$C05F`
3. **Shadow memory**: Two 24 KB buffers (`apple_memory[]` and `aux_memory[]`) shadow main and auxiliary video RAM
4. **Bank routing logic**: Determines which shadow buffer a write targets based on 80STORE, PAGE2, and RAMWRT state
5. **ARM Core #2** renders characters from shadow memory, alternating aux/main bytes to produce 80 columns, encoding directly to TMDS bitstream

The rendering function `render_text80_line()` processes character pairs: `char_a` from auxiliary memory (even column) and `char_b` from main memory (odd column), producing 14 pixels per pair (7 per character).

### 2b. Videx 80-Column (A2DVI v4.x Bidirectional Hardware)

The v4.x bidirectional hardware enables **active Videx VideoTerm emulation**:

- Card is installed in **slot 3** (the Videx's traditional slot)
- Provides the Videx **firmware ROM** at `$C300-$C3FF` (CPU reads get valid Videx ROM data)
- Emulates the **MC6845 CRTC** register interface at `$C0B0-$C0BF`
- Provides **2 KB of video RAM** at `$CC00-$CFFF` (memory-mapped, readable by CPU)
- Renders 80 columns using a separate character ROM (10 character sets available, configurable)
- Uses 9 vertical glyph lines per text row (vs 8 for standard Apple IIe) for 24 rows x 9 = 216 scanlines
- Supports CRTC cursor register emulation with 4 cursor modes

The v4.4 firmware for bidirectional features is **closed source**.

### 2c. Passive Videx Support (All A2DVI Versions)

Even without bidirectional capability, A2DVI can passively support a Videx card:

- A **real Videx VideoTerm card** must be physically installed in slot 3
- A2DVI monitors the Videx card's memory and register writes on the bus
- A2DVI captures the Videx video RAM contents and renders them to HDMI
- The Videx card handles all active bus responses (ROM, RAM reads, CRTC)

---

## 3. Current A2FPGA 80-Column Support <a name="3-a2fpga-current-state"></a>

### 3a. Apple IIe Native 80-Column: FULLY IMPLEMENTED

A2FPGA has complete, production-ready 80-column text support for the Apple IIe. The implementation spans three key modules:

#### Soft Switch Tracking (`hdl/memory/apple_memory.sv`)

All required IIe soft switches are captured:

| Switch | Address | Captured | Purpose |
|--------|---------|----------|---------|
| **80STORE** | $C000/$C001 | Yes (SWITCHES_IIE[0]) | Controls aux/main bank via PAGE2 |
| **RAMRD** | $C002/$C003 | Yes (SWITCHES_IIE[1]) | Auxiliary memory read select |
| **RAMWRT** | $C004/$C005 | Yes (SWITCHES_IIE[2]) | Auxiliary memory write select |
| **ALTZP** | $C008/$C009 | Yes (SWITCHES_IIE[4]) | Auxiliary zero page |
| **COL80** | $C00C/$C00D | Yes (SWITCHES_IIE[6]) | 80-column mode enable |
| **ALTCHAR** | $C00E/$C00F | Yes (SWITCHES_IIE[7]) | Alternate character set (MouseText) |
| **PAGE2** | $C054/$C055 | Yes (SWITCHES_II[2]) | Page/bank select |

IIe switches are captured on writes to `$C00x` range; video switches on any access to `$C05x` range. The IIgs STATEREG at `$C068` is also handled for multi-switch updates.

#### Auxiliary Memory Banking (`hdl/memory/apple_memory.sv:169-182`)

The `aux_mem_r` signal correctly implements the Apple IIe MMU's bank selection logic:

```systemverilog
// For text page ($0400-$07FF):
aux_mem_r = (STORE80 & PAGE2) | (~STORE80 & RAMWRT & ~rw_n);

// For hi-res page ($2000-$3FFF):
aux_mem_r = (STORE80 & PAGE2 & HIRES_MODE) | ((~STORE80 | ~HIRES_MODE) & RAMWRT & ~rw_n);
```

The `E1` signal (`aux_mem_r || m2b0`) is used as the LSB of the text VRAM write address, interleaving main and auxiliary bytes in a single block RAM. This allows 32-bit reads to return 4 characters (2 aux + 2 main) in a single cycle.

#### 80-Column Text Rendering Pipeline (`hdl/video/apple_video.sv:346-486`)

The video scanner detects 80-column mode when `!GR & col80_r` and selects `TEXT80_LINE` processing. The pipeline uses 6 stages to process 4 characters per 28-pixel cycle:

| Stage | Action | Data Source |
|-------|--------|-------------|
| STAGE_TEXT_0 | ROM lookup: character from video_data[7:0] | 32-bit word byte 0 (main, even addr) |
| STAGE_TEXT80_1 | ROM lookup: character from video_data[15:8] | Byte 1 (aux, even addr) |
| STAGE_TEXT80_2 | Store pixels [13:7], ROM lookup video_data[23:16] | Byte 2 (main, odd addr) |
| STAGE_TEXT80_3 | Store pixels [6:0], ROM lookup video_data[31:24] | Byte 3 (aux, odd addr) |
| STAGE_TEXT80_4 | Store pixels [27:21] | |
| STAGE_TEXT80_5 | Store pixels [20:14] | |

Each character is rendered as 7 pixels (1:1 from ROM, no pixel doubling), producing 80 chars x 7 pixels = 560 active pixels per line.

#### Character ROM (`hdl/video/video.hex`)

A 4 KB character ROM containing the complete Enhanced Apple IIe character set, including:
- Standard uppercase and lowercase characters
- Inverse characters
- Flashing characters (via `flash_clk_w` at ~1.9 Hz)
- MouseText glyphs (selected via ALTCHAR switch)

#### Display Mapping

The 560-pixel Apple II display is centered in the 720x480p HDMI frame:
- Horizontal: 80-pixel borders on each side
- Vertical: 48-pixel borders on each side (192 Apple II lines x 2 = 384 pixels)
- 40-column: 40 chars x 14 pixels = 560 pixels (each ROM pixel doubled)
- 80-column: 80 chars x 7 pixels = 560 pixels (1:1 mapping)

### 3b. Videx VideoTerm Support: NOT IMPLEMENTED

A2FPGA has **no Videx VideoTerm support** -- neither passive nor active. There are no references to "Videx" or "VideoTerm" anywhere in the codebase.

### 3c. Double-Width Graphics Modes: FULLY IMPLEMENTED

Related double-width modes using auxiliary memory are also fully implemented:
- **Double Lo-Res** (LORES80_LINE): 80x48 resolution, 16 colors
- **Double Hi-Res** (HIRES80_LINE): 560x192 resolution

---

## 4. Gap Analysis: A2FPGA vs A2DVI v4.x <a name="4-gap-analysis"></a>

| Feature | A2DVI v3 (Passive) | A2DVI v4.x (Bidirectional) | A2FPGA (Current) | Gap |
|---------|--------------------|-----------------------------|-------------------|-----|
| IIe 80-col text | Yes | Yes | **Yes** | None |
| IIe MouseText | Yes | Yes | **Yes** | None |
| IIe ALTCHAR | Yes | Yes | **Yes** | None |
| IIe Double Lo-Res | Yes | Yes | **Yes** | None |
| IIe Double Hi-Res | Yes | Yes | **Yes** | None |
| Videx passive (real card) | Yes | Yes | **No** | Gap |
| Videx active emulation | No | Yes | **No** | Gap |
| Videx character sets (10) | Passive only | Yes | **No** | Gap |
| Videx CRTC cursor modes | Passive only | Yes | **No** | Gap |

**Key finding:** For Apple IIe users, A2FPGA already has full parity with A2DVI on 80-column text support. The gap is exclusively in Videx VideoTerm support, which matters only for Apple II and Apple II+ users who want 80-column text without a physical Videx card.

---

## 5. Feasibility of Videx Emulation in A2FPGA <a name="5-videx-feasibility"></a>

### 5a. What Would Be Required

To match A2DVI v4.x's active Videx emulation, A2FPGA would need:

1. **Slot 3 ROM Emulation**: Respond to CPU reads from `$C300-$C3FF` with Videx firmware ROM data. This requires the FPGA to drive the data bus during the correct bus phase when the CPU reads these addresses.

2. **CRTC Register Emulation**: Implement a subset of the MC6845 register interface at `$C0B0-$C0BF`:
   - Register address port (write-only)
   - Register data port (read/write)
   - Key registers: cursor position, display start address, cursor start/end lines

3. **2 KB Video RAM**: Provide memory-mapped RAM at `$CC00-$CFFF` that the CPU can both read and write.

4. **Character ROM**: A separate character ROM for Videx rendering (different from the Apple IIe character ROM). Multiple character sets (10 in A2DVI) would require approximately 20 KB of ROM storage.

5. **Videx Text Rendering Pipeline**: A separate rendering pipeline for Videx text, differing from the IIe pipeline in:
   - 9 vertical glyph lines per character row (vs 8 for IIe)
   - Different character ROM addressing
   - CRTC-controlled cursor rendering with 4 cursor modes
   - Different memory addressing (linear 2 KB buffer, not Apple II scrambled addressing)

### 5b. A2FPGA Hardware Capabilities

The A2FPGA platform has infrastructure that could support Videx emulation:

| Requirement | A2FPGA Capability | Assessment |
|-------------|-------------------|------------|
| Bidirectional bus | SuperSprite module already drives the bus for TMS9918A VDP emulation | **Possible** -- infrastructure exists |
| FPGA block RAM | Gowin GW2AR-18C has 46 KB of BSRAM available | **Sufficient** for 2 KB Videx RAM + ROM |
| Slot detection | Bus address decoding already handles `$C0xx` range | **Existing** infrastructure |
| ROM storage | PicoSoC has access to SPI flash for data storage | **Available** |
| Rendering pipeline | apple_video.sv architecture supports multiple line types | **Extensible** |
| Character ROM | video.hex loaded into BRAM | **Can add** Videx ROM alongside |

### 5c. Difficulty Assessment

| Component | Difficulty | Rationale |
|-----------|-----------|-----------|
| Slot 3 ROM response | **Moderate** | Requires careful bus timing for read responses; SuperSprite provides a reference implementation |
| CRTC register emulation | **Easy** | Simple register file with write/read logic; only a subset of MC6845 registers needed |
| 2 KB video RAM | **Easy** | Standard dual-port BRAM instantiation |
| Videx rendering pipeline | **Moderate** | New pipeline similar to TEXT80 but with different character ROM addressing, 9-line glyphs, and CRTC-based cursor |
| Bus timing correctness | **Hard** | Must respond to reads within the Apple II's bus cycle timing; incorrect timing causes bus contention |
| Multiple character sets | **Easy** | Additional ROM data loaded from SPI flash |
| Integration and testing | **Moderate** | Requires testing with actual Apple II/II+ software that uses Videx |

**Overall difficulty: Moderate.** The hardest part is reliable bidirectional bus communication with correct timing for slot 3 ROM reads. The SuperSprite module's existing bus driving code provides a foundation, but Videx emulation requires responding in a different address space with different timing constraints.

### 5d. Estimated Scope

- New HDL modules: ~500-800 lines (Videx controller + rendering)
- Modified modules: apple_video.sv (add VIDEX_LINE type), apple_memory.sv (add Videx RAM), top.sv (instantiation)
- New data files: Videx character ROM(s) (~20 KB)
- Testing: Requires Apple II or II+ with Videx-compatible software (ProTERM, WordStar, etc.)

---

## 6. Recommendations <a name="6-recommendations"></a>

### For Apple IIe 80-Column Text: No Action Needed

A2FPGA already has complete, functional 80-column text support. The implementation includes:
- All required soft switches (COL80, 80STORE, RAMWRT, ALTCHAR, PAGE2)
- Correct auxiliary memory banking logic
- Efficient 5-stage rendering pipeline producing 560 pixels/line
- MouseText and alternate character set support
- Mixed mode (80-column text in bottom 4 lines with graphics above)

**If 80-column text is not working in practice**, the issue is likely in:
- The bus snooping timing (missing some writes)
- The soft switch capture logic (especially STATEREG at `$C068`)
- The memory interleaving order (aux vs main byte ordering in the 32-bit word)
- Testing methodology (ensure an 80-column card is installed in the Apple IIe's auxiliary slot)

### For Videx 80-Column Emulation: Possible But Non-Trivial

If Videx emulation is desired:

1. **Phase 1 -- Passive Videx support** (easier): Monitor bus writes to Videx address space when a real Videx card is installed. Shadow the Videx's 2 KB RAM and render it. This is purely additive to the existing bus snooping infrastructure.

2. **Phase 2 -- Active Videx emulation** (harder): Implement full Videx card emulation with ROM, RAM, and CRTC registers. Requires bidirectional bus driving in slot 3.

### For Feature Parity with A2DVI v4.x

If the goal is complete feature parity with A2DVI v4.x bidirectional hardware, note that the v4.4 firmware is **closed source**. The open-source A2DVI firmware (v1.7) supports passive Videx monitoring but not active emulation. Active Videx emulation would need to be reverse-engineered from Videx VideoTerm documentation rather than from A2DVI source code.

---

## 7. Appendix: Technical Details <a name="7-appendix"></a>

### A. Key Source Files

| File | Lines | Purpose |
|------|-------|---------|
| `hdl/video/apple_video.sv` | 644 | Main video controller with TEXT80 pipeline |
| `hdl/video/video.hex` | 4096 bytes | Apple IIe character ROM (includes MouseText) |
| `hdl/video/video_control_if.sv` | 162 | Video soft switch interface (COL80, STORE80 exposed) |
| `hdl/memory/apple_memory.sv` | 388 | Bus snooping, soft switch capture, interleaved VRAM |
| `hdl/memory/a2mem_if.sv` | 142 | Memory interface definition with all soft switches |
| `hdl/bus/a2bus_if.sv` | 121 | Apple II bus signal interface |

### B. 80-Column Memory Interleaving

The A2FPGA stores text VRAM with `E1` (auxiliary bank indicator) as the LSB of the write offset:

```
Write address = {!addr[10], addr[9:0], E1}
```

This means a 32-bit read at a given display address returns:

```
Bits [7:0]   = Main memory, address N     (odd column)
Bits [15:8]  = Aux memory, address N      (even column)
Bits [23:16] = Main memory, address N+1   (odd column)
Bits [31:24] = Aux memory, address N+1    (even column)
```

The rendering pipeline reads these in order: [7:0], [15:8], [23:16], [31:24], producing the correct even-odd-even-odd column sequence on screen.

### C. Apple II Text Screen Address Map

The Apple II uses scrambled (non-linear) row addressing inherited from the original Woz design:

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

Each row occupies 40 bytes. In 80-column mode, each byte position yields 2 characters (aux = even column, main = odd column), so 40 addresses produce 80 columns.

### D. A2DVI Architecture Comparison

```
A2DVI (RP2040):                         A2FPGA (Gowin GW2AR-18C):

PIO state machine                       apple_bus.sv
  -> captures bus cycles                   -> captures bus cycles
  -> 32-bit FIFO                           -> generates data_in_strobe

ARM Core #1                             apple_memory.sv
  -> soft switch tracking                  -> soft switch tracking
  -> shadow memory writes                  -> shadow BRAM writes
  -> aux bank routing                      -> aux bank routing (E1 signal)

ARM Core #2                             apple_video.sv
  -> character ROM lookup                  -> character ROM lookup
  -> 80-col interleave render              -> TEXT80 pipeline (6 stages)
  -> TMDS direct encoding                  -> pixel buffer -> shift register

PIO DVI output                          hdmi.sv + serializer.sv
  -> 3-channel TMDS at 270 Mbps            -> TMDS encoding + OSER10
```

### E. References

- [ThorstenBr/A2DVI-Firmware](https://github.com/ThorstenBr/A2DVI-Firmware) - A2DVI open-source firmware
- [rallepalaveev/A2DVI](https://github.com/rallepalaveev/A2DVI) - A2DVI hardware PCB
- [markadev/AppleII-VGA](https://github.com/markadev/AppleII-VGA) - Upstream VGA project
- "Understanding the Apple IIe" by Jim Sather - Definitive Apple IIe hardware reference
- Apple IIe Technical Reference Manual - Official Apple documentation
- [Videx VideoTerm Manual](http://www.apple-history.com) - Original Videx documentation

---

*Report generated by multi-agent research team analyzing A2FPGA codebase, A2DVI firmware/hardware, and Apple II technical documentation.*
