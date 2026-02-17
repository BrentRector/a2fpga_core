# Videx VideoTerm Passive Monitoring: Comprehensive Implementation Plan

## Context

The A2FPGA Apple II FPGA coprocessor needs passive Videx VideoTerm 80-column text monitoring. An A2DVI v4.4 card in slot 3 actively emulates a Videx VideoTerm (providing ROM, CRTC registers, and 2 KB VRAM). A2FPGA in another slot passively snoops bus writes to shadow the Videx state and render the 80-column text on its HDMI output.

This plan was produced by 4 parallel research agents analyzing the A2FPGA codebase and A2DVI firmware source code.

---

## Part 1: A2DVI Firmware Protocol (Agent 4 Findings)

### 1.1 Bus Monitoring Protocol

The A2DVI firmware (RP2040-based) passively monitors the Apple II address bus. Three address ranges trigger Videx-specific actions:

| Address Range | Trigger | Action |
|---|---|---|
| `$C0B0-$C0BF` | Slot 3 device register I/O (DEVSEL) | CRTC register read/write + bank selection |
| `$C300-$C3FF` | Slot 3 ROM space access | Sets `videx_vterm_mem_selected = true` |
| `$C800-$CFFF` | Shared expansion ROM space | VRAM read/write (only when `videx_vterm_mem_selected`) |

All Videx bus handling is gated by a global `videx_enabled` boolean. From `bus_func_cxxx_read()`:

```c
if (videx_enabled) {
    if ((address & 0xFFF0) == 0xC0B0)       // slot #3 register area
        videx_reg_read(address);
    else if ((address & 0xFF00) == 0xC300)   // slot #3 ROM
        videx_vterm_mem_selected = true;
    else if ((address & 0xF800) == 0xC800)   // expansion ROM area
        if (videx_vterm_mem_selected)
            videx_c8xx_read(address);
}
```

### 1.2 CRTC Register Protocol

The MC6845 CRTC has two I/O ports differentiated by **address bit 0**:

- **Even addresses** (`$C0B0`, `$C0B2`, `$C0B4`, ..., `$C0BE`) — **Register select**: the written data byte is latched as the register index (`videx_crtc_idx = data`)
- **Odd addresses** (`$C0B1`, `$C0B3`, `$C0B5`, ..., `$C0BF`) — **Register data**: the data byte is written to the currently selected register (index < 16 only; registers 16-17 are read-only light pen)

```c
if (address & 0x0001) {
    if (videx_crtc_idx < 16)
        videx_crtc_regs[videx_crtc_idx] = data;  // odd = data write
} else {
    videx_crtc_idx = data;                         // even = index select
}
```

**Important**: Both reads AND writes to `$C0B0-$C0BF` also trigger VRAM bank selection (see below), regardless of even/odd.

### 1.3 CRTC Register Default Values

```
R0  = 0x7B  Horiz Total (123 char times)
R1  = 0x50  Horiz Displayed (80 chars)
R2  = 0x62  Horiz Sync Position
R3  = 0x29  Horiz Sync Width
R4  = 0x1B  Vert Total (27 char rows)
R5  = 0x08  Vert Total Adjust
R6  = 0x18  Vert Displayed (24 char rows)
R7  = 0x19  Vert Sync Position
R8  = 0x00  Interlace Mode
R9  = 0x08  Max Scan Line Address (8 = 9 lines per char, 0-8)
R10 = 0xC0  Cursor Start (line 0, blink mode 3)
R11 = 0x08  Cursor End (line 8)
R12 = 0x00  Start Address High
R13 = 0x00  Start Address Low
R14 = 0x00  Cursor Position High
R15 = 0x00  Cursor Position Low
R16 = 0x00  Light Pen High (read-only)
R17 = 0x00  Light Pen Low (read-only)
```

### 1.4 VRAM Bank Selection (CRITICAL)

The Videx VideoTerm has 2048 bytes (2 KB) of video RAM divided into **4 banks of 512 bytes each**:

| Bank | Offset | VRAM Range |
|------|--------|------------|
| 0    | 0x000  | 0x000-0x1FF |
| 1    | 0x200  | 0x200-0x3FF |
| 2    | 0x400  | 0x400-0x5FF |
| 3    | 0x600  | 0x600-0x7FF |

The bank is selected by **bits [3:2]** of the device register address (`$C0Bx`). **Every** access (read or write) to `$C0B0-$C0BF` updates the bank:

```c
#define VIDEX_SET_BANK(address) videx_bankofs = (address & 0x000c) << 7;
```

| Address bits [3:2] | `address & 0xC` | `<< 7` = bankofs | Bank |
|---|---|---|---|
| 00 | 0x0 | 0x000 | 0 |
| 01 | 0x4 | 0x200 | 1 |
| 10 | 0x8 | 0x400 | 2 |
| 11 | 0xC | 0x600 | 3 |

So `$C0B0/$C0B1` → bank 0, `$C0B4/$C0B5` → bank 1, `$C0B8/$C0B9` → bank 2, `$C0BC/$C0BD` → bank 3.

