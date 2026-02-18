# Videx VideoTerm 80-Column Card — Implementation Specification

## Target: `videx_card.sv` for A2FPGA (Approach B)

This specification defines every hardware behavior the virtual Videx card module must implement, derived from exhaustive analysis of the Videx VideoTerm ROM 2.4 firmware, MC6845 CRTC datasheet, and the existing A2FPGA passive shadow infrastructure.

---

## 1. Module Interface

```systemverilog
module videx_card (
    a2bus_if.slave   a2bus_if,
    a2mem_if.slave   a2mem_if,

    // Directly from slotmaker for slot 3
    input wire       dev_select_n,    // active when addr[6:4]==3 && addr[15:12]==$C
    input wire       io_select_n,     // active when addr[10:8]==3 && addr[15:11]==$C (slot ROM)
    input wire       io_strobe_n,     // active when addr[15:11]==$19 ($C800-$CFFF)

    output reg [7:0] data_o,          // data driven onto bus for reads
    output reg       rd_en_o          // active when card is driving data_o
);
```

The card does **not** generate interrupts (`irq_n` is not needed — the real Videx had no IRQ).

---

## 2. Address Decoding

The card responds to three address regions. All decoding is active during `phi1_posedge` when `!m2sel_n`.

### 2.1 Device I/O: `$C0B0–$C0BF`

Active when `dev_select_n` is asserted (active-low). The slot 3 device select range is `$C0B0–$C0BF` (16 addresses).

| Bits | Meaning |
|------|---------|
| `addr[3:2]` | VRAM bank select (0–3), latched on **every** access (read or write, even or odd) |
| `addr[0]` | 0 = CRTC address register, 1 = CRTC data register |

### 2.2 Slot ROM: `$C300–$C3FF`

Active when `io_select_n` is asserted. The card drives `data_o` with the firmware ROM byte at offset `addr[7:0]`. This also sets the expansion ROM ownership flag.

### 2.3 Expansion ROM: `$C800–$CFFF`

Active when `io_strobe_n` is asserted **and** the card owns the expansion ROM space (ownership flag is set). The card drives `data_o` with the firmware ROM byte. The VRAM window at `$CC00–$CDFF` overlaps this range — see Section 5.

### 2.4 VRAM Window: `$CC00–$CDFF`

A 512-byte subrange of the expansion ROM space. When the expansion ROM ownership flag is set and `addr[15:9] == 7'b1100_110` (`$CC00–$CDFF`):
- **Writes**: Store byte to VRAM at `{bank[1:0], addr[8:0]}`
- **Reads**: Drive VRAM byte onto `data_o` (overrides expansion ROM)

### 2.5 `$CFFF` Strobe

Any access to `$CFFF` clears the expansion ROM ownership flag. The Videx firmware does `STA $CFFF` at every entry.

---

## 3. Expansion ROM Ownership Protocol

```
Ownership flag (1 bit):
  SET   when CPU accesses $C300–$C3FF (io_select_n asserted)
  CLEAR when CPU accesses $CFFF
  CLEAR on system reset
```

When the ownership flag is **set**, the card responds to `$C800–$CFFF` reads (expansion ROM + VRAM window). When **clear**, the card ignores `$C800–$CFFF`.

The existing `apple_memory.sv` tracks `SLOTROM` and `INTC8ROM` independently via its own snooping. The card's internal ownership flag is its own copy of this state, used solely for its own bus response decisions.

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

### 4.3 Read Behavior

**Even address**: Returns undefined (the MC6845 address register is write-only). The card should not drive `data_o`.

**Odd address**: If `crtc_idx` is 14 or 15, drive `crtc_regs[crtc_idx]` onto `data_o` and assert `rd_en_o`. For all other register indices, do not drive the bus (registers R0–R13 are write-only on the HD46505SP/MC6845 Type 0 used in the Videx).

**Why R14/R15 read-back matters**: The Videx ROM itself never reads CRTC registers. However, third-party detection software writes a test value to R14, then reads it back — if the value matches, a Videx card is present. Without read-back, these programs fail to detect the card.

### 4.4 Register Initialization Values (from ROM 2.4)

These are programmed by the firmware, not by the card hardware. Listed here for reference and testing:

| Reg | ROM 2.4 Value | Purpose |
|-----|--------------|---------|
| R0  | `$7A` (122)  | Horizontal Total: 123 character times/line |
| R1  | `$50` (80)   | Horizontal Displayed: 80 characters |
| R2  | `$5E` (94)   | Horizontal Sync Position |
| R3  | `$29` (41)   | Sync Width (clone ROMs use `$2F`) |
| R4  | `$1B` (27)   | Vertical Total: 28 character rows |
| R5  | `$08` (8)    | Vertical Total Adjust: 8 extra scan lines |
| R6  | `$18` (24)   | Vertical Displayed: 24 rows |
| R7  | `$19` (25)   | Vertical Sync Position |
| R8  | `$00`        | Interlace: non-interlaced |
| R9  | `$08`        | Max Scan Line: 9 scanlines/row (0–8) |
| R10 | `$E0`        | Cursor Start: scanline 0, blink 1/32 field rate |
| R11 | `$08`        | Cursor End: scanline 8 |
| R12 | `$00`        | Display Start Address High |
| R13 | `$00`        | Display Start Address Low |
| R14 | `$00`        | Cursor Address High |
| R15 | `$00`        | Cursor Address Low |

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

### 4.6 Feeding the Shadow

The existing passive shadow in `apple_memory.sv` snoops bus writes to `$C0B0/$C0B1` and captures CRTC register values into its own `videx_crtc_regs[]` array. When the emulated card is active, the CPU still writes to `$C0B0/$C0B1` — these writes appear on the bus and the shadow captures them exactly as before. **No changes to the shadow CRTC capture logic are needed.**

The shadow also sets `videx_mode_r = 1` on the first observed CRTC write. This flag activates `VIDEX_LINE` rendering. It will trigger automatically when the Videx firmware initializes.

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

The existing shadow in `apple_memory.sv` also captures this write into its own `videx_vram` BSRAM (same bus transaction, same data). The shadow's VRAM feeds the `VIDEX_LINE` renderer's read port. **No changes to the shadow VRAM write capture are needed.**

### 5.5 Read Path (New — Not in Shadow)

When the CPU reads from `$CC00–$CDFF` and the expansion ROM ownership flag is set:

```systemverilog
data_o <= vram[{bank_sel, addr[8:0]}];
rd_en_o <= 1;
```

This is the **critical gap** the card fills. The shadow's `sdpram32` read port is dedicated to the video scanner — it cannot serve CPU reads. The card maintains its own 2 KB VRAM copy specifically for read-back.

**Why VRAM reads matter**: The Videx ROM's CTRL-U "pick" function reads the character under the cursor from VRAM. Advanced programs (Apple Writer II, WordStar, VisiCalc) also read VRAM directly.

### 5.6 VRAM as Circular Buffer

The 2 KB VRAM is used as a ring buffer for hardware scrolling:
- Display start = `{R12[2:0], R13[7:0]}` (11-bit address, wraps at 2048)
- 24 rows × 80 columns = 1920 bytes active
- 128 bytes unused gap
- Scrolling increments the display start by 80 (one row), wraps modulo 2048
- New blank lines are written at the wrap point

The ROM tracks the scroll offset in the `START` screen hole (`$06FB`). `START` ranges 0–127, and the display start address = `START × 16`.

### 5.7 Implementation: Dual BSRAM vs. Shared

**Recommended**: Two independent VRAM copies:

| Copy | Purpose | Storage | Read Port User |
|------|---------|---------|---------------|
| Shadow VRAM | Video rendering | `sdpram32` in `apple_memory.sv` (existing) | `VIDEX_LINE` pipeline in `apple_video.sv` |
| Card VRAM | CPU read-back | New `sdpram32` or simple BSRAM in `videx_card.sv` | CPU reads of `$CC00–$CDFF` |

Both receive identical writes (from the same bus transactions). The shadow's write capture continues to work because it snoops bus writes — the card's presence doesn't change what appears on the bus during writes.

**Cost**: 1 additional BSRAM block (2 KB). The a2n20v2 has 6 free blocks; this uses 1.

---

## 6. Firmware ROM

### 6.1 Storage

1 KB ROM chip mapped into two regions:

| CPU Address | ROM Offset | Size | Purpose |
|-------------|-----------|------|---------|
| `$C300–$C3FF` | `$300–$3FF` | 256 bytes | Slot ROM |
| `$C800–$CBFF` | `$000–$3FF` | 1024 bytes | Expansion ROM |

The slot ROM at `$C300–$C3FF` is the **same physical bytes** as `$CB00–$CBFF` in the expansion ROM. The ROM file is 1 KB; the slot ROM window reads from the last 256 bytes.

### 6.2 BSRAM Allocation

The 1 KB ROM can be stored in a single BSRAM block (each GW2AR-18C BSRAM block is 2 KB). The unused half can be left empty or used for future expansion.

Loaded from `videx_rom.hex` via `$readmemh`.

