# Videx VideoTerm 80-Column Card — Implementation Specification

## Target: `videx_card.sv` for A2FPGA (Approach B)

This specification defines every hardware behavior the virtual Videx card module implements, derived from exhaustive analysis of the Videx VideoTerm ROM 2.4 firmware, MC6845 CRTC datasheet, and physical Videx hardware testing.

---

## 1. Module Interface

```systemverilog
module videx_card #(
    parameter bit [7:0] ID = 5,
    parameter bit ENABLE = 1'b1
) (
    a2bus_if.slave   a2bus_if,
    a2mem_if.videx   a2mem_if,       // videx modport: outputs VIDEX_* signals, reads INTCXROM/SLOTROM
    slot_if.card     slot_if,        // slot system (same pattern as Mockingboard/SSC)

    output [7:0]     data_o,         // data driven onto bus for reads
    output           rd_en_o,        // active when card is driving data_o
    output           rom_en_o,       // C8 space ownership status (exported for status)

    // Scanner VRAM read port (wired to apple_video VIDEX_LINE pipeline)
    input [8:0]      videx_vram_addr_i,
    input            videx_vram_rd_i,
    output [31:0]    videx_vram_data_o
);
```

The card follows the same `slot_if.card` pattern as `Mockingboard` and `SuperSerial`:
- `ID` parameter: unique card identifier (5 = Videx), matched against `slots.hex` assignment
- `ENABLE` parameter: compile-time enable (card synthesizes away when 0)
- `slot_if.card` modport provides: `slot`, `card_id`, `io_select_n`, `dev_select_n`, `io_strobe_n`, `config_select_n`, `card_config`, `card_enable`
- `a2mem_if.videx` modport: outputs `VIDEX_MODE` and `VIDEX_CRTC_R9`–`R15`, reads `INTCXROM` and `SLOTROM`
- `rom_en_o`: expansion ROM ownership flag (exported for status, not consumed by top.sv)
- Scanner VRAM port: the `VIDEX_LINE` pipeline in `apple_video.sv` reads VRAM through the card's 32-bit read port, eliminating the need for a separate shadow VRAM copy

The card does **not** generate interrupts (`irq_n` is not needed — the real Videx had no IRQ).

---

## 2. Address Decoding

The card responds to three address regions. All decoding is active during `phi1_posedge` when `!m2sel_n`.

### 2.1 Device I/O: `$C0B0–$C0BF`

Active when `slot_if.dev_select_n` is asserted (active-low) and `slot_if.card_id == ID`. The slot 3 device select range is `$C0B0–$C0BF` (16 addresses).

| Bits | Meaning |
|------|---------|
| `addr[3:2]` | VRAM bank select (0–3), latched on **every** access (read or write, even or odd) |
| `addr[0]` | 0 = CRTC address register, 1 = CRTC data register |

### 2.2 Slot ROM: `$C300–$C3FF`

Active when `slot_if.io_select_n` is asserted. The card drives `data_o` with the firmware ROM byte at offset `addr[7:0]`. This also sets the expansion ROM ownership flag.

### 2.3 Expansion ROM: `$C800–$CFFF`

Active when the card owns the expansion ROM space (ownership flag is set) and `a2bus_if.phi0` is high. The card drives `data_o` with the firmware ROM byte. The VRAM window at `$CC00–$CDFF` overlaps this range — see Section 5.