**VRAM write formula:** When the CPU writes to the `$CC00-$CDFF` window:
```c
uint16_t vaddr = videx_bankofs + (address & 0x01ff);
videx_vram[vaddr] = data;
```

The CPU sees only a **512-byte window** at `$CC00-$CDFF` that maps to one of four 512-byte banks in the 2 KB VRAM, selected by the most recent access to the `$C0Bx` range.

### 1.5 Memory Map Within $C800-$CFFF

When `videx_vterm_mem_selected` is true:

| Address Range | Write Behavior | Read Behavior |
|---|---|---|
| `$C800-$CBFF` | Ignored (ROM area) | ROM reads |
| `$CC00-$CDFF` | Written to VRAM at `bankofs + (addr & 0x1FF)` | No VRAM read interception |
| `$CE00-$CFFF` | Deselects Videx memory | Deselects Videx memory |

### 1.6 Mode Detection in A2DVI

A2DVI uses a `SOFTSW_VIDEX_80COL` soft switch toggled by bus accesses:
- `$C058`: `soft_switches &= ~SOFTSW_VIDEX_80COL` (Videx 80-col OFF)
- `$C059`: `soft_switches |= SOFTSW_VIDEX_80COL` (Videx 80-col ON, if videx_enabled)

Display switches to Videx when both conditions are true:
```c
bool IsVidex = ((current_softsw & (SOFTSW_TEXT_MODE | SOFTSW_VIDEX_80COL))
                == (SOFTSW_TEXT_MODE | SOFTSW_VIDEX_80COL));
```

### 1.7 Videx Memory Selection State Machine

1. **Activation**: Any access to `$C300-$C3FF` → `videx_vterm_mem_selected = true`
2. **Deactivation**: Any access to `$CE00-$CFFF` → `videx_vterm_mem_selected = false`
3. **Reset**: The 6502 reset handler clears `videx_vterm_mem_selected`
4. **Gating**: All `$C800-$CFFF` handling only occurs when `videx_vterm_mem_selected == true`

### 1.8 Character ROM Format

Two separate ROMs, each `128 * 16` bytes = 2048 bytes:
```c
const uint8_t videx_normal[128 * 16];   // characters 0x00-0x7F
const uint8_t videx_inverse[128 * 16];  // characters 0x80-0xFF (pre-inverted)
```

**Indexing formula:** `ROM_offset = (character_code << 4) + glyph_line`

Each character occupies 16 bytes (9 used for scanlines 0-8, 7 padding bytes of 0x00). Each byte = 8 pixels: bit 7 = leftmost, bit 0 = rightmost. `1` = foreground, `0` = background.

Characters 0x00-0x7F → normal ROM. Characters 0x80-0xFF → mask off bit 7, use inverse ROM. Inverse ROM is bitwise NOT of normal (pre-computed, not runtime).

### 1.9 Rendering Algorithm (A2DVI)

`render_videx_text()` computes:
```c
const uint16_t text_base_addr = ((videx_crtc_regs[12] & 0x3f) << 8) | videx_crtc_regs[13];
const uint16_t cursor_addr    = ((videx_crtc_regs[14] & 0x3f) << 8) | videx_crtc_regs[15];
```

Each row offset: `text_base_addr + (line * 80)`, wrapped with `& 0x7FF` (2 KB circular buffer).

Characters fetched in groups of 4 (as 32-bit words). Each character's glyph row fetched and packed. Output is 640 pixels per line (80 chars × 8 pixels), each scanline doubled for VGA (432 visible lines = 24 rows × 9 scanlines × 2).

### 1.10 Cursor Behavior

- **R10 (Cursor Start)**: Bits [4:0] = start scanline, Bits [6:5] = blink mode
- **R11 (Cursor End)**: Bits [4:0] = end scanline

| Mode | Bits [6:5] | Behavior |
|------|-----------|----------|
| 0    | 00        | Non-blinking (always visible) |
| 1    | 01        | No cursor (hidden) |
| 2    | 10        | Blink at 1/16th field rate (~1.6 Hz) |
| 3    | 11        | Blink at 1/32nd field rate (~3.2 Hz) |

Cursor applied via XOR: `bits ^= videx_cursor_mask` (mask toggles between 0xFF and 0x00 for blink modes).

---

## Part 2: A2FPGA Bus Monitoring Architecture (Agent 1 Findings)

### 2.1 Existing Bus Infrastructure

**File:** `hdl/memory/apple_memory.sv`

Key timing signals for passive capture:
```systemverilog
wire write_strobe = !a2bus_if.rw_n && a2bus_if.data_in_strobe;  // line 40
wire read_strobe = a2bus_if.rw_n && a2bus_if.data_in_strobe;    // line 41
```

Proven soft-switch capture pattern (line 76):
```systemverilog
if ((a2bus_if.phi1_posedge) && (a2bus_if.addr[15:4] == 12'hC05) && !a2bus_if.m2sel_n) begin
    SWITCHES_II[a2bus_if.addr[3:1]] <= a2bus_if.addr[0];
end
```