### 6.3 Read Response

```
if slot ROM access ($C300–$C3FF):
    data_o <= rom[{1'b1, addr[7:0]}]    // offset $100–$1FF maps to ROM $300–$3FF
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

---

## 7. Annunciator 0 (AN0) — Display Mode Switching

The Videx firmware uses AN0 to signal 80-column mode:

| Address | Effect | When Used by Firmware |
|---------|--------|----------------------|
| `$C058` | AN0 OFF → 40-column mode | `CTRL-Z` + `'1'` (exit to 40-col) |
| `$C059` | AN0 ON → 80-column mode | Initialization; **every character output** |

The card does **not** need to handle AN0 directly. The existing soft switch capture in `apple_memory.sv` already tracks `SWITCHES_II[4]` (AN0) when the CPU accesses `$C058/$C059`. The `VIDEX_LINE` renderer activates when `videx_mode_r && text_mode_r && an0_r`.

**Key detail**: The Videx firmware writes `STA $C059` on **every single character output** (`OUTPT1` at `$CA8F`), re-asserting AN0. This ensures the display stays in 80-column mode even if something else toggled AN0.

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

---

## 9. Character Encoding in VRAM

The firmware encodes characters before writing to VRAM:

```
vram_byte = (ascii_char << 1) | (FLAGS.bit0 << 7)
```

- Bits [6:0]: ASCII character code shifted left by 1
- Bit 7: 0 = normal, 1 = inverse (from FLAGS bit 0)

The character ROM is addressed as `{vram_byte[7:0], scanline[3:0]}`:
- `$000–$7FF`: 128 normal characters × 16 scanlines
- `$800–$FFF`: 128 inverse characters × 16 scanlines

Only scanlines 0–8 are displayed (R9 = 8). Each character cell is 7 pixels wide.

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

All bus responses occur on `phi1_posedge` when `!m2sel_n`:
- **Writes** (`!rw_n`): Capture data from `a2bus_if.data` on `data_in_strobe`
- **Reads** (`rw_n`): Drive `data_o` and assert `rd_en_o`

The card must drive `data_o` early enough in the bus cycle for the CPU to sample it. Follow the same timing pattern as `super_serial_card.sv` for bus response.

---

## 11. Complete State Machine

The card has minimal state — no complex state machine is needed. The entire card is combinational/registered logic:

### Registered State

```
reg        rom_ownership;     // expansion ROM ownership flag
reg [4:0]  crtc_idx;          // CRTC register index
reg [7:0]  crtc_regs[0:15];   // CRTC register file
reg [1:0]  bank_sel;           // VRAM bank select
reg [7:0]  vram[0:2047];      // 2 KB VRAM for CPU read-back
```

### Reset State

```
rom_ownership <= 0;
crtc_idx      <= 0;
bank_sel      <= 0;
crtc_regs[*]  <= 0;
// VRAM: no reset needed (firmware clears it during init)
```

### Per-Cycle Logic (on phi1_posedge, !m2sel_n)

```
// 1. Bank select — on ANY $C0Bx access
if (dev_select_n == 0)
    bank_sel <= addr[3:2];

// 2. CRTC writes
if (dev_select_n == 0 && !rw_n)
    if (addr[0] == 0)
        crtc_idx <= data[4:0];          // address register
    else if (crtc_idx < 16)
        crtc_regs[crtc_idx] <= data;    // data register

// 3. CRTC reads (R14/R15 only)
if (dev_select_n == 0 && rw_n && addr[0] == 1)
    if (crtc_idx == 14 || crtc_idx == 15)
        data_o <= crtc_regs[crtc_idx];
        rd_en_o <= 1;