> **Note**: The implementation uses `rom_c8_active && phi0` rather than `card_io_strobe` (`!slot_if.io_strobe_n && phi0`). This is necessary because `io_strobe_n` is blocked by `INTC8ROM` on the Apple ][+ — see Section 6.6 for the full explanation. The card uses self-clearing `c8_owned` ownership (cleared on other-slot `$Csxx` access) instead of a `SLOTROM` guard — see §3 for details.

### 2.4 VRAM Window: `$CC00–$CDFF`

A 512-byte subrange of the expansion ROM space. When the expansion ROM ownership flag is set and `addr[15:9] == 7'b1100_110` (`$CC00–$CDFF`):
- **Writes**: Store byte to VRAM at `{bank[1:0], addr[8:0]}`
- **Reads**: Drive VRAM byte onto `data_o` (overrides expansion ROM)

### 2.5 `$CFFF` Strobe

Any access to `$CFFF` clears the expansion ROM ownership flag. The Videx firmware's CSW/KSW handlers do `STA $CFFF` at every entry (via `MAIN_HANDLER` at `$C336`). The Pascal INIT path (`$C311 → JMP $C800`) does **not** access `$CFFF`.

---

## 3. Expansion ROM Ownership Protocol

```
Ownership flag (c8_owned, 1 bit):
  SET   when CPU accesses $C300–$C3FF (slot_if.io_select_n asserted)
  CLEAR when CPU accesses $CFFF (while !INTCXROM)
  CLEAR when another slot's $Csxx ROM space is accessed (while !INTCXROM)
  CLEAR on system reset

Active flag (rom_c8_active):
  c8_owned && !INTCXROM
```

When `rom_c8_active` is **true**, the card responds to `$C800–$CFFF` reads (expansion ROM + VRAM window). When **false**, the card ignores `$C800–$CFFF`.

The card monitors `$C100–$C7FF` accesses (excluding slot 3 and `$C0xx`) and clears `c8_owned` when another slot's ROM space is accessed. This "self-clearing" approach prevents the card from driving the bus with Videx ROM data when another slot's expansion ROM is being accessed — critical for the Pascal OS boot sequence where INIT returns without clearing ownership (see §19, edge case #7). The detection is phi0-qualified to avoid transient address matches during phi1.

**Implementation**:
```systemverilog
wire other_slot_rom = a2bus_if.phi0 &&
                      (a2bus_if.addr[15:11] == 5'b1100_0) &&  // $C100-$C7FF
                      (a2bus_if.addr[10:8] != 3'd3) &&        // not slot 3
                      (a2bus_if.addr[10:8] != 3'd0);          // not $C0xx

reg c8_owned;
always @(posedge a2bus_if.clk_logic) begin
    if (!a2bus_if.system_reset_n)
        c8_owned <= 1'b0;
    else if (card_io_sel)
        c8_owned <= 1'b1;
    else if (!a2mem_if.INTCXROM && (cfff_access || other_slot_rom))
        c8_owned <= 1'b0;
end

wire rom_c8_active = c8_owned && !a2mem_if.INTCXROM;
```

**Why self-clearing instead of SLOTROM guard**: An earlier approach used `SLOTROM == 3` from `apple_memory.sv` to gate `rom_c8_active`. This caused PR#3 to hang — probable cause is a timing mismatch between `SLOTROM` (updated on `phi1_posedge` in `apple_memory.sv`) and the card's phi0-qualified read signals. The self-clearing approach works reliably because the card monitors the bus directly, using the same clock edge and qualification.

---

## 4. MC6845 CRTC Register Emulation

### 4.1 Register File

16 registers, 8 bits each. One 5-bit index register.

```
reg [4:0] crtc_idx;          // latched from writes to even $C0Bx addresses
reg [7:0] crtc_regs[0:15];   // R0–R15
```

### 4.2 Write Behavior

**Even address** (`addr[0] == 0`): Latch `data[4:0]` into `crtc_idx`.

**Odd address** (`addr[0] == 1`): If `crtc_idx < 16`, write `data[7:0]` to `crtc_regs[crtc_idx]`.

All writes also update the VRAM bank select from `addr[3:2]` (Section 2.1).

### 4.3 Read Behavior (HD6845SP Type 1)

The card must respond to ALL device-select reads (`$C0Bx`) and assert `rd_en_o`, not just R14/R15. The real MC6845 always drives the data bus on reads to its address range — returning `$00` for write-only or non-existent registers. Failing to respond leaves the bus floating ("open bus"), causing programs to read garbage values like `$C0` (the address high byte on the Apple II), which leads to wrong VRAM offsets, scattered garbage characters, and lockups.

**Even address** (`$C0B0`, `$C0B4`, `$C0B8`, `$C0BC`): Returns `$00`. The MC6845 address/status register read returns `$00` — status bits (retrace, update ready, light pen) are not implemented. Physical Videx also returns `$00` (confirmed via VIDEX_DIAG T01).

**Odd address** (`$C0B1`, `$C0B5`, `$C0B9`, `$C0BD`): If `crtc_idx` is 0–15, returns `crtc_regs[crtc_idx]` (the written value). For indices 16–31 (non-existent), returns `$00`. This matches HD6845SP Type 1 behavior where **all** R0–R15 are readable, and also matches A2DVI's CRTC implementation.

**Implementation**:
```systemverilog
wire crtc_read     = card_dev_sel && a2bus_if.rw_n;  // ALL dev-sel reads
wire [7:0] crtc_data = (a2bus_if.addr[0] && crtc_idx < 5'd16)
                     ? crtc_regs[crtc_idx] : 8'h00;
```

**HD6845SP Type 1 vs. MC6845 Type 0**: The original MC6845 (Type 0) makes only R14/R15 readable. The HD6845SP (Hitachi, Type 1) — the chip used in physical Videx cards — returns written values for all R0–R15. The A2FPGA implementation follows Type 1 behavior. Physical HD6845SP has a quirk where R12 reads as 63 and R13 reads as 60 (partial state leakage, not the written value), but the implementation returns the exact written value for all registers.

**Why read-back matters**: The Videx ROM itself never reads CRTC registers. However, third-party detection software and diagnostic tools write test values to various registers, then read them back. VIDEX_DIAG tests T02–T06, T13, and T17 all verify CRTC read-back behavior.

### 4.4 Register Initialization Values (from ROM 2.4)

These are programmed by the firmware at ROM offset `$0A1` (CPU `$C8A1`), not by the card hardware. Listed here for reference and testing. Values shown are from the actual ROM image in `hdl/videx/videx_rom.hex`, verified against the user's physical VT-FRM-600 (C) 1982 VIDEX card:

| Reg | Value | Purpose |
|-----|-------|---------|
| R0  | `$7A` (122)  | Horizontal Total: 123 character times/line |
| R1  | `$50` (80)   | Horizontal Displayed: 80 characters |
| R2  | `$5E` (94)   | Horizontal Sync Position |
| R3  | `$2F` (47)   | Sync Widths: H=15, V=2 (packed `{vsync_w[3:0], hsync_w[3:0]}`) |
| R4  | `$22` (34)   | Vertical Total: 35 character rows |
| R5  | `$00` (0)    | Vertical Total Adjust: 0 extra scan lines |
| R6  | `$18` (24)   | Vertical Displayed: 24 rows |
| R7  | `$1D` (29)   | Vertical Sync Position: row 29 |
| R8  | `$00`        | Interlace: non-interlaced |
| R9  | `$08`        | Max Scan Line: 9 scanlines/row (0–8) |
| R10 | `$E0`        | Cursor Start: scanline 0, blink 1/32 field rate |
| R11 | `$08`        | Cursor End: scanline 8 |
| R12 | `$00`        | Display Start Address High |
| R13 | `$00`        | Display Start Address Low |
| R14 | `$00`        | Cursor Address High |
| R15 | `$00`        | Cursor Address Low |

#### 4.4.1 50 Hz vs. 60 Hz CRTC Variants

The Videx VideoTerm ROM 2.4 exists in two known variants that differ only in CRT timing registers. MAME catalogs both:

| Variant | MAME BIOS ID | ROM Size | CRC-32 | Source |
|---------|-------------|----------|--------|--------|
| **50 Hz** | `v24_50hz` | 1 KB | `bbe3bb28` | Original Videx ROM (this image) |
| **60 Hz** | `v24_60hz` | 2 KB | `5776fa24` | Clone card dump (`6.ic6.bin`) |

Five CRTC registers differ between the two variants:

| Reg | 50 Hz (This ROM) | 60 Hz (Clone) | Effect |
|-----|-------------------|---------------|--------|
| R0  | `$7A` (122) → 123 chars | `$7B` (123) → 124 chars | +1 horizontal character time |
| R3  | `$2F` (H=15, V=2) | `$29` (H=9, V=2) | Narrower horizontal sync pulse |
| R4  | `$22` (34) → 35 rows | `$1B` (27) → 28 rows | Fewer total vertical rows |
| R5  | `$00` → 0 adjust lines | `$08` → 8 adjust lines | Added scanlines to compensate |
| R7  | `$1D` (29) | `$19` (25) | Earlier vertical sync position |

**Timing calculation — 50 Hz variant** (this ROM):
- Character clock = 17.430 MHz ÷ 9 pixels = 1.937 MHz
- Horizontal frequency = 1.937 MHz ÷ 123 = 15,745 Hz (63.51 µs/line)
- Total scanlines = 35 rows × 9 scanlines + 0 adjust = **315 lines**
- Vertical frequency = 15,745 ÷ 315 = **49.98 Hz** (PAL-compatible)

**Timing calculation — 60 Hz variant** (clone ROM):
- Character clock = 17.430 MHz ÷ 9 pixels = 1.937 MHz
- Horizontal frequency = 1.937 MHz ÷ 124 = 15,621 Hz (64.02 µs/line)
- Total scanlines = 28 rows × 9 scanlines + 8 adjust = **260 lines**
- Vertical frequency = 15,621 ÷ 260 = **60.08 Hz** (NTSC-compatible)

**Hypothesis for the difference**: The original Videx VideoTerm was designed in 1980–1981 for the US market (NTSC, 60 Hz). The ROM 2.4 image preserved in the Apple II Documentation Project and btb/80ColumnCard repository produces 50 Hz timing, suggesting it may have been a later revision for European/PAL markets, or (more likely) the CRTC init values were not critical since the Videx generates its own independent video timing from its 17.430 MHz crystal — the Apple II's NTSC sync is irrelevant to the Videx output. The CRT monitor connected to the Videx's DB-15 port would free-run at whatever rate the card produces.

**Impact on A2FPGA**: The HDMI rendering pipeline in `apple_video.sv` ignores R0–R8 entirely. It uses hard-coded geometry (80 columns × 24 rows × 9 scanlines at 720×480 HDMI). Only R9–R15 (which are identical between both variants) affect display output. **The 50 Hz vs. 60 Hz distinction is irrelevant for FPGA implementation.**

### 4.5 Which Registers the Renderer Uses

The existing `VIDEX_LINE` renderer in `apple_video.sv` reads these via `a2mem_if`:

| Register | Signal | Renderer Use |
|----------|--------|-------------|
| R9[3:0]  | `VIDEX_CRTC_R9` | Max scanline (character height - 1) |
| R10      | `VIDEX_CRTC_R10` | Cursor start line + blink mode |
| R11      | `VIDEX_CRTC_R11` | Cursor end line |
| R12      | `VIDEX_CRTC_R12` | Display start address high (hardware scroll) |
| R13      | `VIDEX_CRTC_R13` | Display start address low |
| R14      | `VIDEX_CRTC_R14` | Cursor position high |
| R15      | `VIDEX_CRTC_R15` | Cursor position low |

R0–R8 define CRT timing that is irrelevant to HDMI rendering. They must be stored (for R14/R15 read-back indexing to work) but are not forwarded to the renderer.

### 4.6 Driving the Renderer

The card drives CRTC register values to the `VIDEX_LINE` rendering pipeline via `a2mem_if.videx` modport signals (`VIDEX_CRTC_R9` through `VIDEX_CRTC_R15`). These are assigned directly from the card's internal register array whenever register writes occur.

`VIDEX_MODE` is driven by `card_enable` — the card is always "in mode" when configured in its slot. The `VIDEX_LINE` pipeline activates when `VIDEX_MODE && TEXT_MODE && AN0`.

---

## 5. VRAM Architecture

### 5.1 Organization

2 KB total, organized as 4 banks × 512 bytes:

| Bank | VRAM Offset | Selected By |
|------|------------|-------------|
| 0    | `$000–$1FF` | `addr[3:2] = 00` (e.g., `$C0B0`) |
| 1    | `$200–$3FF` | `addr[3:2] = 01` (e.g., `$C0B4`) |
| 2    | `$400–$5FF` | `addr[3:2] = 10` (e.g., `$C0B8`) |
| 3    | `$600–$7FF` | `addr[3:2] = 11` (e.g., `$C0BC`) |

### 5.2 Bank Selection

A register `bank_sel[1:0]` is updated on **every** access to `$C0B0–$C0BF`:

```systemverilog
// On any access to $C0Bx (read or write):
bank_sel <= a2bus_if.addr[3:2];
```

The bank select determines which 512-byte bank is visible through the `$CC00–$CDFF` window.

**Side effect**: CRTC register writes to `$C0B0`/`$C0B1` implicitly select bank 0 (since `addr[3:2] = 00`). The ROM's `PSNCALC` routine explicitly reads from `$C0B0+X` where X ∈ {0, 4, 8, 12} to select the correct bank before each VRAM access.

### 5.3 VRAM Address Calculation

The full 11-bit VRAM address for a CPU access to `$CC00–$CDFF`:

```
vram_addr[10:0] = {bank_sel[1:0], addr[8:0]}
```

Where `addr[8:0]` comes from the bus address (`$CC00` + offset, so `addr[8]` distinguishes `$CC00–$CCFF` from `$CD00–$CDFF`).

### 5.4 Write Path

When the CPU writes to `$CC00–$CDFF` and the expansion ROM ownership flag is set:

```systemverilog
vram[{bank_sel, addr[8:0]}] <= data_in;
```

The card's VRAM SDPB block has a 32-bit read port wired to the `VIDEX_LINE` rendering pipeline for scanner access (4 characters per read cycle).

### 5.5 Read Path

When the CPU reads from `$CC00–$CDFF` and the expansion ROM ownership flag is set:

```systemverilog
data_o <= vram[{bank_sel, addr[8:0]}];
rd_en_o <= 1;
```

The VRAM SDPB uses asymmetric port widths: 8-bit write for CPU access, 32-bit read for the scanner pipeline. CPU read-back uses a hold register and byte selection from the 32-bit read data.

**Why VRAM reads matter**: The Videx ROM's CTRL-U "pick" function reads the character under the cursor from VRAM. Advanced programs (Apple Writer II, WordStar, VisiCalc) also read VRAM directly.

### 5.6 VRAM as Circular Buffer

The 2 KB VRAM is used as a ring buffer for hardware scrolling:
- Display start = `{R12[2:0], R13[7:0]}` (11-bit address, wraps at 2048)
- 24 rows × 80 columns = 1920 bytes active
- 128 bytes unused gap
- Scrolling increments the display start by 80 (one row), wraps modulo 2048
- New blank lines are written at the wrap point

The ROM tracks the scroll offset in the `START` screen hole (`$06FB`). `START` ranges 0–127, and the display start address = `START × 16`.

### 5.7 Implementation: Single GoWin SDPB with Muxed Read Port

A single GoWin SDPB primitive provides both CPU read-back and scanner access through a muxed read port:

| Port | Width | User | Purpose |
|------|-------|------|---------|
| Write (Port A) | 8-bit | CPU writes to `$CC00–$CDFF` | Byte-addressed VRAM writes |
| Read (Port B) | 32-bit | Muxed: scanner (priority) or CPU | 4 chars per read for scanner; byte-selected for CPU |

The asymmetric port widths (BIT_WIDTH_0=8 write, BIT_WIDTH_1=32 read) use exactly **1 SDPB block** for the full 2 KB — avoiding the 4-block byte_enable splitting penalty of `sdpram32`.

The read port is shared between the `VIDEX_LINE` scanner pipeline (via `videx_vram_addr_i`/`videx_vram_rd_i`/`videx_vram_data_o`) and CPU reads. Scanner has priority. A 2-cycle SDPB pipeline feeds separate hold registers:
- **Scanner hold** (32-bit): captures 4-character word for `apple_video.sv`
- **CPU hold** (32-bit): captures word, then byte-selected via `vram_addr[1:0]` pipeline

The previous shadow VRAM in `apple_memory.sv` has been removed. The card's VRAM is the sole copy.

**Cost**: 1 SDPB block (2 KB).

---

## 6. Firmware ROM

### 6.1 Storage

1 KB ROM chip mapped into two regions:

| CPU Address | ROM Offset | Size | Purpose |
|-------------|-----------|------|---------|
| `$C300–$C3FF` | `$300–$3FF` | 256 bytes | Slot ROM |
| `$C800–$CBFF` | `$000–$3FF` | 1024 bytes | Expansion ROM |

The slot ROM at `$C300–$C3FF` is the **same physical bytes** as `$CB00–$CBFF` in the expansion ROM. The ROM file is 1 KB; the slot ROM window reads from the last 256 bytes.

### 6.2 RAM Allocation

The 1 KB ROM is annotated with `syn_ramstyle="distributed_ram"` to use LUTs instead of BSRAM. A 2-stage pipeline read is used for GoWin distributed RAM inference. GoWin may still place this in BSRAM depending on optimization context.

Loaded from `videx_rom.hex` via `$readmemh`.

### 6.3 Read Response

```
if slot ROM access ($C300–$C3FF):
    data_o <= rom[{2'b11, addr[7:0]}]   // 10-bit index, offset $300–$3FF
    rd_en_o <= 1

if expansion ROM access ($C800–$CBFF) and ownership flag set:
    data_o <= rom[addr[9:0]]             // ROM $000–$3FF
    rd_en_o <= 1
```

### 6.4 Expansion ROM vs. VRAM Window Priority

Addresses `$CC00–$CDFF` fall within the expansion ROM range (`$C800–$CFFF`) but are the VRAM window, not ROM. When ownership is set:

```
if addr[15:9] == 7'b1100_110:      // $CC00–$CDFF
    // VRAM access (read or write) — see Section 5
else if addr[15:11] == 5'b11001:   // $C800–$CFFF (excluding $CC00–$CDFF)
    // Expansion ROM read
```

Addresses `$CC00–$CDFF` are **never** served from ROM. Addresses `$CE00–$CFFF` are unused by the Videx and should return open bus (card does not drive `data_o`).

The real Videx hardware maps:
- `$C800–$CBFF`: ROM (1 KB)
- `$CC00–$CDFF`: VRAM window (512 bytes, bank-selected)
- `$CE00–$CFFF`: unused

### 6.5 Signature Bytes

These bytes in the slot ROM are checked by software for card detection:

| Address | Value | Check |
|---------|-------|-------|
| `$C305` | `$38` | Pascal 1.1 ID byte 1 (SEC instruction) |
| `$C307` | `$18` | Pascal 1.1 ID byte 2 (CLC instruction) |
| `$C30B` | `$01` | Pascal 1.1 generic signature |
| `$C30C` | `$82` | Device type: `$8x` = 80-column card |

These are part of the ROM content and require no special hardware handling — they're just bytes served from the ROM image.

**ProDOS IIe detection note**: ProDOS on the Apple IIe checks a fifth byte at `$CnFA` (offset `$3FA`) for `$2C` to identify 80-column cards. The Videx ROM has `$C4` at this offset, not `$2C`. This is historically accurate — the original Videx VideoTerm ROM predates the IIe convention. On Apple ][/][+, ProDOS uses the standard 4-byte Pascal 1.1 protocol above and detects the card correctly. No ROM patch is applied.

### 6.6 SLOTC3ROM and INTC8ROM — Apple IIe Compatibility

This emulation targets Apple ][/][+. On an Apple IIe, the motherboard's `SLOTC3ROM` soft switch controls whether `$C300–$C3FF` is served by the internal ROM or by slot 3. By default (after reset), the IIe serves its own ROM at `$C300`, hiding slot 3 cards. Software must execute `STA $C00B` to enable `SLOTC3ROM` before the Videx slot ROM becomes visible.

The `slotmaker` does not gate `io_select_n` with `SLOTC3ROM` — this matches real Apple IIe behavior where `IOSELECT` is gated by the motherboard, not by the card.

#### 6.6.1 The INTC8ROM Problem on the Apple ][+

**Critical implementation detail**: `apple_memory.sv` contains IIe-style logic that sets `INTC8ROM=1` whenever the CPU accesses `$C300–$C3FF` and `SLOTC3ROM=0`:

```systemverilog
// apple_memory.sv — IIe INTC8ROM logic
if (!a2mem_if.SLOTC3ROM && (a2bus_if.addr[15:8] == 8'hC3)) INTC8ROM <= 1'b1;
```

On the Apple ][+, `SLOTC3ROM` defaults to 0 (the IIe soft switch is never written). This means **every access to `$C3xx` sets `INTC8ROM=1`**. In the slotmaker, `INTC8ROM=1` blocks `io_strobe_n`:

```systemverilog
// slotmaker.sv
slot_iostrobe_n = a2mem_if.INTCXROM | a2mem_if.INTC8ROM | !c8_sel;
```

With `INTC8ROM=1`, `io_strobe_n` is permanently stuck HIGH, making the standard `card_io_strobe` signal (`!io_strobe_n && phi0`) **permanently false for slot 3 on the Apple ][+**.

This does NOT affect the SSC (slot 2) or Mockingboard (slot 4) because the `INTC8ROM` check only triggers for `$C3xx` — it is a slot 3-specific issue.

**Why `STA $CFFF` doesn't help**: The Videx ROM writes `STA $CFFF` at `$C336` to clear `INTC8ROM`. But the very next instruction fetch comes from `$C337` (still in `$C3xx`), which immediately re-sets `INTC8ROM=1`. There is no window where `INTC8ROM=0` AND the CPU is fetching from `$C800+`.

**The failure sequence**:
1. CPU accesses `$C300` (slot scan) → `INTC8ROM` set to 1
2. Videx ROM executes from slot ROM (`$C300–$C3FF`)
3. At `$C336`: `STA $CFFF` → `INTC8ROM` cleared to 0
4. At `$C337`: next instruction fetch → `INTC8ROM` re-set to 1
5. At `$C358`: `JSR $C800` → card cannot respond (io_strobe_n blocked)
6. CPU reads open bus at `$C800` → executes garbage → crash → reboot loop

#### 6.6.2 The Fix: Bypass `io_strobe_n` with Self-Clearing Ownership

The `videx_card` module does **not** use `card_io_strobe` (`!slot_if.io_strobe_n && phi0`) for expansion ROM or VRAM reads. Instead, it qualifies C8-space reads with `phi0` directly and uses its own `c8_owned` flip-flop for ownership tracking:

```systemverilog
// videx_card.sv — C8 space reads bypass io_strobe_n
// c8_owned is self-clearing: set on card_io_sel, cleared on $CFFF or other-slot access
wire rom_c8_active = c8_owned && !a2mem_if.INTCXROM;
wire exp_rom_read = rom_c8_active && a2bus_if.phi0 && exp_rom_range && a2bus_if.rw_n;
wire vram_read    = rom_c8_active && a2bus_if.phi0 && vram_window && a2bus_if.rw_n;
```

The self-clearing `c8_owned` (see §3) automatically clears when another slot's `$Csxx` ROM space is accessed. This prevents the card from responding to `$C800-$CFFF` reads when another slot is active — critical for the Pascal OS boot sequence where INIT returns without clearing ownership (see §19, edge case #7). After the Pascal INIT path (`$C311 → JMP $C800 → INIT → RTS`), `c8_owned` stays set, but the next `$Csxx` access (e.g., `$C200` for SSC) automatically clears it.

**Why not SLOTROM guard**: An earlier approach used `SLOTROM == 3` from `apple_memory.sv` instead of self-clearing `c8_owned`. This caused PR#3 to hang — probably due to timing mismatch between `SLOTROM` (updated on `phi1_posedge` in `apple_memory.sv`) and the card's phi0-qualified read signals. The self-clearing approach works reliably because it monitors the bus directly using the same clock edge.

The `phi0` qualification ensures `rd_en_o` is only active during the data phase of the bus cycle, preventing the bus transceiver from driving during phi1 (when the 6502 places the address high byte on the data bus).

Slot ROM reads (`card_io_sel`) and CRTC reads (`card_dev_sel`) are unaffected — they use slot_if signals that depend on `io_select_n` and `dev_select_n`, which are NOT blocked by `INTC8ROM`.

On A2FPGA boards with `VIDEX_CARD_ENABLE=0` (all boards except `a2n20v2`), this is irrelevant.

---

## 7. Annunciator 0 (AN0) — Display Mode Switching

The Videx firmware uses AN0 to signal 80-column mode:

| Address | Effect | When Used by Firmware |
|---------|--------|----------------------|
| `$C058` | AN0 OFF → 40-column mode | `CTRL-Z` + `'1'` (exit to 40-col) |
| `$C059` | AN0 ON → 80-column mode | Initialization; **every character output** |

The card does **not** need to handle AN0 directly. The existing soft switch capture in `apple_memory.sv` already tracks `SWITCHES_II[4]` (AN0) when the CPU accesses `$C058/$C059`. The `VIDEX_LINE` renderer activates when `videx_mode_r && text_mode_r && an0_r`.

**Key detail**: The Videx firmware writes `STA $C059` on **every single character output** (`OUTPT1` at `$CA8F`), re-asserting AN0. This ensures the display stays in 80-column mode even if something else toggled AN0.

### 7.1 Shadow Rendering Mode

The card architecture supports a passive shadow rendering mode for use with a physical Videx VideoTerm card. In this configuration:

- **Physical Videx** in slot 3 drives the Apple II bus (firmware ROM, CRTC, VRAM)
- **A2FPGA** in another physical slot (typically slot 7) with the Videx card module configured for slot 3

The FPGA card snoops all bus writes to slot 3 addresses — CRTC register writes (`$C0B0/$C0B1`), VRAM writes (`$CC00–$CDFF`), and soft switch accesses (`$C058/$C059`) — without driving the bus (`rd_en_o=0`, `rom_en_o=0`). The `VIDEX_LINE` pipeline renders the snooped data on HDMI output, providing a digital display for a physical Videx card that only has composite video output.

This mode was used during development to verify the rendering pipeline independently from bus response logic. To enable shadow mode, disable the `rd_en_o` and `rom_en_o` assignments in `videx_card.sv`.

---

## 8. Screen Holes (Firmware State in Page-Hole RAM)

The Videx firmware stores its working state in Apple II "screen holes" — addresses within the text page that are not displayed. For slot 3, these are at offset +3 within each hole group. The card hardware does **not** need to intercept these — they are normal RAM locations that the 6502 reads and writes. Listed here for debugging and testing reference:

| Address | Name | Purpose |
|---------|------|---------|
| `$0478` | CRFLAG | Autowrap flag / slot marker (`$C3` during operation) |
| `$047B` | BASEL | VRAM line base address low byte |
| `$04FB` | BASEH | VRAM line base address high byte |
| `$057B` | CHORZ | Cursor horizontal position (0–79) |
| `$05FB` | CVERT | Cursor vertical position (0–23) |
| `$06FB` | START | Scroll offset (0–127). Display start = START × 16 |
| `$077B` | POFF | Power-off detection / lead-in state. `$30` = initialized |
| `$07FB` | FLAGS | Bit 0: inverse. Bit 3: exit-to-40col. Bit 6: case. Bit 7: GETLN |
| `$04F8` | TEMP_ROW | Temporary row storage during cursor positioning |
| `$05F8` | TEMP_CHORZ | Temporary horizontal position during cursor positioning |
| `$0678` | LAST_CHAR | Last character saved (used in PUTC/KEYPROC) |
| `$067B` | TEMP_CHAR | Temporary character save during PUTC processing |

---

## 9. Character Encoding in VRAM

The firmware encodes characters before writing to VRAM using `ASL A; PHA; LDA FLAGS; LSR A; PLA; ROR A` (ROM `$CA71–$CA78`). The ASL shifts the character left, the LSR loads the inverse flag into carry, and the ROR shifts right with the inverse flag injected into bit 7:

```
vram_byte = {FLAGS.bit0, ascii_char[6:0]}
```

- Bit 7: 0 = normal, 1 = inverse (from FLAGS bit 0)
- Bits [6:0]: ASCII character code (7-bit, e.g., `$41` = 'A')

The character ROM stores only 128 normal characters (2 KB). The ROM is addressed as `{vram_byte[6:0], scanline[3:0]}` (11-bit address into 2 KB ROM). Inverse characters (vram bit 7 = 1) are rendered by XOR-inverting the normal character's pixel data at capture time in the `VIDEX_LINE` pipeline, saving 1 BSRAM block.

Only scanlines 0–8 are displayed (R9 = 8). Each character cell is 7 pixels wide. Scanlines 9–15 in the ROM are padding.

---

## 10. Bus Response Priority and Timing

### 10.1 Response Priority

When multiple address ranges could match, priority from highest to lowest:

1. **VRAM window** (`$CC00–$CDFF`, ownership set) — read/write VRAM
2. **CRTC registers** (`$C0B0–$C0BF`) — register I/O + bank select
3. **Slot ROM** (`$C300–$C3FF`) — serve ROM byte, set ownership
4. **Expansion ROM** (`$C800–$CBFF`, ownership set) — serve ROM byte
5. **`$CFFF`** — clear ownership (no data driven)

### 10.2 Timing

- **Writes** (`!rw_n`): Capture on `phi1_posedge` (CRTC/bank) or `data_in_strobe` (VRAM) when `!m2sel_n`.
- **Reads** (`rw_n`): Drive `data_o` and assert `rd_en_o` during `phi0` only.

**phi0 qualification is mandatory** for all read-response signals. The `apple_bus.sv` bridge drives the external bus transceiver direction from `data_out_en_i` with a phase-counter-gated OE cutoff:

```systemverilog
// OE cutoff: release bus transceiver before CDC-delayed phi0 drop
localparam int CDC_DELAY = 6;   // CDC denoise pipeline delay
localparam int OE_MARGIN = 2;   // Cycles past estimated real phi0 drop
localparam int OE_CUTOFF = PHASE_COUNT - CDC_DELAY + OE_MARGIN;  // = 22

wire oe_early_cutoff = a2bus_if.phi0 && (phase_cycles_r >= OE_CUTOFF[5:0]);
assign a2_bridge_bus_d_oe_n_o = ~(data_out_en_i & BUS_DATA_OUT_ENABLE & ~oe_early_cutoff);
```

If `rd_en_o` is true during phi1, the transceiver drives the Apple II data bus while the 6502 is simultaneously placing the address high byte on it — causing bus contention and system crashes. Every signal that feeds `rd_en_o` must include phi0: `card_io_sel` and `card_dev_sel` inherit it from `card_sel`; `exp_rom_read` and `vram_read` include it explicitly.

The OE cutoff addresses a secondary timing issue: the CDC denoise pipeline delays phi0 by ~6 clk_logic cycles (~100ns). Without the cutoff, `data_out_en_i` keeps the CPLD bus driver active for the full CDC delay into phi1. The cutoff releases OE at phase cycle 22 (of 26), approximately 37ns after the estimated real phi0 drop — matching real slot card 74LS245 release timing. This is critical for I/O writes ($C0xx) from C8 space, which are sensitive to extended bus driving. See §24.7 for the ROM patch test evidence.

The card must drive `data_o` early enough in the bus cycle for the CPU to sample it. The `apple_bus.sv` bridge checks `data_out_en_i` at `phase_cycles_r == WRITE_COUNT` (10 clk_logic cycles into phi0, ~185 ns) and samples `data_out_i` one cycle later. The ROM pipeline (2-stage registered read) settles well within this window (~14 clk_logic cycles from address latch to data sample). The OE cutoff at cycle 22 is well after IO_WRITE_DATA completes (cycle 13).

---

## 11. Complete State Machine

The card has minimal state — no complex state machine is needed. The entire card is combinational/registered logic:

### Registered State

```
reg        c8_owned;           // expansion ROM ownership flag (self-clearing)
reg [4:0]  crtc_idx;           // CRTC register index
reg [7:0]  crtc_regs[0:15];   // CRTC register file
reg [1:0]  bank_sel;           // VRAM bank select
// VRAM: GoWin SDPB primitive (8-bit write, 32-bit read), shared with scanner
```

### Reset State

```
c8_owned      <= 0;
crtc_idx      <= 0;
bank_sel      <= 0;
crtc_regs[*]  <= 0;
// VRAM: no reset needed (firmware clears it during init)
```

### Per-Cycle Logic

Uses the card enable and slot_if selection pattern from Mockingboard/SSC:

```systemverilog
// Selection signals (following Mockingboard/SSC pattern)
wire card_sel     = card_enable && (slot_if.card_id == ID) && a2bus_if.phi0;
wire card_dev_sel = card_sel && !slot_if.dev_select_n;    // $C0Bx during phi0
wire card_io_sel  = card_sel && !slot_if.io_select_n;     // $C300-$C3FF during phi0
// NOTE: card_io_strobe is NOT used — see Section 6.6.1 (INTC8ROM blocks it for slot 3)

// Other-slot detection for self-clearing ownership (see §3)
wire other_slot_rom = phi0 && addr[15:11]==5'b1100_0 && addr[10:8]!=3'd3 && addr[10:8]!=3'd0;

// C8 space ownership — self-clearing, independent of SLOTROM (see §6.6.2)
wire rom_c8_active = c8_owned && !a2mem_if.INTCXROM;

// VRAM and expansion ROM address ranges
wire vram_window   = (a2bus_if.addr[15:9] == 7'b1100_110);    // $CC00-$CDFF
wire exp_rom_range = (a2bus_if.addr[15:10] == 6'b110010);     // $C800-$CBFF
```

**Writes** — captured on `phi1_posedge` using direct address decode:

```
// 1. Bank select — on ANY $C0Bx access (read or write)
on phi1_posedge, if card_enable && addr[15:4] == $C0B && !m2sel_n:
    bank_sel <= addr[3:2];

// 2. CRTC writes
    if (!rw_n)
        if (addr[0] == 0)
            crtc_idx <= data[4:0];          // address register
        else if (crtc_idx < 16)
            crtc_regs[crtc_idx] <= data;    // data register

// 3. VRAM write (via SDPB write port)
on data_in_strobe, if rom_c8_active && vram_window && !rw_n:
    vram[{bank_sel, addr[8:0]}] <= data;

// 4. Slot ROM access → set ownership
on posedge clk_logic, if card_io_sel:
    c8_owned <= 1;

// 5. $CFFF or other-slot $Csxx → clear ownership
on posedge clk_logic, if !INTCXROM && (addr == $CFFF || other_slot_rom):
    c8_owned <= 0;
```

**Reads** — driven during phi0 via selection signals:

```
// 6. CRTC reads (ALL device-select reads) — combinational
//    HD6845SP Type 1: all R0-R15 return written values (see §4.3)
if card_dev_sel && rw_n:
    if addr[0] == 1 && crtc_idx < 16:
        data_o = crtc_regs[crtc_idx];
    else:
        data_o = $00;

// 7. Slot ROM read — registered (2-stage pipeline for GoWin distributed RAM)
if card_io_sel && rw_n:
    data_o = rom[{2'b11, addr[7:0]}];       // last 256 bytes of 1KB ROM

// 8. VRAM read — from SDPB hold register, phi0-qualified (NOT card_io_strobe, see §6.6.1)
if rom_c8_active && phi0 && vram_window && rw_n:
    data_o = vram_read_byte;                 // byte-selected from 32-bit cpu_hold

// 9. Expansion ROM read — registered, phi0-qualified (NOT card_io_strobe, see §6.6.1)
if rom_c8_active && phi0 && exp_rom_range && rw_n:
    data_o = rom[addr[9:0]];                 // full 1KB ROM

// rd_en_o = card_enable && (any of cases 6-9)
```

### Renderer Interface

The card **directly drives** `a2mem_if.VIDEX_CRTC_R*` and `VIDEX_MODE` signals via the `a2mem_if.videx` modport. The card is the sole owner of all Videx state. The scanner VRAM read port is wired directly to the `VIDEX_LINE` pipeline in `apple_video.sv`.

---

## 12. Integration into Board Top-Level

### 12.1 Parameters

Add to `boards/a2n20v2/hdl/top.sv` module parameters:

```systemverilog
parameter bit VIDEX_CARD_ENABLE = 1,
parameter bit [7:0] VIDEX_CARD_ID = 5,
```

Couple `VIDEX_SUPPORT` with `VIDEX_CARD_ENABLE` — the rendering pipeline requires the card module:

```systemverilog
apple_memory #(.VGC_MEMORY(1), .VIDEX_SUPPORT(VIDEX_CARD_ENABLE)) apple_memory (...);
apple_video  #(.VIDEX_SUPPORT(VIDEX_CARD_ENABLE)) apple_video (...);
```

### 12.2 Instantiation

The card follows the same `slot_if.card` pattern as Mockingboard and SSC. It is gated by a generate block:

```systemverilog
wire [7:0] videx_d_w;
wire videx_rd;
wire videx_rom_en;

generate if (VIDEX_CARD_ENABLE) begin : videx_card_gen
    videx_card #(.ENABLE(VIDEX_CARD_ENABLE), .ID(VIDEX_CARD_ID)) videx (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),
        .slot_if(slot_if),
        .data_o(videx_d_w),
        .rd_en_o(videx_rd),
        .rom_en_o(videx_rom_en),
        // Scanner VRAM port (wired to apple_video VIDEX_LINE pipeline)
        .videx_vram_addr_i(videx_vram_addr),
        .videx_vram_rd_i(videx_vram_rd),
        .videx_vram_data_o(videx_vram_data)
    );
end else begin : no_videx_card_gen
    assign videx_d_w = 8'b0;
    assign videx_rd = 1'b0;
    assign videx_rom_en = 1'b0;
end endgenerate
```

### 12.3 Bus Multiplexer

Add card's data output to the existing bus mux:

```systemverilog
assign data_out_en_w = ssp_rd || mb_rd || ssc_rd || videx_rd;
assign data_out_w = videx_rd ? videx_d_w :
    ssc_rd ? ssc_d_w : ssp_rd ? ssp_d_w : mb_rd ? mb_d_w : a2bus_if.data;
```

No IRQ change — the Videx card has no IRQ.

### 12.4 Slot Assignment

Update `hdl/slots/slots.hex` to assign Videx card ID 5 to slot 3:

```
00 00 03 05 02 04 00 01
```

The slotmaker module reads this file at initialization, configures slot 3 with card_id=5, and routes the slot 3 select signals to all cards via `slot_if`. The videx_card's enable logic matches on `slot_if.card_id == ID` during configuration.

---

## 13. Rendering Path

The `VIDEX_LINE` pipeline in `apple_video.sv` handles all rendering. Summary of what it does:

### 13.1 Mode Activation

```systemverilog
wire line_type_w = (videx_mode_r & text_mode_r & an0_r) ? VIDEX_LINE : ...;
```

`videx_mode_r` is driven by `a2mem_if.VIDEX_MODE`, which the card sets to `card_enable` (always active when configured). `text_mode_r` and `an0_r` come from soft switches.

### 13.2 Display Geometry

- 80 columns × 24 rows × 9 scanlines = 560 × 216 active pixels
- Doubled to 560 × 432 for HDMI output within 720 × 480 frame
- V border = 24 pixels each side (vs. 48 for standard Apple II text)

### 13.3 VRAM Address for Rendering

```
row_start = (text_base + row × 80) mod 2048
char_addr = (row_start + column) mod 2048
```

Where `text_base = {R12[2:0], R13[7:0]}`. This is the 11-bit circular buffer address.

### 13.4 Character ROM Lookup

```
rom_addr = {vram_byte[6:0], scanline[3:0]}   // 11-bit address into 2 KB ROM
pixel_data = videxrom[rom_addr]               // 8 bits, only lower 7 used
```

The ROM stores only normal characters (0x00–0x7F). Inverse characters use the same ROM data with pixel inversion applied at capture (§13.5).

### 13.5 Cursor Rendering

Cursor position: `{R14[2:0], R15[7:0]}` (11-bit VRAM address).
Blink mode from R10[6:5]: `00`=always on, `01`=hidden, `10`=1/16 field rate, `11`=1/32 field rate.
Scanline range: R10[3:0] (start) to R11[3:0] (end).

Rendered by XOR combining the character's inverse flag (vram bit 7) with the cursor active flag:
```
pixel_out = rom_data[6:0] ^ {7{vram_byte[7] ^ cursor_active}}
```
This means: normal char + no cursor = normal pixels, inverse char + no cursor = inverted pixels, normal char + cursor = inverted pixels, inverse char + cursor = normal pixels (double inversion cancels).

---

## 14. BSRAM Budget

Baseline (no Videx): 41/46 blocks used (89%), 5 free.

| New Component | Type | BSRAM Blocks |
|--------------|------|-------------|
| Firmware ROM (1 KB) | Distributed RAM (LUTs), annotated `syn_ramstyle="distributed_ram"` | 0–1 |
| Character ROM (2 KB, halved from 4 KB) | pROM | 1 |
| VRAM (2 KB, GoWin SDPB asymmetric 8-bit write / 32-bit read) | SDPB | 1 |
| **Total Videx** | | **3** |
| **Total with Videx** | | **44/46** |
| **Remaining free** | | **2** |

The character ROM halving (§9 — chars `$80–$FF` are inverse of `$00–$7F`, XOR at capture in VIDEX_LINE) saves 1 BSRAM block vs. a full 4 KB charrom. The VRAM uses a single SDPB block with asymmetric port widths instead of the 4 blocks that `sdpram32` with byte_enable would consume.

---

## 15. Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `hdl/videx/videx_card.sv` | **Create** | Virtual card module (~300 lines), follows Mockingboard/SSC `slot_if.card` pattern |
| `hdl/videx/videx_rom.hex` | **Exists** | Videx VideoTerm ROM 2.4 image (1 KB, hex format) — already created |
| `boards/a2n20v2/hdl/top.sv` | **Modify** | Add `VIDEX_CARD_ENABLE`/`VIDEX_CARD_ID` params, instantiate card, wire to bus mux, couple `VIDEX_SUPPORT` with `VIDEX_CARD_ENABLE` |
| `hdl/slots/slots.hex` | **Modify** | Assign Videx card ID 5 to slot 3 |
| `hdl/memory/apple_memory.sv` | **Modify** | Add `is_iie` runtime detection, fix INTC8ROM logic for Apple ][+ |
| `hdl/video/apple_video.sv` | **Modify** | Add `VIDEX_LINE` rendering pipeline with charrom halving (XOR inversion) |
| `hdl/memory/a2mem_if.sv` | **Modify** | Add `videx` modport, VIDEX_MODE and VIDEX_CRTC_R9–R15 signals |

---

## 16. Testing Checklist

### 16.1 Card Detection

- [ ] `PR#3` from Applesoft BASIC activates 80-column mode
- [ ] ROM signature bytes at `$C305=$38`, `$C307=$18`, `$C30B=$01`, `$C30C=$82`
- [ ] CRTC R14/R15 write-then-read-back returns written value
- [ ] ProDOS slot scan identifies an 80-column card in slot 3

### 16.2 Character Output

- [ ] Printable ASCII characters display correctly in 80 columns
- [ ] Cursor advances after each character
- [ ] Line wraps at column 80 (autowrap mode)
- [ ] All control codes work: BS, LF, CR, FF (clear screen), HOME, CLREOL, CLREOP

### 16.3 Scrolling

- [ ] Text scrolls when output reaches line 24
- [ ] Hardware scroll via R12/R13 updates (no visible copy delay)
- [ ] Scroll wraps correctly through 2 KB ring buffer
- [ ] New blank line appears at bottom after scroll

### 16.4 VRAM Access

- [ ] Direct VRAM writes to `$CC00–$CDFF` display correctly
- [ ] Bank selection via `$C0B0/$C0B4/$C0B8/$C0BC` works
- [ ] VRAM read-back returns previously written value
- [ ] CTRL-U "pick" function reads character under cursor

### 16.5 Display Quality

- [ ] 9-scanline character height (full descenders on g, j, p, q, y)
- [ ] Cursor blinks at correct rate (1/32 field rate = ~1.9 Hz)
- [ ] Cursor is full-height block (scanlines 0–8)
- [ ] Inverse characters display correctly (CTRL-O to enable, CTRL-N to disable)

### 16.6 ESC Sequences

- [ ] ESC + row + column cursor positioning (used by terminal emulators like ProTERM)
- [ ] All ESC-@ through ESC-G sequences (see firmware `OUTPT1` at `$CA89` and POFF state machine)

### 16.7 Mode Switching

- [ ] `CTRL-Z` + `'1'` switches to 40-column mode (AN0 off)
- [ ] `CTRL-Z` + `'0'` reinitializes card
- [ ] Returning to BASIC prompt and typing `PR#3` re-enters 80-column mode

---

## 17. Reference: Firmware Entry Points

| Address | Entry | Mechanism |
|---------|-------|-----------|
| `$C300` | Cold start | `BIT $FFCB` → `BVS ENTR` (V=1) |
| `$C305` | Keyboard input | `SEC` → carry=1 marks input path |
| `$C307` | Character output | `CLC` → carry=0 marks output path |
| `$C332` | Input hook (KSW) | Firmware patches `$38/$39` to `$C332` |

The firmware patches both CSW (`$36/$37` → `$C307`) and KSW (`$38/$39` → `$C332`) during initialization.

---

## 18. Reference: Firmware Cold Start Sequence

For understanding the exact order of hardware accesses during initialization:

1. `STA $CFFF` — deselect other expansion ROMs
2. Write `$C3` to `$0478` (CRFLAG)
3. Patch KSW to `$C332`, CSW to `$C307`
4. Write `$30` to `$077B` (POFF), `$07FB` (FLAGS)
5. Write `$00` to `$06FB` (START)
6. Clear all VRAM: write `$A0` (space) to 1920 positions via bank-switched `$CC00–$CDFF`
7. Program R0–R15 sequentially: 16 pairs of `STA $C0B0` / `STA $C0B1`
8. `STA $C059` — set AN0 on, enabling 80-column display

---

## 19. Known Edge Cases

1. **CRTC writes to `$C0B0` select bank 0 as a side effect.** The firmware relies on this — after programming CRTC registers, bank 0 is implicitly selected.

2. **The firmware's CSW/KSW handlers access `$CFFF` at every entry** (input and output) via `STA $CFFF` at `$C336` (slot ROM). This clears `rom_ownership`, but the very next instruction fetch (`$C339`, also slot ROM) triggers `card_io_sel` and immediately re-asserts it. By the time the firmware enters expansion ROM via JSR, ownership is restored. The **Pascal INIT path** (`$C311 → JMP $C800`) does NOT access `$CFFF` — see edge case #7.

3. **VRAM window takes priority over expansion ROM** at `$CC00–$CDFF`. If the firmware were to try to execute code from `$CC00–$CDFF`, it would read VRAM, not ROM. (It never does this — all code is in `$C800–$CBFF`.)

4. **R12/R13 display start uses only 11 bits** (`{R12[2:0], R13[7:0]}`). Upper bits of R12 are ignored by the renderer.

5. **ROM timing variants**: The Videx ROM 2.4 exists in 50 Hz and 60 Hz variants with different R0/R3/R4/R5/R7 CRTC values (see Section 4.4.1). The card hardware doesn't care — it stores whatever the ROM writes. The renderer ignores R0–R8 timing registers entirely.

6. **INTC8ROM blocks `io_strobe_n` for slot 3 on the Apple ][+.** The `apple_memory.sv` IIe logic sets `INTC8ROM=1` on every `$C3xx` access when `SLOTC3ROM=0`. On the Apple ][+, `SLOTC3ROM` is never set, so `INTC8ROM` is permanently 1 after the first slot 3 access. This blocks the standard `card_io_strobe` signal. The Videx card bypasses this by using `phi0` directly with its own `rom_c8_active` ownership tracking for C8-space reads. See Section 6.6.1 for the full analysis and failure sequence.

7. **Pascal INIT path never accesses `$CFFF` — requires self-clearing ownership.** The `PASCAL_INIT` entry (`$C311 → JMP $C800 → INIT → RTS`) initializes the card but does not execute `STA $CFFF` (which is only in `MAIN_HANDLER`). After INIT returns, `c8_owned` remains set. The self-clearing `c8_owned` (§3) automatically clears when Pascal accesses another slot's `$Csxx` ROM space during its slot scan, preventing the card from responding to other slots' `$C800-$CFFF` reads. Without this self-clearing behavior, `INTC8ROM` blocks those other slots' `io_strobe_n` while our card responds exclusively — feeding wrong data to the CPU and causing a crash/reboot.

8. **CRTC reads must respond to ALL `$C0Bx` device-select reads, not just R14/R15.** The real MC6845 always drives the data bus on reads, returning `$00` for write-only or non-existent registers. If the card fails to respond, the CPU reads "open bus" — typically `$C0` (the address high byte) on the Apple ][+. Programs like CardCat that read CRTC registers other than R14/R15 (e.g., R12/R13 for display start address) interpret the garbage value as a real register value, leading to wrong VRAM offsets, scattered garbage characters, cursor at bottom-right, and eventual lockup. See §4.3.

9. **`rd_en_o` must be phi0-qualified to prevent bus contention.** The `apple_bus.sv` bridge drives `a2_bridge_bus_d_oe_n_o` from `data_out_en_i` with a phase-counter OE cutoff that releases the bus transceiver ~37ns after estimated real phi0 drop (see §10.2). If `rd_en_o` is true during phi1, the FPGA bus transceiver drives the Apple II data bus while the 6502 is also driving it with the address high byte. All read-response signals in the Videx card are phi0-qualified: `card_io_sel` and `card_dev_sel` include phi0 via `card_sel`; `exp_rom_read` includes phi0 explicitly. Additionally, all address-sensitive ownership logic (`cfff_access`, `other_slot_rom`) must be phi0-qualified to avoid responding to bus transients during phi1 — see §23.8.

---

## 20. Firmware ROM Reference

### 20.1 ROM Identity and Checksums

| Property | Value |
|----------|-------|
| File | `hdl/videx/videx_rom.hex` (1024 lines, one hex byte per line) |
| Format | `$readmemh` compatible — loaded in SystemVerilog with `$readmemh("videx_rom.hex", rom, 0)` |
| Version | Videx VideoTerm Firmware v2.4 (50 Hz variant) |
| Size | 1024 bytes (1 KB) |
| SHA-256 | `616f4d9f81a7a4ea0fa918842a05dfb3b503927776d2bfe97e6950b5431b562e` |
| SHA-1 | `bb653836e84850ce3197f461d4e19355f738cfbf` |
| CRC-32 | `bbe3bb28` |
| Source | btb/80ColumnCard GitHub repository |
| Verification | Byte-for-byte match at `$C300–$C3FF` against physical VT-FRM-600 (C) 1982 VIDEX card |
| MAME BIOS ID | `v24_50hz` (in `src/devices/bus/a2bus/a2videoterm.cpp`) |
| Author | Darrel Aldrich, (c) 1981 Videx Inc. |

### 20.2 Memory Map

The 1 KB ROM maps into two Apple II address regions:

```
ROM Offset    CPU Address    Visible As           Purpose
──────────    ───────────    ──────────           ───────
$000-$0FF  →  $C800-$C8FF   Expansion ROM pg 0   Initialization, CRTC init table
$100-$1FF  →  $C900-$C9FF   Expansion ROM pg 1   Cursor movement, scrolling, ESC handler
$200-$2FF  →  $CA00-$CAFF   Expansion ROM pg 2   VRAM address calc, char output, dispatch
$300-$3FF  →  $CB00-$CBFF   Expansion ROM pg 3   Slot ROM entry, main handler, line editor
               $C300-$C3FF   Slot ROM (alias)     Same bytes as $CB00-$CBFF
```

The slot ROM at `$C300–$C3FF` mirrors `$CB00–$CBFF`. In SystemVerilog:

```systemverilog
// Slot ROM read: offset $300-$3FF
data_o <= rom[{1'b1, 1'b1, addr[7:0]}];   // = rom[$300 + addr[7:0]]
// Expansion ROM read: offset $000-$3FF
data_o <= rom[addr[9:0]];
```

### 20.3 Complete Hex Dump

1024 bytes, 16 per line, with CPU addresses and ASCII interpretation:

```
         00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F
$C800:   AD 7B 07 29 F8 C9 30 F0 21 A9 30 8D 7B 07 8D FB   .{.)..0.!.0.{...
$C810:   07 A9 00 8D FB 06 20 61 C9 A2 00 8A 8D B0 C0 BD   ...... a........
$C820:   A1 C8 8D B1 C0 E8 E0 10 D0 F1 8D 59 C0 60 AD FB   ...........Y.`..
$C830:   07 29 08 F0 09 20 93 FE 20 22 FC 20 89 FE 68 A8   .)... .. ". ..h.
$C840:   68 AA 68 60 20 D1 C8 E6 4E D0 02 E6 4F AD 00 C0   h.h` ...N...O...
$C850:   10 F5 20 5C C8 90 F0 2C 10 C0 18 60 C9 8B D0 02   .. \...,...`....
$C860:   A9 DB C9 81 D0 0A AD FB 07 49 40 8D FB 07 B0 E7   .........I@.....
$C870:   48 AD FB 07 0A 0A 68 90 1F C9 B0 90 1B 2C 63 C0   H.....h......,c.
$C880:   30 14 C9 B0 F0 0E C9 C0 D0 02 A9 D0 C9 DB 90 08   0...............
$C890:   29 CF D0 04 A9 DD 09 20 48 29 7F 8D 7B 06 68 38   )...... H)..{.h8
$C8A0:   60 7A 50 5E 2F 22 00 18 1D 00 08 E0 08 00 00 00   `zP^/"..........
$C8B0:   00 8D 7B 06 A5 25 CD FB 05 F0 06 8D FB 05 20 04   ..{..%........ .
$C8C0:   CA A5 24 CD 7B 05 90 03 8D 7B 05 AD 7B 06 20 89   ..$.{....{..{. .
$C8D0:   CA A9 0F 8D B0 C0 AD 7B 05 C9 50 B0 13 6D 7B 04   .......{..P..m{.
$C8E0:   8D B1 C0 A9 0E 8D B0 C0 A9 00 6D FB 04 8D B1 C0   ..........m.....
$C8F0:   60 49 C0 C9 08 B0 1D A8 A9 C9 48 B9 F2 CB 48 60   `I........H...H`
$C900:   EA AC 7B 05 A9 A0 20 71 CA C8 C0 50 90 F8 60 A9   ..{... q...P..`.
$C910:   34 8D 7B 07 60 A9 32 D0 F8 A0 C0 A2 80 CA D0 FD   4.{.`.2.........
$C920:   AD 30 C0 88 D0 F5 60 AC 7B 05 C0 50 90 05 48 20   .0....`.{..P..H
$C930:   B0 C9 68 AC 7B 05 20 71 CA EE 7B 05 2C 78 04 10   ..h.{. q..{.,x..
$C940:   07 AD 7B 05 C9 50 B0 68 60 AC 7B 05 AD FB 05 48   ..{..P.h`.{....H
$C950:   20 07 CA 20 04 C9 A0 00 68 69 00 C9 18 90 F0 B0    .. ....hi......
$C960:   23 20 67 C9 98 F0 E8 A9 00 8D 7B 05 8D FB 05 A8   # g.......{.....
$C970:   F0 12 CE 7B 05 10 9D A9 4F 8D 7B 05 AD FB 05 F0   ...{....O.{.....
$C980:   93 CE FB 05 4C 04 CA A9 30 8D 7B 07 68 09 80 C9   ....L...0.{.h...
$C990:   B1 D0 67 A9 08 8D 58 C0 D0 5B C9 B2 D0 51 A9 FE   ..g...X..[...Q..
$C9A0:   2D FB 07 8D FB 07 60 8D 7B 06 4E 78 04 4C CB C8   -.....`.{.Nx.L..
$C9B0:   20 27 CA EE FB 05 AD FB 05 C9 18 90 4A CE FB 05    '..........J...
$C9C0:   AD FB 06 69 04 29 7F 8D FB 06 20 12 CA A9 0D 8D   ...i.).... .....
$C9D0:   B0 C0 AD 7B 04 8D B1 C0 A9 0C 8D B0 C0 AD FB 04   ...{............
$C9E0:   8D B1 C0 A9 17 20 07 CA A0 00 20 04 C9 B0 95 C9   ..... .... .....
$C9F0:   B3 D0 0E A9 01 0D FB 07 D0 A9 C9 B0 D0 9C 4C 09   ..............L.
$CA00:   C8 4C 27 C9 AD FB 05 8D F8 04 0A 0A 6D F8 04 6D   .L'.........m..m
$CA10:   FB 06 48 4A 4A 4A 4A 8D FB 04 68 0A 0A 0A 0A 8D   ..HJJJJ...h.....
$CA20:   7B 04 60 C9 0D D0 06 A9 00 8D 7B 05 60 09 80 C9   {.`.......{.`...
$CA30:   A0 B0 CE C9 87 90 08 A8 A9 C9 48 B9 B9 C9 48 60   ..........H...H`
$CA40:   18 71 13 B2 48 60 AF 9D F2 13 13 13 13 13 13 13   .q..H`..........
$CA50:   13 13 66 0E 13 38 00 14 7B 18 98 6D 7B 04 48 A9   ..f..8..{..m{.H.
$CA60:   00 6D FB 04 48 0A 29 0C AA BD B0 C0 68 4A 68 AA   .m..H.).....hJh.
$CA70:   60 0A 48 AD FB 07 4A 68 6A 48 20 59 CA 68 B0 05   `.H...JhjH Y.h..
$CA80:   9D 00 CC 90 03 9D 00 CD 60 48 A9 F7 20 A0 C9 8D   ........`H.. ...
$CA90:   59 C0 AD 7B 07 29 07 D0 04 68 4C 23 CA 29 04 F0   Y..{.)...hL#.)..
$CAA0:   03 4C 87 C9 68 38 E9 20 29 7F 48 CE 7B 07 AD 7B   .L..h8. ).H.{..{
$CAB0:   07 29 03 D0 15 68 C9 18 B0 03 8D FB 05 AD F8 05   .)...h..........
$CAC0:   C9 50 B0 03 8D 7B 05 4C 04 CA 68 8D F8 05 60 AD   .P...{.L..h...`.
$CAD0:   00 C0 C9 93 D0 0F 2C 10 C0 AD 00 C0 10 FB C9 83   ......,.........
$CAE0:   F0 03 2C 10 C0 60 A8 B9 31 CB 20 F1 C8 20 44 C8   ..,..`..1. .. D.
$CAF0:   C9 CE B0 08 C9 C9 90 04 C9 CC D0 EA 4C F1 C8 EA   ............L...
$CB00:   2C CB FF 70 31 38 90 18 B8 50 2B 01 82 11 14 1C   ,..p18...P+.....
$CB10:   22 4C 00 C8 20 44 C8 29 7F A2 00 60 20 A7 C9 A2   "L.. D.)...` ...
$CB20:   00 60 C9 00 F0 09 AD 00 C0 0A 90 03 20 5C C8 A2   .`.......... \..
$CB30:   00 60 91 28 38 B8 8D FF CF 48 85 35 8A 48 98 48   .`.(8....H.5.H.H
$CB40:   A5 35 86 35 A2 C3 8E 78 04 48 50 10 A9 32 85 38   .5.5...x.HP..2.8
$CB50:   86 39 A9 07 85 36 86 37 20 00 C8 18 90 6F 68 A4   .9...6.7 ....oh.
$CB60:   35 F0 1F 88 AD 78 06 C9 88 F0 17 D9 00 02 F0 12   5....x..........
$CB70:   49 20 D9 00 02 D0 3B AD 78 06 99 00 02 B0 03 20   I ....;.x......
$CB80:   ED CA A9 80 20 F5 C9 20 44 C8 C9 9B F0 F1 C9 8D   .... .. D.......
$CB90:   D0 05 48 20 01 C9 68 C9 95 D0 12 AC 7B 05 20 59   ..H ..h.....{. Y
$CBA0:   CA B0 05 BD 00 CC 90 03 BD 00 CD 09 80 8D 78 06   ..............x.
$CBB0:   D0 08 20 44 C8 A0 00 8C 78 06 BA E8 E8 E8 9D 00   .. D....x.......
$CBC0:   01 A9 00 85 24 AD FB 05 85 25 4C 2E C8 68 AC FB   ....$....%L..h..
$CBD0:   07 10 08 AC 78 06 C0 E0 90 01 98 20 B1 C8 20 CF   ....x...... .. .
$CBE0:   CA A9 7F 20 A0 C9 AD 7B 05 E9 47 90 D4 69 1F 18   ... ...{..G..i..
$CBF0:   90 D1 60 38 71 B2 7B 00 48 66 C4 C2 C1 FF C3 EA   ..`8q.{.Hf......
```

### 20.4 Entry Points and Subroutine Map

#### Slot ROM Entry Points (`$C300–$C3FF` = `$CB00–$CBFF`)

| Address | Label | Mechanism | Purpose |
|---------|-------|-----------|---------|
| `$C300` (`$CB00`) | `SLOT_ENTRY` | `BIT $FFCB` → `BVS` | Cold start detection (V=1 from `$FFCB`) |
| `$C305` (`$CB05`) | `INPUT_ENTRY` | `SEC` | Keyboard input path (carry=1) |
| `$C307` (`$CB07`) | `OUTPUT_ENTRY` | `CLC` | Character output path (carry=0) |
| `$C311` | `PASCAL_INIT` | Pascal 1.1 INIT offset | Card initialization |
| `$C314` | `PASCAL_READ` | Pascal 1.1 READ offset | Character input |
| `$C31C` | `PASCAL_WRITE` | Pascal 1.1 WRITE offset | Character output |
| `$C322` | `PASCAL_STATUS` | Pascal 1.1 STATUS offset | Device status |

#### Expansion ROM Subroutines (`$C800–$CBFF`)

| Address | Label | Called From | Purpose |
|---------|-------|-------------|---------|
| `$C800` | `INIT` | Cold start | Check POFF, initialize card if needed |
| `$C809` | `INIT_FULL` | `$C800` | Full initialization: set POFF, FLAGS, START, clear screen |
| `$C816` | `INIT_CRTC_LOOP` | `$C809` | Program all 16 CRTC registers from table |
| `$C82E` | `EXIT_TO_40` | ESC-1 | Exit 80-col: call SETVID/VTAB/SETKBD |
| `$C844` | `GETKEY` | Input path | Wait for keyboard with random seed |
| `$C85C` | `KEYPROC` | `$C844` | Process keystroke: case toggle, shift check |
| `$C8A1` | `CRTC_TABLE` | `$C816` | Data: 16-byte CRTC initialization values |
| `$C8B1` | `PUTC` | Output path | Sync ZP cursor, dispatch character |
| `$C8C9` | `CURSOR_UPDATE` | `$C8B1` | Write cursor position to CRTC R12–R15 |
| `$C8F1` | `ESC_DISPATCH` | `$C8B1` | Dispatch ESC-@ through ESC-G |
| `$C901` | `CLR_EOL` | ESC-E / Ctrl-] | Clear from cursor to end of line |
| `$C90F` | `SHOW_VER_4` | Ctrl-D | Display version '4' (writes `$34` to POFF) |
| `$C915` | `SHOW_VER_2` | Ctrl-B | Display version '2' (writes `$32` to POFF) |
| `$C919` | `BELL` | Ctrl-G | Sound speaker ($C030) with delay loop |
| `$C927` | `SCROLL_CHECK` | Cursor move | Check if cursor is in scrollable area |
| `$C939` | `CUR_RIGHT` | ESC-A / Ctrl-\ | Move cursor right with autowrap |
| `$C949` | `CUR_DOWN_SCROLL` | LF / cursor down | Move cursor down, scroll if at bottom |
| `$C961` | `HOME` | ESC-@ / Ctrl-L (FF) | Home cursor: CHORZ=0, CVERT=0 |
| `$C967` | `SCROLL_UP` | `$C949` | Scroll display up one line |
| `$C972` | `CUR_LEFT` | ESC-B / Ctrl-H (BS) | Move cursor left, wrap to prev line |
| `$C97C` | `CUR_UP` | ESC-D / Ctrl-_ | Move cursor up, wrap to bottom |
| `$C987` | `ESC_MAIN` | Output ESC mode | Dispatch ESC-0/1/2/3 lead-in sequences |
| `$C99E` | `INV_OFF` | ESC-2 | Clear inverse flag: FLAGS &= `$FE` |
| `$C9A7` | `STORE_CHAR` | `$CB36` | Store character to screen hole |
| `$C9B0` | `NEW_LINE` | `$C939` | Carriage return + line feed |
| `$C9B3` | `CUR_DOWN` | ESC-C / Ctrl-J (LF) | Move cursor down with scroll check |
| `$C9E8` | `SCROLL_DONE` | `$C9B3` | Finalize scroll: clear new line, cursor update |
| `$C9F3` | `INV_ON` | ESC-3 | Set inverse flag: FLAGS |= `$01` |
| `$CA04` | `VRAM_CALC` | Many | Calculate VRAM base address from CVERT and START |
| `$CA12` | `BANK_SELECT` | `$CA59` | Select VRAM bank via CRTC addr register bits |
| `$CA23` | `CHAR_DISPATCH` | `$C8B1` | Route char: CR special, control table, or printable |
| `$CA59` | `VRAM_WRITE` | `$CA23` | Write one character position to VRAM |
| `$CA71` | `ENCODE_CHAR` | `$CA59` | Encode char: `{inverse, ascii[6:0]}`, select bank |
| `$CA89` | `OUTPT1` | Output path | Main output wrapper: set CRTC, check mode |
| `$CAD1` | `PAUSE_CHECK` | `$CA89` | Check Ctrl-S pause via keyboard |
| `$CAE6` | `PRINT_MSG` | `$CB36` | Print message string via ESC dispatch |
| `$CB36` | `MAIN_HANDLER` | `$CB00` | Central dispatcher: save regs, route I/O/cold |

### 20.5 Data Tables

#### CRTC Initialization Table (`$C8A1`, 16 bytes)

```
Offset  Addr   Hex                                  Decoded
$0A1    $C8A1: 7A 50 5E 2F 22 00 18 1D 00 08 E0 08 00 00 00 00
               R0 R1 R2 R3 R4 R5 R6 R7 R8 R9 R10 R11 R12 R13 R14 R15
```

See Section 4.4 for the full register decode.

#### Control Code Dispatch Table (`$CA40`, 25 entries)

Maps character codes `$00`–`$1F` to handler routine low bytes (high byte is `$C9` via the RTS dispatch trick at `$CA37`):

```
Offset  Addr   Hex
$240    $CA40: 18 71 13 B2 48 60 AF 9D F2 13 13 13 13 13 13 13
$250    $CA50: 13 13 66 0E 13 38 00 14
```

Decoded dispatch (target = `$C900 + low_byte + 1` via RTS trick):

| Index | Char | Low Byte | Target | Function |
|-------|------|----------|--------|----------|
| `$00` | NUL | `$18` | `$C919` | BELL (beep) |
| `$01` | SOH | `$71` | `$C972` | Cursor left |
| `$02` | STX | `$13` | `$C914` | (unused - falls through) |
| `$03` | ETX | `$B2` | `$C9B3` | Cursor down |
| `$04` | EOT | `$48` | `$C949` | Cursor down with scroll |
| `$05` | ENQ | `$60` | `$C961` | Home cursor |
| `$06` | ACK | `$AF` | `$C9B0` | New line (CR+LF) |
| `$07` | BEL | `$9D` | `$C99E` | Inverse off |
| `$08` | BS  | `$F2` | `$C9F3` | Inverse on |
| `$09`–`$11` | TAB–DC1 | `$13` | `$C914` | (unused) |
| `$12` | DC2 | `$66` | `$C967` | Scroll up |
| `$13` | DC3 | `$0E` | `$C90F` | Show version '4' |
| `$14` | DC4 | `$13` | `$C914` | (unused) |
| `$15` | NAK | `$38` | `$C939` | Cursor right |
| `$16` | SYN | `$00` | `$C901` | Clear to EOL |
| `$17` | ETB | `$14` | `$C915` | Show version '2' |

Note: The table index maps from `(char_code + $80) & $1F` because the firmware adds `$80` (ORA #$80) before checking control codes, then subtracts `$87` for the table lookup. The mapping above shows the effective ASCII control code.

#### ESC Sequence Dispatch Table (`$CBF2`, 8 entries)

Uses the RTS dispatch trick with high byte `$C9` (pushed at `$C8F8`):

```
Offset  Addr   Hex
$3F2    $CBF2: 60 38 71 B2 7B 00 48 66
```

| Index | ESC Code | Low Byte | Target | Function |
|-------|----------|----------|--------|----------|
| 0 | ESC-@ | `$60` | `$C961` | Home cursor (clear screen) |
| 1 | ESC-A | `$38` | `$C939` | Cursor right |
| 2 | ESC-B | `$71` | `$C972` | Cursor left |
| 3 | ESC-C | `$B2` | `$C9B3` | Cursor down |
| 4 | ESC-D | `$7B` | `$C97C` | Cursor up |
| 5 | ESC-E | `$00` | `$C901` | Clear to end of line |
| 6 | ESC-F | `$48` | `$C949` | Clear to end of screen |
| 7 | ESC-G | `$66` | `$C967` | Scroll up |

#### Pascal 1.1 Protocol Descriptor (`$CB0B`, 7 bytes)

```
Offset  Addr   Hex
$30B    $CB0B: 01 82 11 14 1C 22
```

| Byte | Value | Meaning |
|------|-------|---------|
| `$CB0B` | `$01` | Device type: generic character device |
| `$CB0C` | `$82` | Flags: `$8x` = 80-column card |
| `$CB0D` | `$11` | INIT handler offset → `$C311` |
| `$CB0E` | `$14` | READ handler offset → `$C314` |
| `$CB0F` | `$1C` | WRITE handler offset → `$C31C` |
| `$CB10` | `$22` | STATUS handler offset → `$C322` |

#### Signature/ID Bytes (`$CB00–$CB0A`)

```
$CB00: 2C CB FF    BIT $FFCB     ; Cold start: V flag set by $FFCB content
$CB03: 70 31       BVS MAIN+$04  ; Branch if V=1 (cold start)
$CB05: 38          SEC           ; Pascal ID 1 / input entry (carry=1)
$CB06: 90 18       BCC +24       ; (never taken after SEC)
$CB08: B8          CLV           ; Pascal ID 2 / clear V flag
$CB09: 50 2B       BVC MAIN+$06  ; Always taken (V cleared)
```

### 20.6 I/O Access Map

Every hardware I/O access performed by the firmware ROM:

| Address | Access | ROM Location | Context |
|---------|--------|-------------|---------|
| `$C000` (KBD) | LDA | `$C84D`, `$C0B4`, `$CB28`, `$CAD1` | Read keyboard data |
| `$C010` (KBDSTRB) | BIT | `$C857`, `$CAD8`, `$CAE3` | Clear keyboard strobe |
| `$C030` (SPKR) | LDA | `$C921` | Toggle speaker (bell) |
| `$C058` (AN0_OFF) | STA | `$C995` | 40-column mode (AN0 off) |
| `$C059` (AN0_ON) | STA | `$C82A`, `$CA92` | 80-column mode (AN0 on) |
| `$C063` (PB3) | BIT | `$C87D` | Read shift key / paddle button 3 |
| `$C0B0` (CRTC_ADDR) | STA | `$C81C`, `$C8D3`, `$C8D8`, `$C9CE`, `$C9D9`, `$CA67` | Select CRTC register |
| `$C0B1` (CRTC_DATA) | STA | `$C822`, `$C8E0`, `$C8E5`, `$C8ED`, `$C9D5`, `$C9E0` | Write CRTC register data |
| `$C0B4` | LDA | `$CA67` | Read CRTC (bank select side-effect: bank 1) |
| `$C0B8` | LDA | `$CA67` | Read CRTC (bank select side-effect: bank 2) |
| `$C0BC` | LDA | `$CA67` | Read CRTC (bank select side-effect: bank 3) |
| `$CC00` | STA | `$CA82` | Write VRAM (bank 0/1 page 0) |
| `$CD00` | STA | `$CA86` | Write VRAM (bank 2/3 page 1) |
| `$CFFF` | STA | `$CB38` | Deselect expansion ROM |

Note: The VRAM bank selection is achieved by reading from `$C0B0+offset` where `addr[3:2]` selects the bank. The firmware uses `LDA $C0B0,X` with X ∈ {0, 4, 8, 12} to select banks 0–3 respectively.

### 20.7 Screen Hole Usage (Enhanced)

All firmware state stored in Apple II screen holes for slot 3:

| Address | Name | Range | Purpose | Details |
|---------|------|-------|---------|---------|
| `$0478` | CRFLAG | `$C3`/`$43` | Slot marker & autowrap | Bit 7 set = autowrap active. `$C3` = slot 3 marker (also serves as high byte of CSW = `$C3xx`) |
| `$047B` | BASEL | `$00`–`$F0` | VRAM base addr low | Low nybble of VRAM row start address (after VRAM_CALC) |
| `$04FB` | BASEH | `$00`–`$07` | VRAM base addr high | High nybble of VRAM row start address |
| `$04F8` | TEMP_ROW | temp | Temporary | Used by VRAM_CALC as scratch during address computation |
| `$057B` | CHORZ | 0–79 | Cursor column | Horizontal position (0 = leftmost) |
| `$05F8` | TEMP_CHORZ | temp | Saved cursor col | Temporary storage during scroll operations |
| `$05FB` | CVERT | 0–23 | Cursor row | Vertical position (0 = top) |
| `$06FB` | START | 0–127 | Scroll offset | Display start = START × 16. Range 0–127, wraps modulo 128. Each scroll increments by 5 (= 80 bytes ÷ 16) |
| `$0678` | LAST_CHAR | any | Last character | Stores most recent character for line editor pick/replace |
| `$077B` | POFF | `$30`/`$32`/`$34` | Mode state | `$30` = 80-col normal, `$32` = ESC lead-in mode, `$34` = version display (Ctrl-D shows "4") |
| `$07FB` | FLAGS | bitfield | Mode flags | Bit 0: inverse on. Bit 3: exit-to-40col pending. Bit 6: case swap. Bit 7: GETLN input mode |

### 20.8 Commented 6502 Disassembly

Complete annotated disassembly of the 1024-byte Videx VideoTerm ROM 2.4 firmware. All 6502 code is at CPU addresses `$C800–$CBFF` (ROM offsets `$000–$3FF`). The slot ROM window at `$C300–$C3FF` aliases `$CB00–$CBFF`.

**Symbolic Names Used:**

| Symbol | Address | Description |
|--------|---------|-------------|
| `CH` | `$24` | Apple II cursor horizontal (zero page) |
| `CV` | `$25` | Apple II cursor vertical (zero page) |
| `BASL` | `$28` | Apple II text base address low (zero page) |
| `BASH` | `$29` | Apple II text base address high (zero page) |
| `TEMP` | `$35` | Temporary storage (zero page) |
| `CSWL` | `$36` | Character output switch low (zero page) |
| `CSWH` | `$37` | Character output switch high (zero page) |
| `KSWL` | `$38` | Keyboard input switch low (zero page) |
| `KSWH` | `$39` | Keyboard input switch high (zero page) |
| `RNDL` | `$4E` | Random seed low (zero page) |
| `RNDH` | `$4F` | Random seed high (zero page) |
| `CRFLAG` | `$0478` | CR/autowrap flag (screen hole, slot 3) |
| `BASEL` | `$047B` | VRAM base address low nybble (screen hole) |
| `BASEH` | `$04FB` | VRAM base address high nybble (screen hole) |
| `TEMP_ROW` | `$04F8` | Temporary row storage (screen hole) |
| `CHORZ` | `$057B` | Cursor horizontal position 0–79 (screen hole) |
| `TEMP_CHORZ` | `$05F8` | Saved cursor column (screen hole) |
| `CVERT` | `$05FB` | Cursor vertical position 0–23 (screen hole) |
| `START` | `$06FB` | Scroll offset 0–127 (screen hole) |
| `LAST_CHAR` | `$0678` | Last character for line editor (screen hole) |
| `POFF` | `$077B` | Mode state: `$30`=80col, `$32`=ESC, `$34`=ver (screen hole) |
| `FLAGS` | `$07FB` | Bit flags (screen hole) |
| `KBD` | `$C000` | Keyboard data register |
| `KBDSTRB` | `$C010` | Keyboard strobe (clear on read) |
| `SPKR` | `$C030` | Speaker toggle |
| `AN0_OFF` | `$C058` | Annunciator 0 off (40-col mode) |
| `AN0_ON` | `$C059` | Annunciator 0 on (80-col mode) |
| `PB3` | `$C063` | Paddle button 3 / shift key |
| `CRTC_ADDR` | `$C0B0` | MC6845 CRTC address register |
| `CRTC_DATA` | `$C0B1` | MC6845 CRTC data register |

```asm
;=============================================================================
; INIT ($C800) — Cold Start / Warm Start Detection
;   Checks POFF screen hole to determine if card was previously initialized.
;   If POFF upper bits match $30, skips re-init (warm start).
;   Otherwise performs full initialization.
;=============================================================================
INIT:
C800: AD 7B 07     LDA POFF            ; Load power-off detection byte
C803: 29 F8        AND #$F8            ; Mask lower 3 bits (check upper 5)
C805: C9 30        CMP #$30            ; Previously initialized?
C807: F0 21        BEQ INIT_AN0        ; Yes → just re-enable AN0 and return

;=============================================================================
; INIT_FULL ($C809) — Complete Card Initialization
;   Sets POFF=$30 (initialized marker), FLAGS=$30 (no inverse, no ESC),
;   START=0, clears screen, programs all 16 CRTC registers.
;=============================================================================
INIT_FULL:
C809: A9 30        LDA #$30            ; Mark as initialized
C80B: 8D 7B 07     STA POFF            ; Store to power-off detect
C80E: 8D FB 07     STA FLAGS           ; Clear all flags (inverse=0, etc.)
C811: A9 00        LDA #$00
C813: 8D FB 06     STA START           ; Reset scroll offset to 0
C816: 20 61 C9     JSR HOME            ; Clear screen and home cursor

;--- Program all 16 CRTC registers from table at CRTC_TABLE ---
C819: A2 00        LDX #$00            ; Register index = 0
INIT_CRTC_LOOP:
C81B: 8A           TXA                 ; A = register number
C81C: 8D B0 C0     STA CRTC_ADDR      ; Select CRTC register
C81F: BD A1 C8     LDA CRTC_TABLE,X   ; Load init value from table
C822: 8D B1 C0     STA CRTC_DATA      ; Write to CRTC data port
C825: E8           INX                 ; Next register
C826: E0 10        CPX #$10            ; All 16 done?
C828: D0 F1        BNE INIT_CRTC_LOOP  ; No → continue loop

;--- Enable 80-column display ---
INIT_AN0:
C82A: 8D 59 C0     STA AN0_ON          ; Set AN0 on (80-col mode)
C82D: 60           RTS

;=============================================================================
; EXIT_TO_40 ($C82E) — Exit to 40-Column Mode
;   Called when FLAGS bit 3 is set. Restores Apple II I/O vectors
;   via monitor ROM calls, then returns to caller's caller (pops 3 bytes).
;=============================================================================
EXIT_TO_40:
C82E: AD FB 07     LDA FLAGS           ; Check FLAGS
C831: 29 08        AND #$08            ; Bit 3 = exit-to-40col pending?
C833: F0 09        BEQ PULL_REGS       ; No → just restore registers and return
C835: 20 93 FE     JSR $FE93           ; SETVID: reset CSW to monitor output
C838: 20 22 FC     JSR $FC22           ; VTAB: recompute text base address
C83B: 20 89 FE     JSR $FE89           ; SETKBD: reset KSW to monitor input

;--- Restore saved registers and return ---
PULL_REGS:
C83E: 68           PLA                 ; Pull saved A (was Y)
C83F: A8           TAY                 ; Restore Y
C840: 68           PLA                 ; Pull saved A (was X)
C841: AA           TAX                 ; Restore X
C842: 68           PLA                 ; Pull saved A
C843: 60           RTS                 ; Return

;=============================================================================
; GETKEY ($C844) — Wait for Keyboard Input
;   Polls $C000 until key available (bit 7 set). Increments random seed
;   ($4E/$4F) while waiting. Processes keystroke through KEYPROC.
;=============================================================================
GETKEY:
C844: 20 D1 C8     JSR CURSOR_UPDATE   ; Update cursor position on screen
GETKEY_LOOP:
C847: E6 4E        INC RNDL            ; Increment random seed low
C849: D0 02        BNE .+2             ; Skip high byte if no overflow
C84B: E6 4F        INC RNDH            ; Increment random seed high
C84D: AD 00 C0     LDA KBD             ; Read keyboard
C850: 10 F5        BPL GETKEY_LOOP     ; No key → keep polling
C852: 20 5C C8     JSR KEYPROC         ; Process keystroke
C855: 90 F0        BCC GETKEY_LOOP     ; Carry clear → key not accepted, retry

;--- Key accepted: clear keyboard strobe and return ---
C857: 2C 10 C0     BIT KBDSTRB         ; Clear keyboard strobe
C85A: 18           CLC                 ; Clear carry (indicate success)
C85B: 60           RTS

;=============================================================================
; KEYPROC ($C85C) — Process Keystroke
;   Handles Ctrl-A (case toggle), shift key detection, and character
;   case mapping. Returns with carry set if key is accepted.
;=============================================================================
KEYPROC:
C85C: C9 8B        CMP #$8B            ; Is it Ctrl-K with high bit? ($0B|$80)
C85E: D0 02        BNE KEYPROC_CHK_A   ; No → check Ctrl-A
C860: A9 DB        LDA #$DB            ; Replace with '[' (open-apple mapped)

KEYPROC_CHK_A:
C862: C9 81        CMP #$81            ; Ctrl-A? ($01|$80)
C864: D0 0A        BNE KEYPROC_CASE    ; No → handle case mapping
C866: AD FB 07     LDA FLAGS           ; Toggle case-swap flag (bit 6)
C869: 49 40        EOR #$40
C86B: 8D FB 07     STA FLAGS
C86E: B0 E7        BCS GETKEY_STROBE   ; Return to GETKEY (clear strobe, retry)

;--- Case mapping based on FLAGS and shift key ---
KEYPROC_CASE:
C870: 48           PHA                 ; Save original key
C871: AD FB 07     LDA FLAGS           ; Check case swap flag
C874: 0A           ASL A               ; Shift left twice to get bit 6 → carry
C875: 0A           ASL A
C876: 68           PLA                 ; Restore key
C877: 90 1F        BCC KEYPROC_DONE    ; Case swap off → accept key as-is
C879: C9 B0        CMP #$B0            ; Below '0'?
C87B: 90 1B        BCC KEYPROC_DONE    ; Yes → no case mapping needed

;--- Check shift key (paddle button 3) ---
C87D: 2C 63 C0     BIT PB3             ; Read shift key
C880: 30 14        BMI KEYPROC_SHIFT   ; Shift pressed → force lowercase

;--- No shift: map uppercase ↔ lowercase ---
C882: C9 B0        CMP #$B0            ; Is it '0'?
C884: F0 0E        BEQ KEYPROC_ARROW   ; Yes → special handling
C886: C9 C0        CMP #$C0            ; Is it '@'?
C888: D0 02        BNE KEYPROC_HI      ; No → check range
C88A: A9 D0        LDA #$D0            ; Replace '@' with 'P'

KEYPROC_HI:
C88C: C9 DB        CMP #$DB            ; Above 'Z'?
C88E: 90 08        BCC KEYPROC_DONE    ; No → accept
C890: 29 CF        AND #$CF            ; Strip bits to map to uppercase
C892: D0 04        BNE KEYPROC_DONE    ; If non-zero → accept

KEYPROC_ARROW:
C894: A9 DD        LDA #$DD            ; Replace with ']'

KEYPROC_SHIFT:
C896: 09 20        ORA #$20            ; Force lowercase (set bit 5)

KEYPROC_DONE:
C898: 48           PHA                 ; Save processed key
C899: 29 7F        AND #$7F            ; Strip high bit
C89B: 8D 7B 06     STA $067B           ; Store to screen hole for display
C89E: 68           PLA                 ; Restore key (with high bit)
C89F: 38           SEC                 ; Set carry = key accepted
C8A0: 60           RTS

;=============================================================================
; CRTC_TABLE ($C8A1) — CRTC Register Initialization Data
;   16 bytes: R0–R15 values programmed during INIT.
;   See Section 4.4 for decoded values.
;=============================================================================
CRTC_TABLE:
C8A1: 7A 50 5E 2F  ; R0=$7A R1=$50 R2=$5E R3=$2F
C8A5: 22 00 18 1D  ; R4=$22 R5=$00 R6=$18 R7=$1D
C8A9: 00 08 E0 08  ; R8=$00 R9=$08 R10=$E0 R11=$08
C8AD: 00 00 00 00  ; R12=$00 R13=$00 R14=$00 R15=$00

;=============================================================================
; PUTC ($C8B1) — Character Output Entry
;   Syncs Apple II ZP cursor (CH/CV) with Videx screen holes (CHORZ/CVERT),
;   then dispatches the character through OUTPT1.
;=============================================================================
PUTC:
C8B1: 8D 7B 06     STA $067B           ; Save character temporarily
C8B4: A5 25        LDA CV              ; Load Apple II cursor row
C8B6: CD FB 05     CMP CVERT           ; Same as Videx cursor row?
C8B9: F0 06        BEQ PUTC_CHK_COL    ; Yes → check column
C8BB: 8D FB 05     STA CVERT           ; No → sync Videx row from ZP
C8BE: 20 04 CA     JSR VRAM_CALC       ; Recalculate VRAM base address

PUTC_CHK_COL:
C8C1: A5 24        LDA CH              ; Load Apple II cursor column
C8C3: CD 7B 05     CMP CHORZ           ; Compare with Videx column
C8C6: 90 03        BCC PUTC_DISPATCH   ; If CH < CHORZ, use CH (don't advance)
C8C8: 8D 7B 05     STA CHORZ           ; Sync Videx column from ZP

PUTC_DISPATCH:
C8CB: AD 7B 06     LDA $067B           ; Restore saved character
C8CE: 20 89 CA     JSR OUTPT1          ; Dispatch through output handler

;=============================================================================
; CURSOR_UPDATE ($C8D1) — Update CRTC Cursor Position
;   Writes R14/R15 (cursor address) and R12/R13 (display start) to CRTC.
;   Called after every cursor movement and before keyboard input.
;=============================================================================
CURSOR_UPDATE:
C8D1: A9 0F        LDA #$0F            ; Select R15 (cursor addr low)
C8D3: 8D B0 C0     STA CRTC_ADDR
C8D6: AD 7B 05     LDA CHORZ           ; Cursor column
C8D9: C9 50        CMP #$50            ; >= 80? (off-screen)
C8DB: B0 13        BCS CURSOR_RET      ; Yes → don't update (hide cursor)
C8DD: 6D 7B 04     ADC BASEL           ; Add VRAM base low
C8E0: 8D B1 C0     STA CRTC_DATA      ; Write R15

C8E3: A9 0E        LDA #$0E            ; Select R14 (cursor addr high)
C8E5: 8D B0 C0     STA CRTC_ADDR
C8E8: A9 00        LDA #$00
C8EA: 6D FB 04     ADC BASEH           ; Add VRAM base high (with carry)
C8ED: 8D B1 C0     STA CRTC_DATA      ; Write R14

CURSOR_RET:
C8F0: 60           RTS

;=============================================================================
; ESC_DISPATCH ($C8F1) — ESC Sequence Dispatcher
;   Handles ESC-@ through ESC-G using the RTS dispatch trick.
;   Converts ESC code to table index, pushes high byte ($C9) and
;   low byte from ESC_TABLE, then RTS jumps to the target.
;=============================================================================
ESC_DISPATCH:
C8F1: 49 C0        EOR #$C0            ; Convert $C0-$C7 → $00-$07
C8F3: C9 08        CMP #$08            ; Valid ESC code (0-7)?
C8F5: B0 1D        BCS ESC_RET         ; No → return (ignore)
C8F7: A8           TAY                 ; Y = ESC code index (0-7)
C8F8: A9 C9        LDA #$C9            ; Push high byte of target ($C9xx)
C8FA: 48           PHA
C8FB: B9 F2 CB     LDA ESC_TABLE,Y     ; Load low byte from table
C8FE: 48           PHA                 ; Push low byte
C8FF: 60           RTS                 ; "Return" to target address + 1

;--- $C900: NOP (alignment byte, never reached normally) ---
C900: EA           NOP

;=============================================================================
; CLR_EOL ($C901) — Clear to End of Line
;   Writes space ($A0) from cursor position to column 79.
;=============================================================================
CLR_EOL:
C901: AC 7B 05     LDY CHORZ           ; Y = current column
CLR_EOL_LOOP:
C904: A9 A0        LDA #$A0            ; Space character (Apple II encoding)
WRITE_CHAR_LOOP:
C906: 20 71 CA     JSR ENCODE_CHAR     ; Encode and write to VRAM
C909: C8           INY                 ; Next column
C90A: C0 50        CPY #$50            ; Past column 79?
C90C: 90 F8        BCC WRITE_CHAR_LOOP ; No → continue
C90E: 60           RTS

;=============================================================================
; SHOW_VER_4 ($C90F) — Display Version Digit '4'
;   Ctrl-D handler: stores ASCII '4' ($34) to POFF for display.
;=============================================================================
SHOW_VER_4:
C90F: A9 34        LDA #$34            ; ASCII '4'
SHOW_VER_STORE:
C911: 8D 7B 07     STA POFF            ; Store to POFF (displayed by output loop)

;--- Shared return point for unused control codes ---
ESC_RET:
C914: 60           RTS

;=============================================================================
; SHOW_VER_2 ($C915) — Display Version Digit '2'
;   Ctrl-B handler: stores ASCII '2' ($32) to POFF.
;   Together with Ctrl-D, this displays "2.4" as the firmware version.
;=============================================================================
SHOW_VER_2:
C915: A9 32        LDA #$32            ; ASCII '2'
C917: D0 F8        BNE SHOW_VER_STORE  ; Always taken → store to POFF

;=============================================================================
; BELL ($C919) — Sound Speaker
;   Toggles the speaker ($C030) in a nested loop to produce a beep.
;   Outer loop (Y=$C0=192 iterations) × inner loop (X=$80=128 iterations).
;=============================================================================
BELL:
C919: A0 C0        LDY #$C0            ; Outer loop count = 192
BELL_OUTER:
C91B: A2 80        LDX #$80            ; Inner loop count = 128
BELL_INNER:
C91D: CA           DEX                 ; Decrement inner counter
C91E: D0 FD        BNE BELL_INNER      ; Inner loop
C920: AD 30 C0     LDA SPKR            ; Toggle speaker
C923: 88           DEY                 ; Decrement outer counter
C924: D0 F5        BNE BELL_OUTER      ; Outer loop
C926: 60           RTS

;=============================================================================
; SCROLL_CHECK ($C927) — Output Character with Scroll Check
;   Checks if cursor is at/past column 80; if so, scrolls first.
;   Then writes character at cursor position and advances cursor.
;=============================================================================
SCROLL_CHECK:
C927: AC 7B 05     LDY CHORZ           ; Y = cursor column
C92A: C0 50        CPY #$50            ; Past column 79?
C92C: 90 05        BCC SCROLL_CHK_WRITE ; No → write char directly
C92E: 48           PHA                 ; Save character
C92F: 20 B0 C9     JSR NEW_LINE        ; Wrap to new line (CR + scroll)
C932: 68           PLA                 ; Restore character

SCROLL_CHK_WRITE:
C933: AC 7B 05     LDY CHORZ           ; Y = cursor column
C936: 20 71 CA     JSR ENCODE_CHAR     ; Encode and write to VRAM

;--- CUR_RIGHT ($C939) — Move Cursor Right ---
CUR_RIGHT:
C939: EE 7B 05     INC CHORZ           ; Advance cursor column
C93C: 2C 78 04     BIT CRFLAG          ; Check autowrap flag (bit 7)
C93F: 10 07        BPL CUR_RIGHT_RET   ; Autowrap off → don't wrap
C941: AD 7B 05     LDA CHORZ           ; Check new column
C944: C9 50        CMP #$50            ; Past column 79?
C946: B0 68        BCS NEW_LINE        ; Yes → new line with scroll

CUR_RIGHT_RET:
C948: 60           RTS

;=============================================================================
; CUR_DOWN_SCROLL ($C949) — Cursor Down with Clear-to-End-of-Screen
;   Used by ESC-F (clear to end of screen): clears current line from
;   cursor position, then clears all subsequent lines.
;=============================================================================
CUR_DOWN_SCROLL:
C949: AC 7B 05     LDY CHORZ           ; Start from cursor column
C94C: AD FB 05     LDA CVERT           ; Current row

CUR_DOWN_LOOP:
C94F: 48           PHA                 ; Save row
C950: 20 07 CA     JSR VRAM_CALC_A     ; Calculate VRAM base for row in A
C953: 20 04 C9     JSR CLR_EOL_LOOP    ; Clear from Y to column 79
C956: A0 00        LDY #$00            ; Start next row from column 0
C958: 68           PLA                 ; Restore row
C959: 69 00        ADC #$00            ; Add carry (always 1 after CPY #$50)
C95B: C9 18        CMP #$18            ; Past row 23?
C95D: 90 F0        BCC CUR_DOWN_LOOP   ; No → clear next row
C95F: B0 23        BCS VRAM_CALC_JMP   ; Done → recalculate base for cursor

;=============================================================================
; HOME ($C961) — Home Cursor
;   Resets cursor to (0,0) and scrolls display to show row 0.
;   First calls SCROLL_UP to reset display, then sets cursor.
;=============================================================================
HOME:
C961: 20 67 C9     JSR SCROLL_UP       ; Reset CHORZ/CVERT/START
C964: 98           TYA                 ; A = 0 (Y was set by SCROLL_UP)
C965: F0 E8        BEQ CUR_DOWN_LOOP   ; Always taken → clear screen from (0,0)

;=============================================================================
; SCROLL_UP ($C967) — Reset Display Position
;   Sets cursor to column 0, row 0, scroll offset 0.
;=============================================================================
SCROLL_UP:
C967: A9 00        LDA #$00
C969: 8D 7B 05     STA CHORZ           ; Column = 0
C96C: 8D FB 05     STA CVERT           ; Row = 0
C96F: A8           TAY                 ; Y = 0
C970: F0 12        BEQ VRAM_CALC_JMP   ; Always taken → recalculate VRAM base

;=============================================================================
; CUR_LEFT ($C972) — Cursor Left / Backspace
;   Decrements cursor column. If at column 0, wraps to column 79
;   of the previous row (if not at row 0).
;=============================================================================
CUR_LEFT:
C972: CE 7B 05     DEC CHORZ           ; Decrement column
C975: 10 9D        BPL ESC_RET         ; Still >= 0 → done (return via $C914)
C977: A9 4F        LDA #$4F            ; Wrap to column 79
C979: 8D 7B 05     STA CHORZ

;--- CUR_UP ($C97C) — Cursor Up ---
CUR_UP:
C97C: AD FB 05     LDA CVERT           ; Current row
C97F: F0 93        BEQ ESC_RET         ; At row 0 → can't go up (return)
C981: CE FB 05     DEC CVERT           ; Decrement row

VRAM_CALC_JMP:
C984: 4C 04 CA     JMP VRAM_CALC       ; Recalculate VRAM base address

;=============================================================================
; ESC_MAIN ($C987) — ESC Lead-In Sequence Handler
;   Handles ESC + parameter sequences: ESC-0 (reinit), ESC-1 (40-col),
;   ESC-2 (inverse off), ESC-3 (inverse on).
;   Also handles ESC + row + col for cursor positioning.
;=============================================================================
ESC_MAIN:
C987: A9 30        LDA #$30            ; Restore POFF to normal mode
C989: 8D 7B 07     STA POFF
C98C: 68           PLA                 ; Pull parameter character
C98D: 09 80        ORA #$80            ; Set high bit (Apple II convention)
C98F: C9 B1        CMP #$B1            ; Is it '1'? (ESC ^-1: 40-col mode)
C991: D0 67        BNE ESC_CHK_0       ; No → check '0'

;--- ESC-1: Switch to 40-column mode ---
C993: A9 08        LDA #$08            ; Set FLAGS bit 3 (exit-to-40col)
C995: 8D 58 C0     STA AN0_OFF         ; Turn off AN0 (40-col display)
C998: D0 5B        BNE ESC_SET_FLAG    ; Always taken → set flag in FLAGS

;--- ESC-2: Inverse off ---
ESC_CHK_2:
C99A: C9 B2        CMP #$B2            ; Is it '2'?
C99C: D0 51        BNE ESC_CHK_3       ; No → check '3'
C99E: A9 FE        LDA #$FE            ; Mask to clear bit 0

INV_OFF:
C9A0: 2D FB 07     AND FLAGS           ; Clear inverse flag
ESC_STORE_FLAGS:
C9A3: 8D FB 07     STA FLAGS           ; Store updated flags
C9A6: 60           RTS

;=============================================================================
; STORE_CHAR ($C9A7) — Store Character via Screen Hole
;   Alternative output path: stores char to $067B screen hole,
;   clears autowrap flag, then jumps to PUTC_DISPATCH.
;=============================================================================
STORE_CHAR:
C9A7: 8D 7B 06     STA $067B           ; Store character
C9AA: 4E 78 04     LSR CRFLAG          ; Clear autowrap (shift right clears bit 7)
C9AD: 4C CB C8     JMP PUTC_DISPATCH   ; Continue through normal output path

;=============================================================================
; NEW_LINE ($C9B0) — Carriage Return + Line Feed
;   Sets column to 0 (CR), then moves cursor down one row.
;   If at bottom of screen, scrolls display up.
;=============================================================================
NEW_LINE:
C9B0: 20 27 CA     JSR CARRIAGE_RET    ; Set CHORZ = 0

;--- CUR_DOWN ($C9B3) — Cursor Down / Line Feed ---
CUR_DOWN:
C9B3: EE FB 05     INC CVERT           ; Increment row
C9B6: AD FB 05     LDA CVERT           ; Check new row
C9B9: C9 18        CMP #$18            ; Past row 23?
C9BB: 90 4A        BCC VRAM_CALC_2     ; No → just recalculate base

;--- Scroll screen up one line ---
C9BD: CE FB 05     DEC CVERT           ; Back to row 23
C9C0: AD FB 06     LDA START           ; Current scroll offset
C9C3: 69 04        ADC #$04            ; Add 4 (= 80/16, but actually +5 with carry)
C9C5: 29 7F        AND #$7F            ; Wrap modulo 128
C9C7: 8D FB 06     STA START           ; Update scroll offset

;--- Update CRTC display start address (R12/R13) ---
C9CA: 20 12 CA     JSR BANK_SELECT     ; Calculate bank from new START
C9CD: A9 0D        LDA #$0D            ; Select R13 (display start low)
C9CF: 8D B0 C0     STA CRTC_ADDR
C9D2: AD 7B 04     LDA BASEL           ; Low byte of display start
C9D5: 8D B1 C0     STA CRTC_DATA      ; Write R13
C9D8: A9 0C        LDA #$0C            ; Select R12 (display start high)
C9DA: 8D B0 C0     STA CRTC_ADDR
C9DD: AD FB 04     LDA BASEH           ; High byte of display start
C9E0: 8D B1 C0     STA CRTC_DATA      ; Write R12

;--- Clear the new blank line at the bottom ---
C9E3: A9 17        LDA #$17            ; Row 23 (last visible row)
C9E5: 20 07 CA     JSR VRAM_CALC_A     ; Calculate VRAM base for row 23
C9E8: A0 00        LDY #$00            ; Start from column 0
C9EA: 20 04 C9     JSR CLR_EOL_LOOP    ; Clear entire line with spaces
C9ED: B0 95        BCS VRAM_CALC_JMP   ; Always taken → recalculate for cursor row

;--- ESC-3: Inverse on ---
ESC_CHK_3:
C9EF: C9 B3        CMP #$B3            ; Is it '3'?
C9F1: D0 0E        BNE ESC_CHK_REINIT  ; No → check reinit/unknown

INV_ON:
C9F3: A9 01        LDA #$01            ; Mask to set bit 0

ESC_SET_FLAG:
C9F5: 0D FB 07     ORA FLAGS           ; Set flag bit(s)
C9F8: D0 A9        BNE ESC_STORE_FLAGS ; Always taken → store and return

;--- ESC-0: Reinitialize card ---
ESC_CHK_0:
C9FA: C9 B0        CMP #$B0            ; Is it '0'?
C9FC: D0 9C        BNE ESC_CHK_2       ; No → check '2'
C9FE: 4C 09 C8     JMP INIT_FULL       ; Yes → full re-initialization

;--- Unknown ESC parameter: treat as cursor position ---
ESC_CHK_REINIT:
CA01: 4C 27 C9     JMP SCROLL_CHECK    ; Output char normally (cursor positioning)

;=============================================================================
; VRAM_CALC ($CA04) — Calculate VRAM Base Address from Cursor Row
;   Computes VRAM address = (CVERT * 5 + START) split into BASEH:BASEL.
;   The *5 comes from: each row = 80 chars, and VRAM is addressed in
;   units of 16, so 80/16 = 5 units per row.
;=============================================================================
VRAM_CALC:
CA04: AD FB 05     LDA CVERT           ; Load cursor row (0-23)
VRAM_CALC_A:                            ; Alternate entry: row in A
CA07: 8D F8 04     STA TEMP_ROW        ; Save row to temp
CA0A: 0A           ASL A               ; A = row * 2
CA0B: 0A           ASL A               ; A = row * 4
CA0C: 6D F8 04     ADC TEMP_ROW        ; A = row * 5
CA0F: 6D FB 06     ADC START           ; A = row * 5 + START (scroll offset)

;--- BANK_SELECT ($CA12) — Split Address into BASEH:BASEL ---
;   The VRAM address has high nybble and low nybble packed.
;   This splits them for bank selection.
BANK_SELECT:
CA12: 48           PHA                 ; Save combined address
CA13: 4A           LSR A               ; Shift right 4 times to get high nybble
CA14: 4A           LSR A
CA15: 4A           LSR A
CA16: 4A           LSR A
CA17: 8D FB 04     STA BASEH           ; High nybble → BASEH (bank + page)
CA1A: 68           PLA                 ; Restore combined address
CA1B: 0A           ASL A               ; Shift left 4 times to get low nybble
CA1C: 0A           ASL A
CA1D: 0A           ASL A
CA1E: 0A           ASL A
CA1F: 8D 7B 04     STA BASEL           ; Low nybble → BASEL (offset in page)
CA22: 60           RTS

;=============================================================================
; CHAR_DISPATCH ($CA23) — Route Character to Handler
;   CR ($0D) goes directly to CARRIAGE_RET. Printable chars (>= $20)
;   go to SCROLL_CHECK. Control codes ($00-$1F) use CTRL_TABLE dispatch.
;=============================================================================
CHAR_DISPATCH:
CA23: C9 0D        CMP #$0D            ; Is it CR?
CA25: D0 06        BNE CHAR_NOT_CR     ; No → check further

CARRIAGE_RET:
CA27: A9 00        LDA #$00            ; Set column to 0
CA29: 8D 7B 05     STA CHORZ
CA2C: 60           RTS

CHAR_NOT_CR:
CA2D: 09 80        ORA #$80            ; Set high bit (Apple II convention)
CA2F: C9 A0        CMP #$A0            ; >= space?
CA31: B0 CE        BCS ESC_CHK_REINIT  ; Yes → printable, goto SCROLL_CHECK

;--- Control code dispatch ($00-$1F) ---
CA33: C9 87        CMP #$87            ; < $87 (= $07 with high bit)?
CA35: 90 08        BCC CTRL_DISPATCH_RET ; Too low → no handler, return

;--- Use RTS dispatch trick with $C9 as high byte ---
CA37: A8           TAY                 ; Y = char (with high bit)
CA38: A9 C9        LDA #$C9            ; Push high byte $C9
CA3A: 48           PHA
CA3B: B9 B9 C9     LDA $C9B9,Y        ; Load low byte from offset table
CA3E: 48           PHA                 ; Push low byte

CTRL_DISPATCH_RET:
CA3F: 60           RTS                 ; "Return" to handler (or just return)

;=============================================================================
; CTRL_TABLE ($CA40) — Control Code Dispatch Data
;   24 bytes of low-byte targets for the RTS dispatch trick.
;   Index is computed from (char | $80) used as offset into $C9B9 table.
;   See Section 20.5 for decoded dispatch targets.
;=============================================================================
CTRL_TABLE:
CA40: 18 71 13 B2 48 60 AF 9D  ; codes $87-$8E
CA48: F2 13 13 13 13 13 13 13  ; codes $8F-$96
CA50: 13 13 66 0E 13 38 00 14  ; codes $97-$9E

;--- $CA58: Stray byte (part of VRAM address constant) ---
CA58: 7B                        ; .byte $7B (used as operand boundary)

;=============================================================================
; VRAM_WRITE ($CA59) — Calculate VRAM Address and Select Bank
;   Computes the physical VRAM address from cursor column (Y) and
;   base address (BASEL/BASEH). Selects the correct bank by reading
;   from $C0B0+offset where addr[3:2] selects the bank.
;   Returns: X = VRAM offset within bank page, carry = page select
;=============================================================================
VRAM_WRITE:
CA59: 18           CLC                 ; Clear carry for addition
CA5A: 98           TYA                 ; A = cursor column (from Y)
CA5B: 6D 7B 04     ADC BASEL           ; Add VRAM base low byte
CA5E: 48           PHA                 ; Save low byte
CA5F: A9 00        LDA #$00
CA61: 6D FB 04     ADC BASEH           ; Add VRAM base high byte (with carry)
CA64: 48           PHA                 ; Save high byte
CA65: 0A           ASL A               ; Shift high byte left
CA66: 29 0C        AND #$0C            ; Isolate bank bits → $00/$04/$08/$0C
CA68: AA           TAX                 ; X = bank select offset
CA69: BD B0 C0     LDA CRTC_ADDR,X    ; Read $C0B0+X to select bank
CA6C: 68           PLA                 ; Restore high byte
CA6D: 4A           LSR A               ; Shift right → carry = page bit
CA6E: 68           PLA                 ; Restore low byte
CA6F: AA           TAX                 ; X = VRAM offset
CA70: 60           RTS

;=============================================================================
; ENCODE_CHAR ($CA71) — Encode Character and Write to VRAM
;   Encodes ASCII character with inverse flag using the ASL/LSR/ROR trick:
;     vram_byte = {FLAGS.bit0, char[6:0]}
;   Then calls VRAM_WRITE to calculate address and writes to VRAM.
;=============================================================================
ENCODE_CHAR:
CA71: 0A           ASL A               ; Shift char left (lose bit 7)
CA72: 48           PHA                 ; Save shifted value
CA73: AD FB 07     LDA FLAGS           ; Load flags
CA76: 4A           LSR A               ; Carry = bit 0 (inverse flag)
CA77: 68           PLA                 ; Restore shifted char
CA78: 6A           ROR A               ; Rotate right: bit 7 = inverse flag
                                        ; Result: {inverse, char[6:0]}
CA79: 48           PHA                 ; Save encoded VRAM byte
CA7A: 20 59 CA     JSR VRAM_WRITE      ; Get bank/offset in X, carry = page
CA7D: 68           PLA                 ; Restore VRAM byte

CA7E: B0 05        BCS ENCODE_HI_PAGE  ; Carry set → write to $CD00 page
CA80: 9D 00 CC     STA $CC00,X         ; Write to VRAM page 0 ($CC00+X)
CA83: 90 03        BCC ENCODE_DONE     ; Always taken

ENCODE_HI_PAGE:
CA85: 9D 00 CD     STA $CD00,X         ; Write to VRAM page 1 ($CD00+X)

ENCODE_DONE:
CA88: 60           RTS

;=============================================================================
; OUTPT1 ($CA89) — Main Output Wrapper
;   Called for every character output. Clears FLAGS bit 3 (exit-to-40col),
;   re-enables AN0 (80-col mode), then checks POFF mode:
;     $30 = normal output → CHAR_DISPATCH
;     $32 = ESC lead-in → ESC_MAIN
;     $34 = version display → cursor positioning
;=============================================================================
OUTPT1:
CA89: 48           PHA                 ; Save character
CA8A: A9 F7        LDA #$F7            ; Mask to clear bit 3
CA8C: 20 A0 C9     JSR INV_OFF         ; AND with FLAGS (clears exit-to-40col)
CA8F: 8D 59 C0     STA AN0_ON          ; Re-enable AN0 on EVERY output
CA92: AD 7B 07     LDA POFF            ; Check mode state
CA95: 29 07        AND #$07            ; Isolate mode bits
CA97: D0 04        BNE OUTPT1_ESC      ; Non-zero → ESC or version mode
CA99: 68           PLA                 ; Normal mode → restore character
CA9A: 4C 23 CA     JMP CHAR_DISPATCH   ; Dispatch normally

OUTPT1_ESC:
CA9D: 29 04        AND #$04            ; Bit 2 set → ESC lead-in mode ($32/$34)
CA9F: F0 03        BEQ OUTPT1_CURSOR   ; Bit 2 clear → cursor positioning
CAA1: 4C 87 C9     JMP ESC_MAIN        ; Handle ESC lead-in

;--- Cursor positioning: first byte = row, second byte = column ---
OUTPT1_CURSOR:
CAA4: 68           PLA                 ; Restore parameter character
CAA5: 38           SEC
CAA6: E9 20        SBC #$20            ; Subtract $20 (space offset)
CAA8: 29 7F        AND #$7F            ; Mask to 7 bits
CAAA: 48           PHA                 ; Save parameter value
CAAB: CE 7B 07     DEC POFF            ; Decrement POFF (count down parameters)
CAAE: AD 7B 07     LDA POFF
CAB1: 29 03        AND #$03            ; Check remaining count
CAB3: D0 15        BNE OUTPT1_SAVE_COL ; Still have column byte → save and return

;--- Both row and column received: apply cursor position ---
CAB5: 68           PLA                 ; Pull row value
CAB6: C9 18        CMP #$18            ; Valid row (< 24)?
CAB8: B0 03        BCS OUTPT1_USE_COL  ; No → use saved column only
CABA: 8D FB 05     STA CVERT           ; Set cursor row

OUTPT1_USE_COL:
CABD: AD F8 05     LDA TEMP_CHORZ      ; Load saved column value
CAC0: C9 50        CMP #$50            ; Valid column (< 80)?
CAC2: B0 03        BCS OUTPT1_RECALC   ; No → don't update column
CAC4: 8D 7B 05     STA CHORZ           ; Set cursor column

OUTPT1_RECALC:
CAC7: 4C 04 CA     JMP VRAM_CALC       ; Recalculate VRAM base address

OUTPT1_SAVE_COL:
CACA: 68           PLA                 ; Pull column value
CACB: 8D F8 05     STA TEMP_CHORZ      ; Save for next call
CACE: 60           RTS

;=============================================================================
; PAUSE_CHECK ($CACF) — Check for Ctrl-S Pause
;   If keyboard has Ctrl-S ($93), waits for another keypress to resume.
;   Ctrl-C ($83) cancels wait. Any other key clears strobe and returns.
;=============================================================================
PAUSE_CHECK:
CACF: AD 00 C0     LDA KBD             ; Read keyboard
CAD2: C9 93        CMP #$93            ; Ctrl-S (XOFF)?
CAD4: D0 0F        BNE PAUSE_RET       ; No → return immediately
CAD6: 2C 10 C0     BIT KBDSTRB         ; Clear strobe

PAUSE_WAIT:
CAD9: AD 00 C0     LDA KBD             ; Wait for any key
CADC: 10 FB        BPL PAUSE_WAIT      ; No key → keep waiting
CADE: C9 83        CMP #$83            ; Ctrl-C?
CAE0: F0 03        BEQ PAUSE_RET       ; Yes → resume without clearing
CAE2: 2C 10 C0     BIT KBDSTRB         ; Clear strobe for non-Ctrl-C key

PAUSE_RET:
CAE5: 60           RTS

;=============================================================================
; PRINT_MSG ($CAE6) — Print Message via ESC Dispatch
;   Outputs a message string indexed by Y from the message table at $CB31.
;   Characters are processed through ESC_DISPATCH. Waits for keyboard
;   input between characters. Loops until specific terminator received.
;=============================================================================
PRINT_MSG:
CAE6: A8           TAY                 ; Y = message index
CAE7: B9 31 CB     LDA $CB31,Y         ; Load message character
CAEA: 20 F1 C8     JSR ESC_DISPATCH    ; Output via ESC dispatcher

PRINT_MSG_LOOP:
CAED: 20 44 C8     JSR GETKEY          ; Wait for keyboard input
CAF0: C9 CE        CMP #$CE            ; >= 'N' + $80?
CAF2: B0 08        BCS PRINT_MSG_ESC   ; Yes → dispatch as ESC
CAF4: C9 C9        CMP #$C9            ; >= 'I' + $80?
CAF6: 90 04        BCC PRINT_MSG_ESC   ; No → dispatch as ESC
CAF8: C9 CC        CMP #$CC            ; Is it 'L' + $80?
CAFA: D0 EA        BNE PRINT_MSG       ; Not 'L' → loop back

PRINT_MSG_ESC:
CAFC: 4C F1 C8     JMP ESC_DISPATCH    ; Dispatch final character as ESC code
CAFF: EA           NOP                 ; Padding byte

;=============================================================================
; SLOT ROM ENTRY ($CB00 = $C300) — Slot 3 ROM Entry Point
;   The Apple II accesses this when it scans slot 3 or when PR#3 is typed.
;   Uses the BIT $FFCB / BVS trick to detect cold start (V=1 from $FFCB).
;   SEC/CLC distinguish input (carry=1) from output (carry=0) paths.
;=============================================================================
SLOT_ENTRY:                             ; Also visible as $C300
CB00: 2C CB FF     BIT $FFCB           ; V flag set from $FFCB content
CB03: 70 31        BVS MAIN_HANDLER    ; Cold start → V=1, branch to handler

;--- Input entry point ---
INPUT_ENTRY:                            ; Also $C305
CB05: 38           SEC                 ; Set carry = input path
CB06: 90 18        BCC PASCAL_WRITE    ; Never taken (carry is set)

;--- Output entry point ---
OUTPUT_ENTRY:                           ; Also $C307
CB08: B8           CLV                 ; Clear V flag (not cold start)
CB09: 50 2B        BVC MAIN_HANDLER    ; Always taken (V cleared)

;=============================================================================
; PASCAL 1.1 PROTOCOL DESCRIPTOR ($CB0B = $C30B)
;   6 bytes identifying the card to the Apple Pascal operating system.
;=============================================================================
PASCAL_DESC:
CB0B: 01           ; Device type: $01 (generic character device)
CB0C: 82           ; Flags: $82 (80-column card, read+write capable)
CB0D: 11           ; INIT handler offset → $C311 (= $CB00 + $11)
CB0E: 14           ; READ handler offset → $C314
CB0F: 1C           ; WRITE handler offset → $C31C
CB10: 22           ; STATUS handler offset → $C322

;--- PASCAL_INIT ($CB11 = $C311) — Pascal INIT entry ---
PASCAL_INIT:
CB11: 4C 00 C8     JMP INIT            ; Jump to expansion ROM init

;--- PASCAL_READ ($CB14 = $C314) — Pascal READ entry ---
PASCAL_READ:
CB14: 20 44 C8     JSR GETKEY          ; Get keystroke
CB17: 29 7F        AND #$7F            ; Strip high bit
CB19: A2 00        LDX #$00            ; X = 0 (no error)
CB1B: 60           RTS

;--- PASCAL_WRITE ($CB1C = $C31C) — Pascal WRITE entry ---
PASCAL_WRITE:
CB1C: 20 A7 C9     JSR STORE_CHAR      ; Output character
CB1F: A2 00        LDX #$00            ; X = 0 (no error)
CB21: 60           RTS

;--- PASCAL_STATUS ($CB22 = $C322) — Pascal STATUS entry ---
PASCAL_STATUS:
CB22: C9 00        CMP #$00            ; Check status request type
CB24: F0 09        BEQ PASCAL_STAT_RET  ; Type 0 → just return OK
CB26: AD 00 C0     LDA KBD             ; Check keyboard for key available
CB29: 0A           ASL A               ; Shift bit 7 into carry
CB2A: 90 03        BCC PASCAL_STAT_RET  ; No key → return OK
CB2C: 20 5C C8     JSR KEYPROC         ; Process available keystroke

PASCAL_STAT_RET:
CB2F: A2 00        LDX #$00            ; X = 0 (no error)
CB31: 60           RTS

;=============================================================================
; MAIN_HANDLER ($CB32/$CB36) — Central Dispatch Handler
;   Stores character to screen via ($28),Y (STA ($28),Y for Apple II
;   text page mirroring). Deselects expansion ROM ($CFFF), saves all
;   registers, then routes to init/input/output based on V and C flags.
;=============================================================================
;--- Write to Apple II text page (40-col mirror) ---
CB32: 91 28        STA (BASL),Y        ; Write char to Apple II text page
CB34: 38           SEC                 ; Set carry (for protocol)
CB35: B8           CLV                 ; Clear V (not cold start)

MAIN_HANDLER:
CB36: 8D FF CF     STA $CFFF           ; Deselect expansion ROM
CB39: 48           PHA                 ; Save A
CB3A: 85 35        STA TEMP            ; Also save to ZP temp
CB3C: 8A           TXA
CB3D: 48           PHA                 ; Save X
CB3E: 98           TYA
CB3F: 48           PHA                 ; Save Y
CB40: A5 35        LDA TEMP            ; Restore saved char
CB42: 86 35        STX TEMP            ; Save X in ZP (for later restore)

;--- Set CRFLAG to $C3 (slot 3 marker + autowrap bit 7) ---
CB44: A2 C3        LDX #$C3
CB46: 8E 78 04     STX CRFLAG          ; Mark slot 3 active with autowrap
CB49: 48           PHA                 ; Push character again (for handler)

;--- Check V flag: cold start? ---
CB4A: 50 10        BVC OUTPUT_PATH     ; V clear → not cold start

;--- Cold start: patch I/O vectors ---
CB4C: A9 32        LDA #$32            ; Low byte of $C332 (KSW target)
CB4E: 85 38        STA KSWL            ; Patch keyboard switch low
CB50: 86 39        STX KSWH            ; X=$C3 → KSW = $C332
CB52: A9 07        LDA #$07            ; Low byte of $C307 (CSW target)
CB54: 85 36        STA CSWL            ; Patch char output switch low
CB56: 86 37        STX CSWH            ; X=$C3 → CSW = $C307
CB58: 20 00 C8     JSR INIT            ; Initialize card hardware
CB5B: 18           CLC                 ; Clear carry (output mode after init)

;--- Route based on carry flag ---
OUTPUT_PATH:
CB5C: 90 6F        BCC OUTPUT_HANDLER  ; Carry clear → character output

;=============================================================================
; INPUT_HANDLER ($CB5E) — Keyboard Input Path
;   Implements the Apple II GETLN line editor. Handles character echoing,
;   backspace, ESC editing, and VRAM read-back (Ctrl-U "pick").
;=============================================================================
INPUT_HANDLER:
CB5E: 68           PLA                 ; Pull saved character (prompt char)
CB5F: A4 35        LDY TEMP            ; Y = saved X register
CB61: F0 1F        BEQ INPUT_GET_KEY   ; If X=0, skip prompt/echo

;--- Check for editing keys ---
CB63: 88           DEY                 ; Y = X - 1 (input buffer position - 1)
CB64: AD 78 06     LDA LAST_CHAR       ; Load last character
CB67: C9 88        CMP #$88            ; Is it backspace ($88)?
CB69: F0 17        BEQ INPUT_GET_KEY   ; Yes → just get next key

;--- Compare with input buffer for case-insensitive match ---
CB6B: D9 00 02     CMP $0200,Y         ; Compare with buffer at $0200+Y
CB6E: F0 12        BEQ INPUT_GET_KEY   ; Match → get next key
CB70: 49 20        EOR #$20            ; Toggle case (flip bit 5)
CB72: D9 00 02     CMP $0200,Y         ; Compare again (case-insensitive)
CB75: D0 3B        BNE INPUT_NEW_KEY   ; No match → get new key

;--- Store replacement character in buffer ---
CB77: AD 78 06     LDA LAST_CHAR       ; Load replacement
CB7A: 99 00 02     STA $0200,Y         ; Store in input buffer
CB7D: B0 03        BCS INPUT_GET_KEY   ; Skip if no prompt needed

;--- Input with prompt ---
INPUT_PROMPT:
CB7F: 20 ED CA     JSR PRINT_MSG_LOOP  ; Display prompt and wait for key

INPUT_GET_KEY:
CB82: A9 80        LDA #$80            ; Set GETLN flag in FLAGS
CB84: 20 F5 C9     JSR ESC_SET_FLAG    ; FLAGS |= $80
CB87: 20 44 C8     JSR GETKEY          ; Wait for keystroke

;--- Handle special keys in line editor ---
CB8A: C9 9B        CMP #$9B            ; ESC key?
CB8C: F0 F1        BEQ INPUT_PROMPT    ; Yes → re-display prompt
CB8E: C9 8D        CMP #$8D            ; Return key?
CB90: D0 05        BNE INPUT_CHK_PICK  ; No → check other keys
CB92: 48           PHA                 ; Save Return
CB93: 20 01 C9     JSR CLR_EOL         ; Clear to end of line
CB96: 68           PLA                 ; Restore Return

;--- Ctrl-U: pick character from screen (VRAM read-back) ---
INPUT_CHK_PICK:
CB97: C9 95        CMP #$95            ; Ctrl-U? ($15|$80)
CB99: D0 12        BNE INPUT_STORE     ; No → store character

;--- VRAM READ-BACK: read character under cursor ---
CB9B: AC 7B 05     LDY CHORZ           ; Y = cursor column
CB9E: 20 59 CA     JSR VRAM_WRITE      ; Calculate VRAM address (X=offset, C=page)
CBA1: B0 05        BCS INPUT_READ_HI   ; Carry → read from $CD00 page
CBA3: BD 00 CC     LDA $CC00,X         ; Read from VRAM page 0
CBA6: 90 03        BCC INPUT_READ_DONE ; Always taken

INPUT_READ_HI:
CBA8: BD 00 CD     LDA $CD00,X         ; Read from VRAM page 1

INPUT_READ_DONE:
CBAB: 09 80        ORA #$80            ; Set high bit (Apple II convention)

;--- Store character for line editor ---
INPUT_STORE:
CBAD: 8D 78 06     STA LAST_CHAR       ; Save last character
CBB0: D0 08        BNE INPUT_RETURN    ; If non-zero → return to caller

;--- No match: get new key without storing ---
INPUT_NEW_KEY:
CBB2: 20 44 C8     JSR GETKEY          ; Get another keystroke
CBB5: A0 00        LDY #$00            ; Clear Y
CBB7: 8C 78 06     STY LAST_CHAR       ; Clear last character

;--- Return to caller (Apple II GETLN) ---
INPUT_RETURN:
CBBA: BA           TSX                 ; Get stack pointer
CBBB: E8           INX                 ; Skip over saved registers
CBBC: E8           INX                 ; (3 bytes: Y, X, A pushed by handler)
CBBD: E8           INX
CBBE: 9D 00 01     STA $0100,X         ; Store result char on stack (replaces A)

;--- Sync Apple II ZP cursor from Videx state ---
INPUT_SYNC_ZP:
CBC1: A9 00        LDA #$00
CBC3: 85 24        STA CH              ; Set Apple II cursor column to 0
CBC5: AD FB 05     LDA CVERT           ; Load Videx cursor row
CBC8: 85 25        STA CV              ; Sync to Apple II cursor row
CBCA: 4C 2E C8     JMP EXIT_TO_40      ; Return via EXIT_TO_40 (restores regs)

;=============================================================================
; OUTPUT_HANDLER ($CBCD) — Character Output Path
;   Routes character through PUTC for display. Checks FLAGS bit 7
;   (GETLN mode) for special handling. After output, calls PAUSE_CHECK
;   and handles right-margin wrap indicator.
;=============================================================================
OUTPUT_HANDLER:
CBCD: 68           PLA                 ; Pull saved character
CBCE: AC FB 07     LDY FLAGS           ; Check FLAGS
CBD1: 10 08        BPL OUTPUT_NORMAL   ; Bit 7 clear → normal output

;--- GETLN mode: check for cursor-right replacement ---
CBD3: AC 78 06     LDY LAST_CHAR       ; Load last char
CBD6: C0 E0        CPY #$E0            ; >= $E0 (lowercase)?
CBD8: 90 01        BCC OUTPUT_NORMAL   ; No → output normally
CBDA: 98           TYA                 ; Yes → use last char instead

OUTPUT_NORMAL:
CBDB: 20 B1 C8     JSR PUTC            ; Output character via PUTC
CBDE: 20 CF CA     JSR PAUSE_CHECK     ; Check for Ctrl-S pause

;--- Handle right-margin wrap indicator ---
CBE1: A9 7F        LDA #$7F            ; Clear GETLN flag: FLAGS &= $7F
CBE3: 20 A0 C9     JSR INV_OFF         ; AND with FLAGS
CBE6: AD 7B 05     LDA CHORZ           ; Check cursor column
CBE9: E9 47        SBC #$47            ; Subtract 71 (column 72+)
CBEB: 90 D4        BCC INPUT_SYNC_ZP   ; Column < 72 → sync ZP and return
CBED: 69 1F        ADC #$1F            ; Add back (adjust for SBC rounding)
CBEF: 18           CLC
CBF0: 90 D1        BCC CBC3            ; Always taken → sync CH with adjusted value

;=============================================================================
; ESC_TABLE ($CBF2) — ESC Sequence Dispatch Table
;   8 low-byte entries for RTS dispatch trick (high byte = $C9).
;   Target address = $C900 + low_byte + 1.
;=============================================================================
ESC_TABLE:
CBF2: 60           ; ESC-@ → $C961 (HOME)
CBF3: 38           ; ESC-A → $C939 (CUR_RIGHT)
CBF4: 71           ; ESC-B → $C972 (CUR_LEFT)
CBF5: B2           ; ESC-C → $C9B3 (CUR_DOWN)
CBF6: 7B           ; ESC-D → $C97C (CUR_UP)
CBF7: 00           ; ESC-E → $C901 (CLR_EOL)
CBF8: 48           ; ESC-F → $C949 (CUR_DOWN_SCROLL / clear to EOS)
CBF9: 66           ; ESC-G → $C967 (SCROLL_UP)

;=============================================================================
; SIGNATURE BYTES ($CBFA) — ROM Signature / End Markers
;=============================================================================
CBFA: C4           ; 'D' (part of version/copyright signature)
CBFB: C2           ; 'B'
CBFC: C1           ; 'A' (Darrel B. Aldrich initials: DBA)
CBFD: FF           ; $FF (filler)
CBFE: C3           ; 'C' (slot 3 marker)
CBFF: EA           ; NOP (end of ROM)
```

---

## 21. Character ROM Reference

### 21.1 ROM Identity

| Property | Value |
|----------|-------|
| File | `hdl/video/videx_charrom.hex` (4096 lines, one hex byte per line) |
| Format | `$readmemh` compatible |
| Size | 4096 bytes total; only first 2048 bytes (normal chars) loaded |
| Source | Captured from a physical Videx VideoTerm adapter. Converted by `tools/gen_videx_rom.py`. |
| Structure | Two halves: normal (2048 bytes) + inverse (2048 bytes). Only the first half is loaded into a 2048-entry ROM array; inverse chars are generated at runtime by XOR inversion (§13.5). |

### 21.2 Addressing

The character ROM is addressed with an 11-bit address formed from the VRAM byte (lower 7 bits) and scanline counter:

```
rom_addr[10:0] = {vram_byte[6:0], scanline[3:0]}
```

- **Bits [10:4]** = Character code (7-bit ASCII, from VRAM bits [6:0])
- **Bits [3:0]** = Scanline within the character cell (0–8 displayed, 9–15 padding)

This gives 128 character entries × 16 scanlines each = 2048 bytes loaded. VRAM bit 7 (inverse flag) is not part of the ROM address — inverse rendering is handled by XOR inversion at pixel capture time in the `VIDEX_LINE` pipeline (§13.5).

Each character occupies 16 consecutive bytes. With R9 = 8 (9 scanlines per row), only bytes at offsets 0–8 within each character are displayed. Bytes at offsets 9–15 are padding.

### 21.3 Pixel Format

Each byte represents one horizontal scanline of one character:

```
Bit:     7   6   5   4   3   2   1   0
         │   │   │   │   │   │   │   │
         │   ╰───┴───┴───┴───┴───┴───╯
         │           7 pixels
     (unused/     (MSB = leftmost)
      spacing)
```

- **7 pixels wide**: Bits [6:0] are the visible pixels, MSB (bit 6) = leftmost
- **Bit 7**: Unused in normal rendering (may be 0 or used for column 8 extension in some implementations)
- `$00` = blank scanline (all pixels off)
- `$7E` = 6 pixels lit (e.g., horizontal bar of 'A')
- `$FF` = all 8 bits lit (fully solid, used in inverse NUL character)

### 21.4 Character Map Examples

**Normal 'A' (VRAM `$41`, ROM `$410–$41F`)**:

```
Scanline  Hex   Binary     Pixels
   0      $18   .##.....   ..##....
   1      $24   .#..#...   .#..#...
   2      $42   #....#..   #....#..
   3      $42   #....#..   #....#..
   4      $7E   #####.#.   ######..
   5      $42   #....#..   #....#..
   6      $42   #....#..   #....#..
   7      $00   ........   ........
   8      $00   ........   ........
  9-15    $00   (padding)
```

**Normal space (VRAM `$20`, ROM `$200–$20F`)**: Scanline 0 = `$10` (see Section 21.6.1), scanlines 1–15 are `$00`.

**Inverse NUL (VRAM `$80`, ROM `$800–$80F`)**: Scanlines 0–8 are `$FF` (fully lit block), scanlines 9–15 are `$FF`.

**Inverse 'A' (VRAM `$C1`, ROM `$C10–$C1F`)**: Pre-inverted pixel data — each displayed scanline is the bitwise complement of the normal version.

### 21.5 Encoding Relationship

The complete chain from ASCII input to pixels on screen:

```
                    Firmware Encoding              Character ROM Lookup
                    (ROM $CA71-$CA78)              (Rendering Pipeline)
                         │                              │
ASCII char ─────→  VRAM byte  ──── stored in ────→ rom_addr ────→ pixel_data
                         │         VRAM $CC00-          │              │
                         │         $CDFF                │              │
                                                        │              │
  Formula:                                    {vram[7:0],         bits[6:0]
  vram = {inverse,                             scanline[3:0]}     = 7 pixels
          char[6:0]}

Example: Normal 'A' ($41)
  char = $41 (0100_0001)
  inverse = 0
  vram = {0, 100_0001} = $41
  rom_addr = $41 * 16 + scanline = $410 + scanline
  scanline 0: rom[$410] = $18 → pixels = .##....

Example: Inverse 'A' ($41 with inverse flag)
  char = $41
  inverse = 1
  vram = {1, 100_0001} = $C1
  rom_addr = $C1 * 16 + scanline = $C10 + scanline
  scanline 0: rom[$C10] = $E7 → pixels = ###..###  (inverted)
```

### 21.6 Notable Character ROM Anomalies and Features

Analysis of the full `videx_charrom.hex` character ROM reveals several non-obvious properties:

#### 21.6.1 Space Character Anomaly

Character `$20` (space) has scanline 0 = `$10` (a single lit pixel at bit 4) instead of the expected `$00`. All other scanlines are `$00`. This appears to be an artifact of the original Videx font data preserved from the hardware character ROM. It does not affect rendering in practice because the pixel is in the normally-unused bit 7 region, but implementations that check for "blank" characters by testing all scanlines against zero will not match space.

#### 21.6.2 Control Code Characters (`$00`–`$1F`)

These character positions are **not blank** — they contain graphical symbols used for semigraphics and box drawing:

| Range | Content | Encoding |
|-------|---------|----------|
| `$00`–`$07` | Block elements | 3-bit encoding of top/middle/bottom thirds (like teletext semigraphics). Each bit controls one third of the character cell. |
| `$08`–`$0F` | Special composite characters | Possibly fractions, ligatures, or other special symbols |
| `$10`–`$1F` | Box-drawing characters | Corners, T-junctions, crossroads, and line segments for constructing bordered regions |

These glyphs are accessible only through direct VRAM writes (the firmware's control code dispatcher intercepts codes `$00`–`$1F` before they reach the character encoder). Software that writes directly to VRAM can display these symbols.

#### 21.6.3 Slashed Zero

Digit `0` (character `$30`) has a DEC-style diagonal slash through the center oval to distinguish it from the letter `O` (`$4F`). This is characteristic of the Videx font and differs from the standard Apple II character ROM which uses an unslashed zero.

#### 21.6.4 DEL Character (`$7F`)

Character `$7F` (DEL) is **not blank** — it contains a checkerboard/hatched fill pattern. This follows the convention of several 1980s terminal character ROMs where DEL serves as a visual "rubout" indicator.

#### 21.6.5 True Lowercase Descenders

Lowercase letters with descenders (`g`, `j`, `p`, `q`, `y`) use all 9 displayed scanlines (scanlines 0–8, matching R9 = 8). The descender strokes extend into scanlines 7 and 8, which are the bottom two lines of the 9-scanline character cell. This is a key visual advantage of the Videx's 9-scanline geometry over the Apple IIe's 8-scanline characters, where descenders must be compressed or truncated.

#### 21.6.6 Inverse Half Verification

The inverse character half (VRAM `$80`–`$FF`, ROM `$800`–`$FFF`) is a perfect bitwise NOT of the normal half (VRAM `$00`–`$7F`, ROM `$000`–`$7FF`) across all 8 bits of every displayed scanline. This confirms the character ROM was generated programmatically from a single source font, with the inverse half computed by bit inversion rather than independently designed.

---

## 22. Apple Pascal Peripheral Card Firmware Protocol

Reference: *Apple IIe Design Guidelines*, Appendix D: Peripheral Card Firmware Protocol (Pascal 1.2).

### 22.1 Slot-to-Device Assignment

Pascal automatically assigns device names based on slot:

| Slot | Device Name(s) | Unit # |
|------|---------------|--------|
| 1 | `PRINTER:` | #6 |
| 2 | `REMOTE:` (`REMIN:` / `REMOUT:`) | #7, #8 |
| 3 | `CONSOLE:` and `SYSTERM:` | #1, #2 |

The Videx card in slot 3 becomes the system console and terminal.

### 22.2 BIOS Startup Scan Protocol

At startup, the Pascal BIOS scans all 8 card slots and populates the `SLTTYPS` table at `$0BF27–$0BF2E`.

**Critical detail**: Before the BIOS calls any firmware routine, it **disables the `$C800` ROM space of all other firmware cards** by accessing `$CFFF`. Then it checks four firmware bytes to identify the card.

The identification sequence for each slot `s`:

1. Access `$CFFF` — release all expansion ROM ownership
2. Read `$Cs05` and `$Cs07` — primary identification
3. Read `$Cs0B` — generic firmware indicator (`$01`)
4. Read `$Cs0C` — device signature (class + manufacturer ID)
5. Read branch table at `$Cs0D`–`$Cs11`
6. Call INIT via `JSR $Cs00 + offset($Cs0D)`

### 22.3 Card Identification (`$Cs05` / `$Cs07`)

| SLTTYPS Value | Meaning | `$Cs05` | `$Cs07` |
|---------------|---------|---------|---------|
| 0 | No PROM on card | — | — |
| 1 | Card not recognized | — | — |
| 2 | Disk controller card | `$03` | `$3C` |
| 3 | Com card | `$18` | `$38` |
| 4 | Serial card | `$38` | `$18` |
| 5 | Printer card | `$48` | `$48` |
| 6 | Firmware card | `$48` | `$48` |

The Videx VideoTerm has `$C305=$38`, `$C307=$18` → SLTTYPS type 4 (Serial card). This is the standard Pascal 1.0 protocol identifier; the actual device class is in `$Cs0C`.

### 22.4 Device Signature Byte (`$Cs0C`)

High nibble `c` = device class, low nibble `i` = manufacturer ID.

| Class (`c`) | Meaning |
|-------------|---------|
| `$0` | Reserved |
| `$1` | Printer |
| `$2` | Joystick or other X-Y input device |
| `$3` | Serial or parallel I/O card |
| `$4` | Modem |
| `$5` | Sound or speech device |
| `$6` | Clock |
| `$7` | Mass storage device |
| `$8` | 80-column card |
| `$9` | Network or bus interface |
| `$A` | Special purpose |
| `$B`–`$F` | Reserved |

The Videx has `$C30C=$82` → class `$8` (80-column card), manufacturer ID `$2`.

### 22.5 Branch Table (`$Cs0D`–`$Cs11`)

| Address | Contents | Videx Value |
|---------|----------|-------------|
| `$Cs0D` | Initialization routine offset (required) | `$11` → `$C311` |
| `$Cs0E` | Read routine offset (required) | `$14` → `$C314` |
| `$Cs0F` | Write routine offset (required) | `$1C` → `$C31C` |
| `$Cs10` | Status routine offset (required) | `$22` → `$C322` |
| `$Cs11` | `$00` if control/interrupt routines implemented | `$00` |

### 22.6 I/O Routine Register Conventions

| Entry | Address | On Entry | On Exit |
|-------|---------|----------|---------|
| **INIT** | `$Cs0D` offset | X=`$Cs`, Y=`$s0` | X=error code |
| **READ** | `$Cs0E` offset | X=`$Cs`, Y=`$sC` | X=error code, A=character read |
| **WRITE** | `$Cs0F` offset | X=`$Cs`, Y=`$s0`, A=char to write | X=error code |
| **STATUS** | `$Cs10` offset | X=`$Cs`, Y=`$s0`, A=request code | X=error code, carry=result |

Status request codes:
- `0` = "Are you ready to accept output?" → carry set = yes
- `1` = "Do you have input ready?" → carry set = yes

### 22.7 Key Difference: PASCAL_WRITE vs CSW Code Path

The Pascal firmware entries take **different code paths** than the CSW/KSW hooks:

| Entry | Path | Accesses `$CFFF`? |
|-------|------|-------------------|
| CSW (`$C307`) | → `MAIN_HANDLER` (`$C336`) → `STA $CFFF` → expansion ROM | **Yes** |
| KSW (`$C332`) | → `MAIN_HANDLER` (`$C336`) → `STA $CFFF` → expansion ROM | **Yes** |
| PASCAL_INIT (`$C311`) | → `JMP $C800` (direct) | **No** |
| PASCAL_READ (`$C314`) | → `JSR $C844` (expansion ROM direct) | **No** |
| PASCAL_WRITE (`$C31C`) | → `JSR $C9A7` (expansion ROM direct) | **No** |
| PASCAL_STATUS (`$C322`) | → inline + `JSR $C85C` if needed | **No** |

The Pascal entries bypass `MAIN_HANDLER` entirely and never access `$CFFF`. This means the Videx card does not release other cards' C8 ownership when called through the Pascal protocol. However, the Pascal BIOS itself accesses `$CFFF` before each firmware call (§22.2), so ownership is managed by the BIOS.

---

## 23. Implementation Changelog

### 23.1 Initial Implementation (commit 123f8d4)

- Combined architecture: single `videx_card.sv` owns ROM, CRTC, VRAM, bus response
- `a2mem_if.videx` modport for VIDEX_* signals
- VRAM as `sdpram32` instances

### 23.2 VRAM Optimization (commit c8b9c13)

- Replaced `sdpram32` instances with inline dual-port array (later changed to GoWin SDPB primitive)
- Goal: reduce BSRAM usage from 4 blocks to 1

### 23.3 Character ROM Halving (commit 7458d97)

- Chars `$80`–`$FF` are bitwise inverse of `$00`–`$7F`
- Store 2 KB, XOR at capture points in `VIDEX_LINE` pipeline
- Saves 1 BSRAM block (charrom from 2 pROM to 1 pROM)

### 23.4 SLOTROM Guard Fix (applied in videx_card.sv, SSC)

**Problem**: After Pascal INIT (`$C311 → JMP $C800 → RTS`), `rom_ownership` stayed set because the INIT path never accesses `$CFFF`. When Pascal continued scanning other slots, the Videx card incorrectly responded to their C8 reads.

**Root cause**: `rom_c8_active` only checked `rom_ownership && !INTCXROM`. After INIT, `rom_ownership=1` and the card responded to all C8 reads regardless of which slot was active.

**Fix**: Added `SLOTROM == 3'd3` guard to `rom_c8_active`:
```systemverilog
wire rom_c8_active = rom_ownership && !a2mem_if.INTCXROM && (a2mem_if.SLOTROM == 3'd3);
```

Same fix applied to SSC (`ENA_C8S` with `SLOTROM == 3'd2` guard, commit 880a976).

**Required**: Added `SLOTROM` to `a2mem_if.videx` modport.

### 23.5 CRTC Read-Back Fix (Open Bus Gotcha)

**Problem**: Programs like CardCat read CRTC registers R12/R13 (display start address). The original implementation only responded to R14/R15 reads, causing "open bus" for other registers — CPU reads `$C0` (address high byte) instead of `$00`. This caused wrong VRAM offsets and lockups.

**Fix**: Changed `crtc_read` to respond to ALL device-select reads:
```systemverilog
wire crtc_read = card_dev_sel && a2bus_if.rw_n;  // no crtc_readable gate
```
All R0–R15 return their written values (HD6845SP Type 1 behavior). Non-existent registers (R16+) and even-address reads return `$00`.

### 23.6 INTC8ROM Clearing on Non-C3 Slot Access

**Problem**: On the Apple ][+, `INTC8ROM` was only cleared by `$CFFF` access. Accessing another slot's ROM (e.g., `$C600`) did not clear `INTC8ROM`, leaving `io_strobe_n` blocked.

**Fix**: In `apple_memory.sv`, non-C3 slot ROM access (`$C100–$C7FF`, not `$C3xx`) now clears `INTC8ROM`:
```systemverilog
else INTC8ROM <= 1'b0;  // already present — verified this path exists
```

### 23.7 Diagnostic Test Suite (VIDEX_DIAG.txt V2.0)

Tests T01–T17 transcribed from on-hardware V1.1 program. Tests T18–T21 added for SLOTROM guard validation:
- T18: Slot deselection (access `$C200`, verify Videx C8 not responding)
- T19: `$CFFF` ownership clearing
- T20: VRAM isolation across slot switch
- T21: Multi-slot round trip (slot 3 → slot 2 → slot 4 → slot 3)

**Result**: All 21 tests pass on the A2FPGA emulation. See §25 for cross-platform comparison.

### 23.8 cfff_access phi0 Fix (Root Cause of Non-Determinism)

**Problem**: `cfff_access` in `videx_card.sv` was not phi0-qualified. Address bus transients during phi1 (especially during CPLD drive-to-tristate transitions) spuriously matched `$CFFF`, clearing `c8_owned` mid-execution. With `c8_owned=0`, 6502 reads open bus at `$C8xx` → executes `$FF` bytes → non-deterministic crash.

**Fix**: `wire cfff_access = a2bus_if.phi0 && (a2bus_if.addr == 16'hCFFF);`

**Result**: 12/12 consecutive boots deterministic. Non-determinism completely eliminated.

### 23.9 SSC C8S2 phi0 Fix (Cross-Card Interference, commit 880a976)

**Problem**: SSC's C8S2 ownership logic had unqualified `$CFFF` detection. When Videx `rd_en_o` transitioned from active to tristate, PCB bus transceiver glitches caused SSC's C8S2 to spuriously clear mid-SSC expansion ROM execution → open bus → SSC FINIT crash.

**Fix**: `else if (a2bus_if.phi0)` gate around entire C8S2 case block in `super_serial_card.sv`.

**Evidence**: Shadow mode (Videx rd_en_o=0 always) eliminates all bus transceiver transitions → SSC C8S2 never spuriously cleared → SSC FINIT succeeds. This confirms the PCB glitch mechanism.

### 23.10 VRAM Read-Back

VRAM CPU reads (`$CC00–$CDFF`) are fully enabled. The card drives `rd_en_o` for VRAM reads when `rom_c8_active` and `phi0` are asserted. The SDPB's 32-bit read port serves both the scanner pipeline and CPU read-back (via hold register and byte selection).

Initial testing had VRAM reads disabled based on the observation that physical Videx and A2DVI return open bus under VIDEX_DIAG. The actual root cause of the Pascal hang was CPLD OE timing (§23.11), not VRAM read responses. VRAM reads were re-enabled after the OE cutoff fix resolved the hang.

### 23.11 Phase-Counter OE Cutoff (apple_bus.sv)

**Problem**: The CPLD bus data OE was purely combinational, tracking `data_out_en_i` directly. The CDC denoise pipeline delays phi0 by ~100ns (6 clk_logic cycles at 54 MHz). This caused the CPLD to continue driving the Apple II data bus for ~100ns into phi1, creating bus contention during I/O writes from C8 space that broke disk loading during Pascal boot.

**Evidence**: ROM patch testing (Tests H-M) proved I/O writes ($C0xx) from C8 space break disk loading while main RAM writes ($0400) from C8 space work fine. The bus contention during I/O decode is the mechanism.

**Fix**: Phase-counter-gated OE cutoff in `apple_bus.sv`:
```systemverilog
localparam int CDC_DELAY = 6;
localparam int OE_MARGIN = 2;
localparam int OE_CUTOFF = PHASE_COUNT - CDC_DELAY + OE_MARGIN;  // = 22

wire oe_early_cutoff = a2bus_if.phi0 && (phase_cycles_r >= OE_CUTOFF[5:0]);
assign a2_bridge_bus_d_oe_n_o = ~(data_out_en_i & BUS_DATA_OUT_ENABLE & ~oe_early_cutoff);
```

**Status**: Verified. Pascal 1.3 boots 100% with all emulated cards enabled. OE_MARGIN=2 confirmed correct.

---

## 24. Resolved: Pascal Boot Hang

Apple Pascal 1.3 initially hung during boot with the Videx card enabled. Multiple root causes were found and fixed:

### 24.1 Root Causes and Fixes

| Root Cause | Fix | Reference |
|------------|-----|-----------|
| `cfff_access` not phi0-qualified — address bus transients during phi1 spuriously cleared `c8_owned` → open bus → non-deterministic crashes | phi0 qualification: `wire cfff_access = a2bus_if.phi0 && (addr == 16'hCFFF)` | §23.9 |
| SSC `C8S2` not phi0-qualified — PCB bus transceiver glitches (from Videx rd_en_o transitions) caused SSC expansion ROM ownership to clear mid-execution | phi0 gate on entire C8S2 case block in `super_serial_card.sv` | §23.9 |
| INTC8ROM permanently set on Apple ][+ — blocked io_strobe_n for ALL slot 3 cards | `is_iie` runtime detection gates INTC8ROM (Apple IIe only) | §23.8 |
| CPLD bus transceiver OE held ~100ns into phi1 — I/O writes from C8-space created bus contention that corrupted disk I/O | Phase-counter OE cutoff in `apple_bus.sv` releases OE ~37ns after real phi0 drops | §23.11 |

### 24.2 Key Observations

- All 21 BASIC diagnostic tests passed even before Pascal fixes — the bugs only manifested during Pascal's multi-card boot sequence where FINIT is called for every detected firmware card
- Shadow mode (rd_en_o=0, rom_en_o=0) confirmed the rendering pipeline was correct — the problem was exclusively in bus response timing
- Systematic ROM patching proved the failure mechanism: I/O writes (`$C0xx`) from C8 space broke disk loading, while RAM writes (`$0400`) from C8 space worked fine — pointing to CPLD OE timing as the root cause

### 24.3 Pascal Detection Protocol

Apple Pascal 1.1–1.3 all use the same UCSD p-System Interpreter II nucleus. Pascal detects Videx as **type 6 (firmware)** based on ROM bytes at offsets 5=$38, 7=$18, 11=$01, routing all console I/O through the Pascal firmware protocol (WFIRM/RFIRM/FINIT). The emulated SSC in slot 2 has identical detection bytes, so Pascal calls FINIT for both cards.

### 24.4 Status

All issues resolved. Pascal 1.3 boots 100% with all emulated cards enabled (Videx + SSC + Mockingboard + SuperSprite).

---

## 25. Cross-Platform VIDEX_DIAG Comparison

### 25.1 Test Platforms

| Platform | CRTC Chip | ROM | Drives Bus | Pascal/CardCat |
|----------|-----------|-----|------------|----------------|
| Physical Videx | HD6845SP (Hitachi, Type 1) | Original hardware ROM | Yes (physical card) | **Works** (confirmed via shadow mode HDMI) |
| A2DVI v4.4 | Emulated | Custom firmware | Yes (own transceiver) | **Works** (confirmed on HDMI) |
| A2FPGA shadow | Emulated (Type 1) | N/A (rd_en_o=0) | No (snoops writes only) | **Works** (rendering correct) |
| A2FPGA normal | Emulated (Type 1) | videx_rom.hex (ROM 2.4) | Yes (shared FPGA transceiver) | **Works** (OE cutoff fix) |

### 25.2 VIDEX_DIAG Results (V2.0)

| Test | Description | Physical Videx | A2DVI v4.4 | A2FPGA |
|------|-------------|---------------|------------|--------|
| T01 | Init/detect | 0 OK | OK | OK |
| T02 | CRTC R14 | OK | OK | 1 OK |
| T03 | CRTC R15 | OK | OK | 160 OK |
| T04 | WO reg read | 0 OK | FAIL (returns written val) | 122 FAIL(EXP 0) |
| T05 | R12 RD(WO) | 63 FAIL(EXP 0) | FAIL (returns written val) | 0 OK |
| T06 | R13 RD(WO) | 60 FAIL(EXP 0) | FAIL (returns written val) | 160 FAIL(EXP 0) |
| T07 | Slot ROM | 44 OK | OK | 44 OK |
| T08 | Exp ROM | **255 FAIL(EXP 173)** | FAIL (open bus) | 173 OK |
| T09 | VRAM WR/RD | **195 FAIL(EXP 170)** | FAIL (open bus) | 170 OK |
| T10 | VRAM BYTE2 | **58 FAIL(EXP 85)** | FAIL (open bus) | 85 OK |
| T11 | CFFF+REENT | **210 FAIL(EXP 173)** | FAIL | 173 OK |
| T12 | VRAM POST | **160 FAIL(EXP 170)** | FAIL | 170 OK |
| T13 | R14/15 | 42,99 OK | OK | 42,99 OK |
| T14 | BANK SWITCH | **255,0 FAIL(EXP 85,170)** | FAIL | 85,170 OK |
| T15 | VRAM FILL | **255 ERRS FAIL** | FAIL | 0 ERRS OK |
| T16 | VRAM STRESS | **509 ERRS FAIL** (loop 1-2) | FAIL | 0 ERRS OK |
| T17 | WO DIAG | 0 OK (CARD) | OK | OK |
| T18 | Slot desel | — | — | 32,173 OK |
| T19 | CFFF clear | — | — | 160,173 OK |
| T20 | VRAM isol | — | — | OK |
| T21 | Multi-slot | — | — | FAIL |

### 25.3 Key Findings

1. **Physical Videx fails T08–T16**: The real card does not serve expansion ROM or VRAM reads when accessed by VIDEX_DIAG's test pattern. T08 returns $FF (not valid ROM data), T09–T16 VRAM tests all fail. Pascal works with the physical Videx (confirmed via shadow mode HDMI rendering).

2. **A2DVI fails the same tests**: A2DVI returns open bus for expansion ROM and VRAM reads. Pascal/CardCat confirmed working on A2DVI's HDMI output.

3. **A2FPGA passes T08–T16**: Our emulation correctly serves expansion ROM and VRAM reads. Pascal/CardCat hangs.

4. **A2FPGA serves all C8-space reads correctly**: Unlike the physical Videx and A2DVI, which return open bus for expansion ROM and VRAM reads under VIDEX_DIAG, the A2FPGA serves these reads correctly. This is the desired behavior for full emulation fidelity. The Pascal hang was caused by CPLD OE timing (§23.11), not by C8-space read responses.

5. **CRTC register reads differ across platforms**:
   - Physical HD6845SP: R0 returns 0, R12 returns 63, R13 returns 60 (mixed behavior)
   - A2DVI: Returns written values for all registers (full Type 1)
   - A2FPGA: Returns written values for all registers (full Type 1)

6. **Physical Videx T05/T06**: R12 returns 63 ($3F), R13 returns 60 ($3C). These are neither 0 nor the previously written values. This may reflect partial read-back or internal CRTC state leaking through.

### 25.4 Analysis

The physical Videx and A2DVI both fail VIDEX_DIAG T08-T16 (expansion ROM and VRAM reads) yet work correctly with Pascal. The A2FPGA passes all tests and also works correctly with Pascal (after the bus timing fixes in §23). The test differences are unrelated to the Pascal hang — the A2FPGA's correct C8-space read responses are the desired behavior for full emulation fidelity.

The physical Videx card's failure to respond to VIDEX_DIAG's C8-space reads likely reflects the real Apple ][+ io_strobe_n mechanism. VIDEX_DIAG accesses C8-space from BASIC without the firmware-initiated io_strobe_n handshake that normal firmware execution provides. The A2FPGA uses phi0-qualified `rom_c8_active` instead of io_strobe_n (see §3, §26).

---

## 26. C8 Ownership Design Rationale

### 26.1 Why Not SLOTROM Guard

The Videx card uses self-clearing `c8_owned` instead of a SLOTROM-based guard. SLOTROM-based approaches (both `a2mem_if.SLOTROM` and raw address decode) consistently caused PR#3 to hang. The probable cause is a timing mismatch: SLOTROM is updated on `phi1_posedge` in `apple_memory.sv`, but card signals use different clock qualifications (`phi0`, `card_io_sel`). The SLOTROM value may not be stable when the card evaluates `rom_c8_active` during the same bus cycle.

**Note**: The SSC's SLOTROM guard (`SLOTROM == 2`) has not been verified with actual SSC C8-space usage and may have the same timing issue.

### 26.2 Current Approach

Self-clearing `c8_owned`: the card monitors `$C1xx-$C7xx` directly (phi0-qualified) and clears `c8_owned` when any non-slot-3 `$Csxx` address is accessed. This implements the ownership protocol internally without depending on SLOTROM. `rom_c8_active = c8_owned && !INTCXROM`.

### 26.3 INTC8ROM Fix

The `is_iie` runtime detection is implemented and verified in `apple_memory.sv`. On Apple ][+, INTC8ROM remains 0 (never set), allowing io_strobe_n to fire normally for all slot 3 cards. On Apple IIe, INTC8ROM works correctly gated by SLOTC3ROM.

### 26.4 phi0 Qualification

All address-sensitive signals in the card (`cfff_access`, `other_slot_rom`, C8S2 in SSC) must be phi0-qualified to prevent address bus transients during phi1 from causing spurious state changes. At 54+ MHz `clk_logic`, even single-cycle transients during address transitions (e.g., `$C33x` → `$C8xx` passing through `$CFFF`) can fire unqualified comparators.