Data-based capture pattern (line 88):
```systemverilog
if (!a2bus_if.rw_n && (a2bus_if.phi1_posedge) && (a2bus_if.addr == 16'hC068) && !a2bus_if.m2sel_n) begin
    SWITCHES_IIE[1] <= a2bus_if.data[5];
end
```

### 2.2 SLOTROM Tracking (Already In Place)

From lines 133-144, the existing SLOTROM tracking already detects which slot owns expansion ROM:

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

**No changes needed** — `SLOTROM == 3'd3` means slot 3 owns `$C800-$CFFF`.

### 2.3 CRTC Register Capture Design

**Insert after line 167** (after keypress_strobe assignment):

```systemverilog
reg [4:0] videx_crtc_idx;
reg [7:0] videx_crtc_regs[18];
reg [10:0] videx_bankofs;  // VRAM bank offset (0x000, 0x200, 0x400, 0x600)

always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
    if (!a2bus_if.system_reset_n) begin
        videx_crtc_idx <= 5'h0;
        videx_bankofs <= 11'h0;
        for (int i = 0; i < 18; i++)
            videx_crtc_regs[i] <= 8'h00;
    end else if ((a2bus_if.phi1_posedge) && !a2bus_if.m2sel_n &&
                 (a2bus_if.addr[15:4] == 12'hC0B)) begin
        // Bank selection on ANY $C0Bx access (read or write)
        videx_bankofs <= {a2bus_if.addr[3:2], 9'b0};  // bits [3:2] × 512

        // CRTC register capture on writes only
        if (!a2bus_if.rw_n && a2bus_if.data_in_strobe) begin
            if (!a2bus_if.addr[0])  // even address = index select
                videx_crtc_idx <= a2bus_if.data[4:0];
            else if (videx_crtc_idx < 5'd16)  // odd address = data write
                videx_crtc_regs[videx_crtc_idx] <= a2bus_if.data[7:0];
        end
    end
end
```

### 2.4 Mode Detection Design

**Insert after line 182** (after aux_mem_r logic):

```systemverilog
reg videx_crtc_write_detected;
always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
    if (!a2bus_if.system_reset_n)
        videx_crtc_write_detected <= 1'b0;
    else if (write_strobe && (a2bus_if.addr[15:4] == 12'hC0B) && !a2bus_if.m2sel_n)
        videx_crtc_write_detected <= 1'b1;
end

assign a2mem_if.VIDEX_MODE = videx_crtc_write_detected;
```

### 2.5 VRAM Write Capture Design

**Insert before BSRAM section (~line 245)**:

```systemverilog
wire videx_vram_write_enable = write_strobe &&
                               (SLOTROM == 3'd3) &&
                               (a2bus_if.addr[15:9] == 7'b1100_110);  // $CC00-$CDFF

// Full VRAM address = bank offset + (bus_addr & 0x1FF)
wire [10:0] videx_vram_waddr = videx_bankofs + {2'b0, a2bus_if.addr[8:0]};
```

### 2.6 VRAM BSRAM Instance

**Insert after line 385** (after hires_aux BSRAM):

```systemverilog
sdpram32 #(.ADDR_WIDTH(9)) videx_vram (  // 2^9 × 32-bit = 2048 bytes
    .clk(a2bus_if.clk_logic),
    .write_addr(videx_vram_waddr[10:2]),
    .write_data(write_word),
    .write_enable(videx_vram_write_enable),
    .byte_enable(4'(1 << videx_vram_waddr[1:0])),
    .read_addr(videx_video_read_addr),
    .read_enable(videx_video_rd),
    .read_data(videx_vram_data)
);
```

### 2.7 Signals to Add to a2mem_if.sv

**Insert after line 48** (after SLOTROM):

```systemverilog
// Videx VideoTerm signals
logic VIDEX_MODE;
logic [7:0] VIDEX_CRTC_R10;    // Cursor start + blink mode
logic [7:0] VIDEX_CRTC_R11;    // Cursor end scanline
logic [7:0] VIDEX_CRTC_R12;    // Display start addr high
logic [7:0] VIDEX_CRTC_R13;    // Display start addr low
logic [7:0] VIDEX_CRTC_R14;    // Cursor addr high
logic [7:0] VIDEX_CRTC_R15;    // Cursor addr low
logic [3:0] VIDEX_MAX_SCANLINE; // R9[3:0] (typically 8 → 9 lines)
```

Add to master modport as `output`, slave modport as `input`.

---

## Part 3: Video Rendering Architecture (Agent 2 Findings)

### 3.1 Existing Pipeline: 28-Step State Machine

**File:** `hdl/video/apple_video.sv`

```
STEP_LENGTH = 28              // Pixels processed per state machine cycle
PIX_BUFFER_SIZE = 29          // Buffer width (28 pixels + 1 delay bit)
STEP_FIRST = 0, STEP_LAST = 27
STEP_LOAD_MEM = 0             // Issue memory read for next block
STEP_LATCH_MEM = 14           // Latch returned memory data
```

