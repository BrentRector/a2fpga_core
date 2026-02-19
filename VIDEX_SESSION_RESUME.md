# Videx VideoTerm Implementation — Session Resume Prompt

## Context for New LLM Session

You are continuing work on the A2FPGA project — an FPGA-based companion card for vintage Apple II computers that provides HDMI video output, audio, and peripheral card emulation. The project is written in SystemVerilog and targets GoWin GW2AR-18C FPGAs.

This session has two goals:

1. **Evaluate combining shadow rendering and emulation** — We originally built a *passive* Videx shadow rendering pipeline (snoops bus writes to render Videx 80-column text on HDMI). Now we're adding *active* Videx emulation (a virtual card module that responds on the bus). Can/should the shadow and emulation functionality be combined into a single, more optimal Videx device module?

2. **Encapsulate Videx as a configurable module** — All Videx implementation should be encapsulated such that A2FPGA firmware can be built with or without Videx support, following the same pattern as the Mockingboard and Super Serial Card conditional builds.

---

## Repository Structure

```
/home/user/a2fpga_core/
├── hdl/
│   ├── memory/
│   │   ├── apple_memory.sv      # Main memory controller, Videx shadow capture (VIDEX_SUPPORT generate block)
│   │   └── a2mem_if.sv          # Memory interface, includes VIDEX_MODE, VIDEX_CRTC_R* signals
│   ├── video/
│   │   ├── apple_video.sv       # Video renderer, VIDEX_LINE pipeline (VIDEX_SUPPORT generate block)
│   │   └── videx_charrom.hex    # Videx character ROM (4 KB, 256 chars × 16 bytes)
│   ├── videx/
│   │   ├── videx_card.sv        # (TO CREATE) Virtual Videx card module — bus responses
│   │   └── videx_rom.hex        # Videx VideoTerm firmware ROM 2.4 (1 KB)
│   ├── slots/
│   │   ├── slotmaker.sv         # Virtual slot controller, address decode, card config
│   │   ├── slot_if.sv           # Slot interface definition (slot, card_id, select signals)
│   │   └── slots.hex            # Current: 00 00 03 00 02 04 00 01 (slot 3 = empty → will be 05)
│   ├── mockingboard/
│   │   └── mockingboard.sv      # Mockingboard card (ENABLE, ID parameters)
│   ├── ssc/
│   │   └── super_serial_card.sv # Super Serial Card (ENABLE, ID, IRQ_ENABLE parameters)
│   └── supersprite/
│       └── supersprite.sv       # SuperSprite card (ENABLE, ID parameters)
├── boards/
│   ├── a2n20v2/hdl/top.sv       # Main board: VIDEX_SUPPORT=1, all cards instantiated
│   ├── a2n20v2-Enhanced/hdl/top.sv # Enhanced board: VIDEX_SUPPORT=0
│   └── (a2n20v1, a2mega, a2n9, a2p25) # Other boards: VIDEX_SUPPORT=0
├── tools/
│   └── gen_videx_rom.py         # Generates videx_charrom.hex from A2DVI font data
├── VIDEX_IMPLEMENTATION_SPEC.md # Complete hardware spec for videx_card.sv (~2000 lines)
├── VIDEX_EMULATION_EVALUATION.md # Architectural evaluation of 3 approaches (Approach B chosen)
├── VIDEX_SUPPORT.md             # Documentation of passive shadow monitoring
└── VIDEX_SESSION_RESUME.md      # This file
```

---

## Existing Architecture Summary

### Current State: Passive Shadow (Working, Deployed)

The existing Videx support is **passive** — it snoops bus writes made by an external Videx-compatible card (e.g., A2DVI v4.4 in slot 3) and renders the 80-column text on HDMI.

**Shadow data capture** (`apple_memory.sv`, generate block `videx_gen`, lines 180–262):
- Snoops CRTC register writes at `$C0B0`/`$C0B1` → stores R9–R15 in `a2mem_if.VIDEX_CRTC_R*`
- Snoops VRAM writes at `$CC00`–`$CDFF` → stores in 2 KB `sdpram32` (write port: bus, read port: video scanner)
- Tracks VRAM bank selection from `addr[3:2]` on any `$C0Bx` access
- Sets `videx_mode_r = 1` on first CRTC write (auto-detection)