// 4. Slot ROM read → set ownership
if (io_select_n == 0 && rw_n)
    rom_ownership <= 1;
    data_o <= rom[{1'b1, addr[7:0]}];
    rd_en_o <= 1;

// 5. VRAM write
if (rom_ownership && addr is $CC00–$CDFF && !rw_n)
    vram[{bank_sel, addr[8:0]}] <= data;

// 6. VRAM read
if (rom_ownership && addr is $CC00–$CDFF && rw_n)
    data_o <= vram[{bank_sel, addr[8:0]}];
    rd_en_o <= 1;

// 7. Expansion ROM read (not VRAM range)
if (rom_ownership && io_strobe_n == 0 && addr is $C800–$CBFF && rw_n)
    data_o <= rom[addr[9:0]];
    rd_en_o <= 1;

// 8. $CFFF → clear ownership
if (addr == $CFFF)
    rom_ownership <= 0;
```

### Shadow Interaction

The card does **not** write to `a2mem_if.VIDEX_CRTC_R*` signals directly. The existing shadow capture logic in `apple_memory.sv` snoops the same bus writes the card processes and populates those signals automatically. The card and shadow see identical bus transactions.

---

## 12. Integration into Board Top-Level

### 12.1 Instantiation

Add to `boards/a2n20v2/hdl/top.sv` (gated by `VIDEX_SUPPORT` parameter):

```systemverilog
generate if (VIDEX_SUPPORT) begin : videx_card_gen
    videx_card videx_card_inst (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),
        .dev_select_n(slot3_dev_select_n),
        .io_select_n(slot3_io_select_n),
        .io_strobe_n(slot3_io_strobe_n),
        .data_o(videx_data_o),
        .rd_en_o(videx_rd_en_o)
    );
end endgenerate
```

### 12.2 Bus Multiplexer

Add card's data output to the existing bus mux:

```systemverilog
assign data_out_w = videx_rd_en_o ? videx_data_o : /* existing chain */;
assign data_out_en_w = videx_rd_en_o | /* existing chain */;
```

### 12.3 Slot Assignment

The card must be wired to slot 3's select signals from `slotmaker`. If `slotmaker` uses `slots.hex` for card assignment, update entry 3 to the Videx card ID. If wired directly, connect the slot 3 select lines.

---

## 13. Rendering Path (Existing — No Changes)

The `VIDEX_LINE` pipeline in `apple_video.sv` handles all rendering. No modifications are needed. Summary of what it does:

### 13.1 Mode Activation

```systemverilog
wire line_type_w = (videx_mode_r & text_mode_r & an0_r) ? VIDEX_LINE : ...;
```

`videx_mode_r` is set by the shadow on first CRTC write. `text_mode_r` and `an0_r` come from soft switches.

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
rom_addr = {vram_byte[7:0], scanline[3:0]}   // 12-bit address into 4 KB ROM
pixel_data = videxrom[rom_addr]               // 8 bits, only lower 7 used
```

### 13.5 Cursor Rendering

Cursor position: `{R14[2:0], R15[7:0]}` (11-bit VRAM address).
Blink mode from R10[6:5]: `00`=always on, `01`=hidden, `10`=1/16 field rate, `11`=1/32 field rate.
Scanline range: R10[3:0] (start) to R11[3:0] (end).
Rendered as XOR `7'h7F` on the character's pixel data.

---

## 14. BSRAM Budget

From synthesis report: 40/46 blocks used (87%), 6 free.

| New Component | BSRAM Blocks |
|--------------|-------------|
| Firmware ROM (1 KB in 2 KB block) | 1 |
| Card VRAM for CPU read-back (2 KB) | 1 |
| **Total new** | **2** |
| **Remaining free** | **4** |

The shadow's existing `videx_vram` BSRAM (1 block) is unchanged. Total Videx BSRAM = 3 blocks (1 shadow + 2 card).

---

## 15. Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `hdl/videx/videx_card.sv` | **Create** | Virtual card module (~300–400 lines) |
| `hdl/videx/videx_rom.hex` | **Create** | Videx VideoTerm ROM 2.4 image (1 KB, hex format) |
| `boards/a2n20v2/hdl/top.sv` | **Modify** | Instantiate card, wire to bus mux and slot 3 selects |
| `hdl/memory/apple_memory.sv` | **No change** | Shadow capture continues to work as-is |
| `hdl/video/apple_video.sv` | **No change** | VIDEX_LINE renderer continues to work as-is |
| `hdl/memory/a2mem_if.sv` | **No change** | VIDEX signals already defined |

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

### 16.6 Mode Switching

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

2. **The firmware accesses `$CFFF` at every entry** (input and output). This means the expansion ROM is briefly deselected, then reactivated when the next instruction fetch hits `$C800+`. The card must handle rapid ownership clear/set cycles.

3. **VRAM window takes priority over expansion ROM** at `$CC00–$CDFF`. If the firmware were to try to execute code from `$CC00–$CDFF`, it would read VRAM, not ROM. (It never does this — all code is in `$C800–$CBFF`.)

4. **R12/R13 display start uses only 11 bits** (`{R12[2:0], R13[7:0]}`). Upper bits of R12 are ignored by the renderer.

5. **Clone ROM differences**: Some Videx clone ROMs use different CRTC timing values (R3=`$2F`, R4=`$22`, R5=`$00`, R7=`$1D`). The card hardware doesn't care — it stores whatever the ROM writes. The renderer ignores R0–R8 timing registers.