**Pipeline timing per 28-step cycle:**
- Step 0: Memory read issued (video_address_o, video_rd_o asserted)
- Step 14: Memory data captured into `video_data_r[31:0]`
- Steps 15-27: Character ROM lookups proceed
- Step 27 (LOAD_SHIFT): Pixels shifted into `pix_shift_r`, h_offset incremented

### 3.2 Line Type Selection (lines 346-352)

```systemverilog
wire [2:0] line_type_w = (!GR & !col80_r) ? TEXT40_LINE :
    (!GR & col80_r) ? TEXT80_LINE :
    (GR & !hires_mode_r & an3_r) ? LORES40_LINE :
    (GR & col80_r & !hires_mode_r & !an3_r) ? LORES80_LINE :
    (GR & !col80_r & hires_mode_r & an3_r) ? HIRES40_LINE :
    (GR & col80_r & hires_mode_r & !an3_r) ? HIRES80_LINE :
    TEXT40_LINE;

wire GR = ~(text_mode_r | (window_y_w[5] & window_y_w[7] & mixed_mode_r));
```

Soft switches are latched during blanking (lines 106-125) to prevent tearing.

### 3.3 Character ROM Addressing

**Existing Apple II ROM:**
```systemverilog
reg [7:0] viderom_r[4095:0];           // 4 KB array
initial $readmemh("video.hex", viderom_r, 0);
reg [11:0] viderom_a_r;
reg [7:0] viderom_d_r;
always @(posedge a2bus_if.clk_pixel) viderom_d_r <= ~viderom_r[viderom_a_r];
```

Apple II ROM is 12-bit addressed: `{mode_bit, inverse_bit, alt_charset_bit, char[5:0], scanline[2:0]}`

**Videx ROM will be separate:** 12-bit addressed: `{char[7:0], scanline[3:0]}` — 4096 entries covering 256 characters × 16 bytes/char (both normal 0x00-0x7F and inverse 0x80-0xFF combined).

### 3.4 Display Geometry

**Current Apple II:**
```
WINDOW_WIDTH = 560 (80 chars × 7 pixels)
WINDOW_HEIGHT = 384 (192 lines × 2 vertical doubling)
SCREEN_WIDTH = 720, SCREEN_HEIGHT = 480
H_BORDER = 80, V_BORDER = 48
```

**Videx options:**
- 8 pixels/char → 80 × 8 = 640px → H_BORDER = 40
- 7 pixels/char → 80 × 7 = 560px → H_BORDER = 80 (same as Apple II, fits 28-step pipeline)

Vertical: 9 scanlines × 24 rows = 216 lines, doubled = 432px → V_BORDER = 24.

### 3.5 TEXT80 Pipeline (Reference for VIDEX)

TEXT80 uses 6 stages to process 4 characters per 28-step cycle:
```systemverilog
STAGE_TEXT80_1 = {STEP_LATCH_MEM + 2, TEXT80_LINE};
STAGE_TEXT80_2 = {STEP_LATCH_MEM + 3, TEXT80_LINE};
...
STAGE_TEXT80_5 = {STEP_LATCH_MEM + 6, TEXT80_LINE};
```

Each stage issues a character ROM lookup and stores the previous result. The `expandText40()` function doubles each of 7 bits to 14 pixels.

### 3.6 Pixel Output

```systemverilog
reg [PIX_BUFFER_SIZE-1:0] pix_buffer_r;
reg [PIX_BUFFER_SIZE-1:0] pix_shift_r;
wire pix_out_w = pix_shift_r[0];  // Current pixel output
```

Color generation uses `pix_history_r` (8-pixel deep) for text and artifact color:
```systemverilog
if (!GR) begin
    pix_color_r <= pix_history_r[4] ? text_color_r : background_color_r;
end
```

---

## Part 4: FPGA Resource Analysis (Agent 3 Findings)

### 4.1 BSRAM Budget

**GW2AR-18C (Tang Nano 20K): 46 total BSRAM blocks**

Current allocation from PnR report:
```
BSRAM: 41/46 blocks (90% utilization)
  - SDPB: 28 blocks
  - DPB:   8 blocks
  - DPX9B: 2 blocks
  - pROM:  3 blocks
```

**Remaining: 5 blocks (~20 KB)**

Major consumers:
| Component | Blocks | Purpose |
|-----------|--------|---------|
| text_vram | 1 | Apple II text shadow |
| hires_main_2000_5FFF | 1 | Main hires RAM |
| hires_aux_2000_5FFF | 1 | Aux hires RAM |
| hires_aux_6000_9FFF | 1 | VGC memory |
| F18A VDP (SuperSprite) | 12-15 | Sprite/pattern/VRAM |
| Picosoc firmware | 3-4 | RV32 code |
| Video character ROM | 3 | Apple II text glyphs (pROM) |
| Mockingboard audio | 2-5 | Audio buffers |

### 4.2 Clock Domains

```
clk (27 MHz)          → External clock input
clk_logic_w (54 MHz)  → Logic domain (Apple II CPU + memory)
clk_pixel_w (27 MHz)  → Pixel clock (video rendering)
clk_hdmi_w (135 MHz)  → HDMI TMDS serialization
```