**Shadow rendering** (`apple_video.sv`, VIDEX_LINE pipeline):
- 80 columns × 24 rows × 9 scanlines = 560 × 216 active pixels, doubled to 560 × 432
- Division by 9 via multiply-shift approximation (exact for 0–215)
- Videx character ROM (4 KB in distributed SSRAM): `{vram_byte[7:0], scanline[3:0]}`
- Hardware scrolling via R12/R13 (circular 2 KB buffer, wraps at 2048)
- MC6845 cursor with 4 blink modes, scanline range from R10/R11
- 6-stage pipeline: VIDEX_0 through VIDEX_5

### Planned Addition: Active Emulation (Not Yet Built)

A new `videx_card.sv` module that actively responds on the Apple II bus, enabling Videx 80-column support on Apple ][/][+ systems that have **no external Videx card**:

**What the card provides (gaps the shadow cannot fill):**
1. **Firmware ROM** — Serves Videx VideoTerm ROM 2.4 bytes at `$C300`–`$C3FF` (slot ROM) and `$C800`–`$CBFF` (expansion ROM). 1 KB stored in BSRAM.
2. **CRTC register read-back** — R14/R15 readable via `$C0B1` for card detection and cursor queries.
3. **VRAM read-back** — CPU reads of `$CC00`–`$CDFF` return stored data. Essential for programs like Apple Writer II, WordStar.
4. **Expansion ROM ownership protocol** — Set on `$C300`–`$C3FF` access, clear on `$CFFF`.
5. **VRAM bank selection** — `addr[3:2]` latched on any `$C0Bx` access.

**Architectural decision (documented in VIDEX_EMULATION_EVALUATION.md):**
Approach B was chosen — build upon the existing VIDEX_LINE shadow path rather than translating to IIe TEXT80. The shadow capture logic continues to work because bus writes made during card emulation are visible on the bus for the shadow to snoop.

---

## Conditional Build Patterns (Existing Cards)

All existing cards follow the same pattern:

### Module Parameters
```systemverilog
module Mockingboard #(
    parameter bit [7:0] ID = 2,
    parameter bit ENABLE = 1'b1
) (
    a2bus_if.slave a2bus_if,
    slot_if.card slot_if,
    output [7:0] data_o,
    output rd_en_o,
    output irq_n_o,
    ...
);
```

### Card Enable Logic (inside module)
```systemverilog
reg card_enable;
always @(posedge a2bus_if.clk_logic) begin
    if (!slot_if.config_select_n) begin
        if (slot_if.slot == 3'd0)
            card_enable <= 1'b0;  // disable during config
        else if (slot_if.card_id == ID && ENABLE)
            card_enable <= 1'b1;
        else
            card_enable <= 1'b0;
    end
end

wire card_sel = card_enable && (slot_if.card_id == ID) && a2bus_if.phi0;
wire card_dev_sel = card_sel && !slot_if.dev_select_n;
wire card_io_sel = card_sel && !slot_if.io_select_n;
```

### Top-Level Instantiation (`boards/a2n20v2/hdl/top.sv`)
```systemverilog
// Parameters at module level
parameter bit MOCKINGBOARD_ENABLE = 1,
parameter bit [7:0] MOCKINGBOARD_ID = 2,

// Instantiation
Mockingboard #(
    .ENABLE(MOCKINGBOARD_ENABLE),
    .ID(MOCKINGBOARD_ID)
) mockingboard (
    .a2bus_if(a2bus_if),
    .slot_if(slot_if),
    .data_o(mb_d_w),
    .rd_en_o(mb_rd),
    .irq_n_o(mb_irq_n),
    .audio_l_o(mb_audio_l),
    .audio_r_o(mb_audio_r)
);
```

### Slot Configuration
- `slots.hex`: 8 bytes mapping slots 0–7 to card IDs (0 = empty)
- Current: `00 00 03 00 02 04 00 01` (slot 2=SSC, slot 4=Mockingboard, slot 5=DISK_II, slot 7=SuperSprite)
- **Slot 3 is currently empty** — this is where the Videx card would go

### Data Output Mux
```systemverilog
assign data_out_en_w = ssp_rd || mb_rd || ssc_rd;
assign data_out_w = ssc_rd ? ssc_d_w :
    ssp_rd ? ssp_d_w :
    mb_rd ? mb_d_w :
    a2bus_if.data;
```

### IRQ Mux
```systemverilog
assign irq_n_w = mb_irq_n && vdp_irq_n && ssc_irq_n;
// Note: Videx has NO IRQ — it does not generate interrupts
```

---

## Goal 1: Shadow and Emulation Architecture — DECIDED

### Decision: Shadow and card work together, no standalone shadow mode

The shadow capture in `apple_memory.sv` and the card module in `videx_card.sv` both maintain CRTC registers and VRAM state. This redundancy is intentional — each copy serves a different purpose:

- **Shadow CRTC registers** → feed `a2mem_if.VIDEX_CRTC_R*` → drive the `VIDEX_LINE` renderer
- **Card CRTC registers** → serve CPU read-back (R14/R15) for card detection and cursor queries
- **Shadow VRAM** (`sdpram32`) → feed the video scanner read port for rendering
- **Card VRAM** (new BSRAM) → serve CPU read-back for programs that read VRAM

Both capture the same bus writes. The shadow snoops writes that the card also processes — the card's bus activity is visible to the shadow.

```
videx_card.sv (new)                 apple_memory.sv (unchanged)
  - Firmware ROM (1 KB BSRAM)         videx_gen generate block
  - CRTC register file (R0-R15)       - CRTC reg snooping → a2mem_if.VIDEX_CRTC_R*
  - VRAM for CPU read-back (2 KB)     - VRAM write snooping (2 KB) → scanner read port
  - Bus response logic                - Bank selection snooping
  - Expansion ROM ownership           - VIDEX_MODE flag
       ↓                                    ↓
  data_o / rd_en_o → bus mux         apple_video.sv
  (ROM, CRTC readback, VRAM readback)  VIDEX_LINE pipeline → HDMI
```

**There is no standalone "shadow-only" mode.** There is no viable use case for running both an A2FPGA card and a separate Videx card in the same system. `VIDEX_SUPPORT` is coupled with `VIDEX_CARD_ENABLE` — when the card is enabled, the shadow is enabled; when the card is disabled, the shadow is disabled. `apple_memory.sv` and `apple_video.sv` require **no changes**.

---

## Goal 2: Configurable Videx Module — DECIDED

### Decisions
1. **Card ID = 5**, slot 3 (standard Videx slot)
2. Follows Mockingboard/SSC `slot_if.card` pattern with `ID` and `ENABLE` parameters
3. `VIDEX_SUPPORT` is coupled with `VIDEX_CARD_ENABLE` — no independent shadow mode
4. Slot assignment goes through `slots.hex` and `slotmaker`
5. Card includes `rom_en_o` output following SSC pattern (exported for status, not consumed by top.sv)

### What Needs to Happen
1. **Create `hdl/videx/videx_card.sv`** — New module implementing `slot_if.card`, following the Mockingboard/SSC pattern
2. **Modify `boards/a2n20v2/hdl/top.sv`** — Add `VIDEX_CARD_ENABLE`, `VIDEX_CARD_ID` parameters; instantiate the card; add to bus mux; couple `VIDEX_SUPPORT` with `VIDEX_CARD_ENABLE`
3. **Modify `hdl/slots/slots.hex`** — Assign Videx card ID 5 to slot 3

Other boards (`a2n20v2-Enhanced`, `a2n20v1`, `a2mega`, `a2n9`, `a2p25`) already pass `VIDEX_SUPPORT(0)` or omit it — no changes needed.

### Board Support Matrix

`VIDEX_SUPPORT` and `VIDEX_CARD_ENABLE` are coupled — shadow rendering is always active when the card is enabled, and always disabled when the card is disabled. The `VIDEX_SUPPORT` parameter passed to `apple_memory` and `apple_video` is set to `VIDEX_CARD_ENABLE`.

| Board | VIDEX_CARD_ENABLE | Notes |
|-------|-------------------|-------|
| a2n20v2 | 1 | Full Videx emulation + shadow rendering |
| a2n20v2-Enhanced | 0 | No Videx (already VIDEX_SUPPORT=0) |
| a2n20v1 | 0 | No Videx |
| a2mega | 0 | No Videx |
| a2n9 | 0 | No Videx |
| a2p25 | 0 | No Videx |

---

## Key Technical Details for Implementation

### BSRAM Budget
- GW2AR-18C: 46 total blocks, 40 used (87%), **6 free**
- Videx card needs: 1 block (firmware ROM) + 1 block (VRAM read-back) = **2 blocks minimum**
- Remaining after card: 4 blocks

### Slot Interface Signals
```systemverilog
interface slot_if ();
    logic [2:0] slot;
    logic [7:0] card_id;
    logic io_select_n;    // $C100-$C7FF (slot ROM space)
    logic dev_select_n;   // $C080-$C0FF (device I/O space)
    logic io_strobe_n;    // $C800-$CFFF (expansion ROM space)
    logic config_select_n;
    logic [31:0] card_config;
    logic card_enable;
endinterface
```

### Address Decoding for Videx (Slot 3)
- `$C0B0`–`$C0BF`: Device I/O (CRTC registers + bank select) — `dev_select_n`
- `$C300`–`$C3FF`: Slot ROM — `io_select_n`
- `$C800`–`$CFFF`: Expansion ROM + VRAM window — `io_strobe_n`
- VRAM window: `$CC00`–`$CDFF` (within expansion ROM range)

### Memory Interface Signals (a2mem_if)
```systemverilog
// Already defined for Videx shadow:
logic VIDEX_MODE;
logic [7:0] VIDEX_CRTC_R9, VIDEX_CRTC_R10, VIDEX_CRTC_R11;
logic [7:0] VIDEX_CRTC_R12, VIDEX_CRTC_R13, VIDEX_CRTC_R14, VIDEX_CRTC_R15;
```

---

## Reference Documents

Read these files for complete details:
- `VIDEX_IMPLEMENTATION_SPEC.md` — Complete hardware behavior spec (~2100 lines, includes full annotated 6502 disassembly)
- `VIDEX_EMULATION_EVALUATION.md` — Architectural analysis of 3 approaches, Approach B recommended
- `VIDEX_SUPPORT.md` — Documentation of existing passive shadow

---

## What Has NOT Been Built Yet

- `hdl/videx/videx_card.sv` — Does not exist. Must be created.
- `boards/a2n20v2/hdl/top.sv` — Not yet modified for Videx card instantiation.
- `hdl/slots/slots.hex` — Still has slot 3 as empty (`00`), needs to be changed to `05`.
- `apple_memory.sv` and `apple_video.sv` require **no changes** — shadow code stays as-is.
- The passive shadow rendering and character ROM generation are complete and working.
- All specification and evaluation documents are complete and updated.

---

## Summary of Prior Session Work

### Session 1: Shadow Pipeline and Specification
1. Created the Videx shadow rendering pipeline (passive monitoring of external Videx cards)
2. Generated the Videx character ROM from A2DVI font data
3. Wrote comprehensive implementation specification for the virtual Videx card
4. Evaluated 3 architectural approaches; recommended Approach B (build on shadow path)
5. Obtained and verified the Videx VideoTerm ROM 2.4 firmware image
6. Created complete annotated 6502 disassembly of the firmware ROM
7. Documented character ROM anomalies (space char artifact, control code graphics, slashed zero, DEL checkerboard, true descenders, inverse half verification)

### Session 2: Architecture Decisions and Spec Updates
8. Decided shadow and card architecture: card adds bus responses, shadow stays unchanged in `apple_memory.sv`
9. Decided `VIDEX_SUPPORT` is coupled with `VIDEX_CARD_ENABLE` — no standalone shadow mode
10. Decided Card ID = 5, slot 3, following Mockingboard/SSC `slot_if.card` pattern
11. Updated `VIDEX_IMPLEMENTATION_SPEC.md` with `slot_if.card` interface, selection signals, integration instructions
12. Updated `VIDEX_SESSION_RESUME.md` with decided architecture and implementation plan
13. Created implementation plan for `videx_card.sv`, `top.sv` modifications, and `slots.hex` update