### 4.3 Character ROM Storage Strategy

**Strongly recommended: LUT RAM (0 BSRAM blocks)**

```systemverilog
reg [7:0] videxrom_r[4095:0];  // 4 KB
initial $readmemh("videx_charrom.hex", videxrom_r, 0);
reg [11:0] videxrom_a_r;
reg [7:0] videxrom_d_r;
always @(posedge a2bus_if.clk_pixel) videxrom_d_r <= videxrom_r[videxrom_a_r];
```

Gowin infers SSRAM (LUT RAM) automatically. Uses ~150 SSRAM units from logic budget (abundant at 27% logic utilization) instead of BSRAM blocks.

### 4.4 Integration Points in top.sv

**File:** `boards/a2n20v2/hdl/top.sv` (683 lines)

Video pipeline chain (lines 267-412):
```
apple_video (lines 293-311)
    ↓ (RGB output)
vgc (lines 317-342)
    ↓ (Super Hires RGB)
SuperSprite/F18A (lines 378-412)
    ↓ (VDP overlay)
HDMI (lines 613-644)
```

Memory connectivity (lines 218-246):
```systemverilog
apple_memory #(.VGC_MEMORY(1)) apple_memory (
    .a2bus_if(a2bus_if),
    .a2mem_if(a2mem_if),
    .video_address_i(video_address_w),
    .video_rd_i(video_rd_w),
    .video_data_o(video_data_w),
    .vgc_active_i(vgc_active_w),
    .vgc_address_i(vgc_address_w),
    .vgc_rd_i(vgc_rd_w),
    .vgc_data_o(vgc_data_w)
);
```

### 4.5 Timing Analysis

- Current pipeline: 31+ pixel clocks deep (27 MHz = 37ns per pixel)
- Adding 1-2 cycle ROM lookup latency: acceptable
- CRTC register access: combinational (0 cycles)
- VRAM read: 1 cycle (SDPB registered output)
- **No timing concerns**

---

## Part 5: Architecture Decisions

### AD1: BSRAM — 1 block for VRAM, LUT RAM for character ROM
- Current: 41/46 blocks (90%). After: 42/46 (91%), 4 blocks free
- Videx VRAM shadow: 1 SDPB block (2 KB, sdpram32 ADDR_WIDTH=9)
- Character ROM: 4 KB in distributed/LUT RAM (`$readmemh`), 0 BSRAM
- CRTC registers: 18 bytes in flip-flops, 0 BSRAM

### AD2: Integrate into apple_video.sv (not a separate module)
- Add `VIDEX_LINE = 3'd2` as a new line type
- Reuses existing 28-step state machine, pixel buffer, and color output
- Avoids new pipeline stages between vgc/SuperSprite

### AD3: VRAM bank selection via CRTC register address bits [3:2]
The CPU sees only a 512-byte window at $CC00-$CDFF. The bank is selected by bits [3:2] of the last $C0Bx access:
- $C0B0/$C0B1 → bank 0 (offset 0x000)
- $C0B4/$C0B5 → bank 1 (offset 0x200)
- $C0B8/$C0B9 → bank 2 (offset 0x400)
- $C0BC/$C0BD → bank 3 (offset 0x600)

VRAM write formula: `vram[bankofs + (bus_addr & 0x1FF)] = data`

### AD4: Display geometry — 7-pixel horizontal, 9-scanline vertical
- **Horizontal:** Videx chars are 8px wide, but rendering all 8 would need 640px (incompatible with 28-step pipeline at current borders). Use only bits [6:0] of ROM data → 7 pixels/char → 4 chars × 7px = 28 pixels per pipeline cycle → 560px → same H_BORDER as Apple II. See Part 10 for detailed limitation analysis.
- **Vertical:** Full 9 scanlines per row. 9 × 24 rows = 216 content lines × 2 (doubling) = 432 pixels. Dynamic V_BORDER: VIDEX_V_BORDER = 24 (vs standard V_BORDER = 48). The `y_active_w` signal switches between standard and Videx vertical windows based on mode. Row and scanline computed via multiply-shift divide-by-9: `row = (content_y * 57) >> 9`, `scanline = content_y - row * 9`.

### AD5: Videx mode detection — sticky CRTC flag + AN0 gating
- Sticky flag (`videx_mode_r`) set on first write to $C0Bx, cleared on device reset. $C0B0-$C0BF are slot 3 I/O space — never used by normal Apple IIe software.
- Runtime mode switching via AN0 ($C058/$C059): Videx rendering only active when `videx_mode_r && text_mode_r && AN0`. The $C058/$C059 soft switches (annunciator 0) are monitored as `an0_r`, latched during blanking. This matches A2DVI's `SOFTSW_VIDEX_80COL` behavior and allows proper switching between Videx 80-column and standard Apple II display without requiring a reset.

### AD6: Character ROM format — 16 bytes/char, MSB = leftmost pixel
- ROM address: `{char[7:0], scanline[3:0]}` = 12 bits, 4096 entries
- Characters 0x00-0x7F = normal set, 0x80-0xFF = inverse set
- Inverse ROM has pre-inverted pixel data (not computed at runtime)
- No inversion (~) applied at read time (unlike Apple II viderom which inverts)

### AD7: Behavior when no Videx card is present

When no Videx VideoTerm (or compatible/emulated card like A2DVI) is installed in slot 3, A2FPGA must behave exactly as if Videx support does not exist — no visual artifacts, no mode switches, no wasted cycles.

**Runtime behavior (VIDEX_SUPPORT=1, no card installed):**

- **VIDEX_MODE stays false.** The auto-detection flag (`videx_crtc_write_detected`) is only set by CPU writes to `$C0B0-$C0BF` (slot 3 device I/O). Without a Videx card, no driver software will write to these addresses, so the flag is never set and the rendering pipeline never enters `VIDEX_LINE` mode.
- **No false triggers.** `$C0B0-$C0BF` is slot 3's dedicated device I/O space. The Apple IIe's built-in 80-column firmware uses entirely different addresses (`$C07x`, `$C00x`). No standard Apple II software writes to slot 3 I/O unless it specifically targets slot 3 hardware.
- **Rendering is unaffected.** The `line_type_w` mux checks `videx_mode_r` first — when false, it falls through to standard TEXT40/TEXT80/LORES/HIRES selection as normal.
- **VRAM and CRTC registers are idle but allocated.** The 1 BSRAM block for VRAM shadow and the flip-flops for CRTC registers are still instantiated. They consume no dynamic power (no writes occur), but they do consume static silicon resources.
- **Character ROM LUT RAM is idle but allocated.** The 4 KB LUT RAM array is synthesized and initialized from the hex file. It consumes ~150 SSRAM units of logic budget but is never read.

**Compile-time parameter (VIDEX_SUPPORT=0):**

For builds where Videx support is not wanted (e.g., to reclaim the 1 BSRAM block for other peripherals), a compile-time parameter should gate all Videx hardware:

```systemverilog
parameter VIDEX_SUPPORT = 1  // Set to 0 to eliminate all Videx hardware
```

When `VIDEX_SUPPORT=0`:
- No CRTC register capture logic (saves ~18 flip-flops + decode logic)
- No VRAM BSRAM block instantiated (saves 1 BSRAM block)
- No character ROM LUT RAM (saves ~150 SSRAM units)
- No `VIDEX_MODE` detection logic
- `VIDEX_MODE` signal hardwired to `1'b0`
- All Videx-related `a2mem_if` signals tied to constant zero
- The `VIDEX_LINE` path in `apple_video.sv` is dead code and optimized away by synthesis

This parameter should be set in `top.sv` and threaded through `apple_memory` and `apple_video` module instantiations.

**Summary:**

| Scenario | VIDEX_MODE | Resources Used | Rendering |
|----------|-----------|----------------|-----------|
| Videx card present, 80-col active | `true` | All Videx hardware active | Videx 80-column text |
| Videx card present, 40-col mode | `false` | VRAM/CRTC captured but not rendered | Standard Apple II modes |
| No Videx card installed | `false` (never set) | Hardware allocated but idle | Standard Apple II modes |
| `VIDEX_SUPPORT=0` (compile-time) | hardwired `0` | No Videx hardware synthesized | Standard Apple II modes only |

---

## Part 6: Detailed File Changes

### File 1: `hdl/memory/a2mem_if.sv` (modify)
**Deps:** None (do first)

Add Videx signals to interface and both modports (master=output, slave=input).

### File 2: `hdl/memory/apple_memory.sv` (modify)
**Deps:** a2mem_if.sv

- **Change A (~line 167):** CRTC register index/data capture + bank offset tracking
- **Change B (~line 182):** Mode detection (sticky flag)
- **Change C (~line 245):** VRAM write address generation with bank offset
- **Change D (~line 385):** Videx VRAM BSRAM instance (sdpram32, ADDR_WIDTH=9)
- **Change E:** Add module ports for Videx VRAM read path

### File 3: `hdl/video/apple_video.sv` (modify)
**Deps:** a2mem_if.sv, apple_memory.sv

- **Change A:** Add `VIDEX_LINE = 3'd2` constant
- **Change B:** Add Videx character ROM (LUT RAM, 4 KB, `$readmemh`)
- **Change C:** Add Videx geometry parameters (V_BORDER = 24 when active)
- **Change D:** Latch `videx_mode_r` during blanking
- **Change E:** Add `videx_mode_r ? VIDEX_LINE :` as highest priority in `line_type_w`
- **Change F:** Add Videx scanline counter (`videx_row_r` 0-23, `videx_scanline_r` 0-8)
- **Change G:** Add Videx memory address generation (display start from R12/R13, linear with & 0x7FF wrap)
- **Change H:** Add VIDEX pipeline stages (similar to TEXT80, 4-6 stages processing 4 chars per cycle)
- **Change I:** Add cursor rendering (XOR mask, blink modes from R10[6:5])
- **Change J:** Add module ports for Videx VRAM read

### File 4: `hdl/video/videx_charrom.hex` (new file)
- Convert A2DVI `videx_normal.c` (chars 0x00-0x7F) + `videx_inverse.c` (chars 0x80-0xFF)
- 4096 bytes in hex format, one byte per line
- Characters 0x00-0x7F: normal ROM data (128 × 16 bytes)
- Characters 0x80-0xFF: inverse ROM data (128 × 16 bytes)

### File 5: `boards/a2n20v2/hdl/top.sv` (modify)
**Deps:** All other files

- Add wires for Videx VRAM read path
- Connect to apple_memory port list
- Connect to apple_video port list

---

## Part 7: Phase Plan

### Phase 1: Bus Monitoring Only
**Files:** a2mem_if.sv, apple_memory.sv, top.sv (debug only)
**Goal:** Capture CRTC registers + VRAM writes with bank selection, verify via debug overlay
**Validate:** CRTC regs show R1=$50, R6=$18, R9=$08 after Videx init; VRAM captures text data across all 4 banks
**Resource cost:** +1 BSRAM, ~100 LUTs

### Phase 2: Static Videx Rendering
**Files:** apple_video.sv, videx_charrom.hex, top.sv
**Goal:** Render Videx 80-col text to HDMI (no cursor, assume R12/R13=0)
**Validate:** Characters display correctly on HDMI; existing modes unaffected
**Resource cost:** ~300 LUTs (character ROM in LUT RAM)

### Phase 3: Full Videx Rendering
**Files:** apple_video.sv
**Goal:** Add cursor, blink, display start address scrolling
**Validate:** Cursor blinks correctly, text scrolls via R12/R13, all cursor modes work

### Phase 4: Multiple Character Sets (future, not in this plan)

---

## Part 8: Risk Assessment

| Risk | Level | Mitigation |
|------|-------|------------|
| BSRAM overflow | LOW | Only +1 block; char ROM uses LUT RAM (0 BSRAM) |
| Timing closure | LOW | 27 MHz pixel clock, LUT RAM latency acceptable |
| Regression to existing modes | MEDIUM | VIDEX_MODE defaults off; only $C0Bx writes activate; test all modes |
| False Videx detection | LOW | $C0B0-$C0BF are slot 3 I/O — unused by normal Apple IIe software |
| VRAM bank mapping | MEDIUM | Phase 1 debug validates bank selection; addr[3:2] from $C0Bx must be captured on EVERY access (not just writes) |
| 7-pixel vs 8-pixel char width | LOW | 7-pixel mode matches existing pipeline; 8-pixel upgrade possible later |

---

## Part 9: Verification

1. **Phase 1:** Run Videx software on Apple II with A2DVI in slot 3. Check debug overlay shows correct CRTC register values and VRAM data matches expected text across all 4 banks.
2. **Phase 2:** Verify 80-column text appears on A2FPGA HDMI output. Compare character rendering against A2DVI's own HDMI output. Test TEXT40, TEXT80, LORES, HIRES modes still work when VIDEX_MODE is inactive.
3. **Phase 3:** Verify cursor position, blink modes, and scrolling. Test with ProTERM, Apple Writer, and Videx ROM self-test.

---

## Part 10: Known Limitations and Rationale

This section documents three known limitations in the current Videx implementation, their practical effects, the engineering rationale for each decision, and the complexity of fixing them in the future.

### 10.1 Seven-Pixel Character Width (AD4)

**Limitation:** Each Videx character is rendered at 7 pixels wide instead of the true 8 pixels defined by the MC6845 CRTC and the character ROM data.

**Root Cause — Pipeline Architecture Constraint:** The `apple_video.sv` rendering engine uses a fixed 28-step state machine that processes exactly 28 pixels per pipeline cycle. All existing Apple II display modes (TEXT40, TEXT80, LORES, HIRES, and their 80-column variants) are designed around this 28-pixel quantum. In the Videx pipeline, 4 characters are processed per cycle: 4 × 7 = 28 pixels, fitting perfectly. Using the full 8 pixels per character would require 4 × 8 = 32 pixels per cycle, which would break the pipeline timing and require fundamental changes to the state machine, pixel buffer width (`PIX_BUFFER_SIZE`), and all existing display modes.

**Practical Effect:** The rightmost pixel column of each character glyph (bit 0 of each ROM byte) is dropped. For the vast majority of characters — all alphanumeric characters, punctuation, and common symbols — this column is blank padding in the Videx character ROM, so the visual difference is imperceptible.

**Where It Matters:** The primary impact is on box-drawing and line-drawing characters in the range `$10-$1F`. These characters use all 8 pixel columns to create continuous horizontal lines. With only 7 pixels rendered, horizontal lines in box-drawing characters will have a 1-pixel gap between adjacent characters. This affects:
- Terminal programs that draw screen borders (e.g., ProTERM's UI frames)
- Spreadsheet programs with cell borders
- Any software using the Videx extended character set for line art

Standard text display (letters, numbers, punctuation) is unaffected because these characters have blank right-edge columns in the ROM data.

**Fix Complexity: HIGH.** Would require redesigning the pipeline to support a 32-step cycle or a variable-width step, changing `STEP_LENGTH`, `PIX_BUFFER_SIZE`, pixel shift register width, and H_BORDER calculations. All existing display modes would need re-validation. This is a fundamental architectural change, not a localized fix.

### 10.2 VRAM Word Alignment Assumption

**Limitation:** The display start address (CRTC registers R12/R13) is assumed to be a multiple of 4. If software sets R12/R13 to a non-aligned value, characters within each 4-character read group may appear in the wrong order.

**Root Cause — sdpram32 Memory Architecture:** The Videx VRAM shadow uses `sdpram32`, a 32-bit-wide Simple Dual Port RAM. Each read returns 4 bytes (4 characters) simultaneously at a word-aligned address. The current pipeline reads characters in groups of 4 and processes them sequentially across pipeline stages (`STAGE_VIDEX_0` through `STAGE_VIDEX_5`). The byte extraction logic assumes character 0 is at bits [7:0], character 1 at [15:8], etc., which is only correct when the base address is 4-byte aligned.

**Practical Effect:** If R12/R13 is set to, say, address `0x001` (offset by 1), the pipeline would still read the word at address `0x000` and treat byte 0 as the first character, when it should start with byte 1. This would cause the entire display to be shifted by 1-3 character positions within each group of 4.

**When This Occurs:** In practice, the Videx VideoTerm firmware and essentially all known Videx-compatible software initialize R12/R13 to `0x0000` and scroll by full row widths (80 characters). Since 80 is a multiple of 4, scrolling by row increments always maintains alignment. The only scenario where misalignment would occur is if software performed smooth horizontal scrolling by single-character increments, which is technically possible but not known to be used by any real Videx software.

**Fix Complexity: MEDIUM.** Would require adding a 2-bit offset register derived from `R12_R13 & 2'b11`, then using that offset to rotate the byte extraction from the 32-bit word. Approximately 20-30 additional LUTs for barrel-shifting the 4 bytes. The pipeline stage assignments would also need adjustment to handle the wrap-around case where one read group spans two words.

### 10.3 R9 (Max Scanline) Hardcoded to 8

**Limitation:** The number of scanlines per character row is fixed at 9 (R9 value of 8, meaning scanlines 0-8). The actual value of CRTC register R9 is captured from the bus but not used for rendering.

**Root Cause — Divide-by-9 Implementation:** The vertical position calculation uses a compile-time divide-by-9 via the multiply-shift trick: `row = (content_y * 57) >> 9`. This produces exact integer division by 9 for all content_y values from 0 to 215 (24 rows × 9 scanlines - 1). Making this dynamic would require either:
- A variable-divisor implementation (expensive in FPGA fabric — typically uses iterative subtraction or lookup tables)
- A set of parallel multiply-shift circuits for each possible R9 value with a mux to select the active one

Additionally, the vertical display geometry (`VIDEX_WINDOW_HEIGHT = 432`, `VIDEX_V_BORDER = 24`) is computed based on 9 scanlines per row. A different R9 value would change the total content height and require dynamic border adjustment.

**Practical Effect:** If software sets R9 to a value other than 8, characters would render with incorrect vertical spacing:
- R9 < 8: Character rows would overlap, causing garbled vertical display
- R9 > 8: Extra blank scanlines would appear between character rows, and the display would extend beyond the expected vertical window

**When This Occurs:** The Videx VideoTerm firmware always initializes R9 to `0x08` (9 scanlines, matching the 9×8 pixel character cell). The character ROM is designed around this geometry. No known Videx software changes R9 after initialization. Some theoretical use cases (custom character heights for graphics modes or reduced-height fonts) could set different R9 values, but these are not found in the real-world Videx software library.

**Fix Complexity: MEDIUM-HIGH.** Would require:
1. A parameterizable divider or lookup table for the row/scanline computation (~50-100 LUTs)
2. Dynamic `VIDEX_WINDOW_HEIGHT` and `VIDEX_V_BORDER` based on R9 and R6 (vertical displayed)
3. Re-validation of the `y_active_w` window signal for all possible R9 values
4. Potential timing issues if the divide path becomes too long for one clock cycle

### 10.4 Summary

| Limitation | Affected Use Case | Frequency in Real Software | Fix Complexity |
|---|---|---|---|
| 7-pixel character width | Box-drawing chars ($10-$1F) | Occasional (terminal UI borders) | HIGH (pipeline redesign) |
| VRAM word alignment | Non-4-aligned R12/R13 scroll | Extremely rare (no known software) | MEDIUM (barrel shift) |
| R9 hardcoded to 8 | Non-standard character height | Extremely rare (no known software) | MEDIUM-HIGH (variable divider) |

All three limitations represent deliberate engineering trade-offs that prioritize compatibility with the existing pipeline architecture and real-world Videx software behavior. The 7-pixel limitation has the most visible effect but is architecturally the hardest to fix. The other two limitations are unlikely to manifest with any known Videx software.
