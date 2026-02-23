# Proposed Upstream Fixes for a2fpga_core

This document describes three changes to shared a2fpga_core files discovered during
Videx VideoTerm card emulation development. Each fix addresses a real bug or
architectural issue that affects any multi-card emulation scenario, not just Videx.

---

## Fix 1: Phase-Counter OE Cutoff for CPLD Bus Data Output Enable

**STATUS: VERIFIED.** Hardware-tested on A2N20v2 with Apple ][+. Pascal 1.3
boots 100% with all emulated cards enabled (Videx + SSC + Mockingboard + SuperSprite).

**File:** `boards/a2n20v2/hdl/bus/apple_bus.sv` (CPLD-based board variants)

**The problem:**

The A2FPGA emulates multiple cards through a single A2Bridge CPLD (XC9572XL).
When any emulated card responds to a bus read, the signal
`a2_bridge_bus_d_oe_n_o` tells the CPLD to drive data onto the Apple II bus.
This signal was a purely combinational assign:

```systemverilog
assign a2_bridge_bus_d_oe_n_o = ~(data_out_en_i & BUS_DATA_OUT_ENABLE);
```

The CDC denoise pipeline delays phi0 by ~6 clk_logic cycles (~93-111ns at
54 MHz). When cards deassert `rd_en_o` at the real phi0→phi1 transition, the
CPLD OE doesn't release until the CDC-delayed phi0 drop reaches the FPGA. This
creates ~100ns of bus contention where the CPLD continues driving the Apple II
data bus while the 6502 is already presenting the next address. A real slot
card's 74LS245 releases within ~10-20ns of phi0 dropping.

This ~100ns overlap is especially harmful during I/O write cycles ($C0xx) that
originate from C8-space instruction fetches. The Apple II motherboard's I/O
decode logic (GAL/PAL) responds to $C0xx with timing that is sensitive to bus
contention. ROM patch testing confirmed: I/O writes from C8 space break disk
loading; main RAM writes from C8 space work fine.

**Why registering OE doesn't work:** Hardware-tested — registering
`a2_bridge_bus_d_oe_n_o` causes system crashes (Apple II resets). The 1-cycle
delay extends CPLD drive INTO phi1 → bus contention with the 6502 → WORSE than
the ~100ns overlap. The combinational OE must remain; the fix is to cut it off
early using the phase counter.

**The fix:**

Use the existing phase counter (`phase_cycles_r`) to force-release OE before
the CDC-delayed phi0 drop:

```systemverilog
// Early OE cutoff: Release bus transceiver before CDC-delayed phi0 drop.
localparam int CDC_DELAY = 6;   // CDC denoise: 2 sync + 3 debounce + 1 FIFO
localparam int OE_MARGIN = 2;   // Cycles past estimated real phi0 drop
localparam int OE_CUTOFF = PHASE_COUNT - CDC_DELAY + OE_MARGIN;  // = 22

wire oe_early_cutoff = a2bus_if.phi0 && (phase_cycles_r >= OE_CUTOFF[5:0]);
assign a2_bridge_bus_d_oe_n_o = ~(data_out_en_i & BUS_DATA_OUT_ENABLE & ~oe_early_cutoff);
```

The phase counter resets on each CDC-delayed phi edge. Real phi0 drops at
approximately `PHASE_COUNT - CDC_DELAY` (= 20) counts into the phi0 half. The
cutoff fires at cycle 22, approximately 37ns after the estimated real phi0 drop.
IO_WRITE_DATA triggers at cycle 10 and completes by cycle 13, so all data is
latched to the bridge well before cutoff.

**Cost:** Negligible — one comparison, one AND gate.

**Benefit:** Eliminates ~60-70ns of unnecessary bus driving that previously
extended into phi1. Reduces the contention window from ~100ns to ~37ns,
matching real slot card behavior more closely.

**Risk:** Low. The 37ns post-phi0 margin is conservative — the 6502 latches data
before phi0 drops, so the data hold time is already satisfied. If OE_MARGIN=2
is too aggressive (cards fail to respond), it can be increased to 3 or 4. If
too conservative (Pascal still hangs), it can be reduced to 1.

**Applicability:** Only needed for CPLD-based boards (a2n20v2, a2n20v1,
a2n20v2-Enhanced). The a2mega board has direct bus access (no CPLD bridge) and
does not have this issue.

---

## Fix 2: INTC8ROM / is_iie Detection in apple_memory.sv

**File:** `hdl/memory/apple_memory.sv`

**The problem:**

The INTC8ROM soft switch is an Apple IIe-only mechanism. On the IIe, accessing
`$C3xx` with SLOTC3ROM=0 sets INTC8ROM=1, which routes `$C800-$CFFF` to the
internal 80-column firmware ROM instead of external cards.

On the Apple ][+, SLOTC3ROM is never set (the soft switch doesn't exist), so
SLOTC3ROM defaults to 0. The existing code unconditionally sets INTC8ROM=1 on
every `$C3xx` access:

```systemverilog
if (!a2mem_if.SLOTC3ROM && (a2bus_if.addr[15:8] == 8'hC3)) INTC8ROM <= 1'b1;
```

On a ][+, this means the first `PR#3` or any `$C3xx` access permanently sets
INTC8ROM=1. Since INTC8ROM=1 blocks `io_strobe_n` generation in the slotmaker
framework, ALL emulated cards' expansion ROM reads stop working -- not just
slot 3. This is a system-wide failure that affects any ][+ with any card in
slot 3.

A second issue: the original code had no `else` clause, so INTC8ROM was never
cleared when a different slot's `$Csxx` was accessed. On a real IIe, INTC8ROM
clears when any slot other than 3 is accessed in the `$C1xx-$C7xx` range.

**The fix:**

Add runtime ][+ vs IIe detection and gate INTC8ROM accordingly:

```systemverilog
// Runtime detection: IIe boot ROM writes to $C00x soft switches within
// milliseconds of startup. A ][+ never touches these addresses.
reg is_iie;
always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
    if (!a2bus_if.system_reset_n)
        is_iie <= 1'b0;
    else if (!a2bus_if.rw_n && (a2bus_if.phi1_posedge) &&
             (a2bus_if.addr[15:4] == 12'hC00) && !a2bus_if.m2sel_n)
        is_iie <= 1'b1;
end

// In the INTC8ROM/SLOTROM block:
if (is_iie && !a2mem_if.SLOTC3ROM && (a2bus_if.addr[15:8] == 8'hC3))
    INTC8ROM <= 1'b1;
else
    INTC8ROM <= 1'b0;   // Clear on non-C3 slot access (real IIe behavior)
SLOTROM <= a2bus_if.addr[10:8];
```

**Cost:** 1 register for `is_iie`, minor logic for the write detection.

**Benefit:** Fixes a hard bug where any ][+ accessing slot 3 permanently breaks
all expansion ROM reads system-wide. Also fixes the missing INTC8ROM clear on
IIe (non-C3 slot access should clear it).

**Risk:** Very low. The `is_iie` detection is conservative -- it only fires on
actual writes to `$C00x`, which the IIe boot ROM performs immediately. On a ][+,
`is_iie` stays 0 and INTC8ROM is never set, which exactly matches real ][+
hardware behavior (the ][+ has no INTC8ROM mechanism at all). On an IIe,
`is_iie` is set within milliseconds of boot and INTC8ROM works exactly as
before, with the addition of the correct `else` clear.

**Testing:** Verified on Apple ][+ hardware with Videx (slot 3), SSC (slot 2),
and Mockingboard (slot 4). All expansion ROMs function correctly. IIe behavior
unchanged (tested with IIe soft switch patterns).

---

## Fix 3: SLOTROM Guard on SSC Expansion ROM

**File:** `hdl/ssc/super_serial_card.sv`

**The problem:**

The SSC's expansion ROM enable (`ENA_C8S`) is controlled by the `C8S2` flag,
which is set on any `$C2xx` access and cleared on `$CFFF`. However, `C8S2` can
remain stale: if `$C2xx` is accessed and then another slot is selected without
an intervening `$CFFF`, `C8S2` stays set.

On real hardware with physical per-slot bus transceivers, a stale C8S2 doesn't
cause problems because each card's bus drivers are electrically independent. But
on the A2FPGA, where all emulated cards share one CPLD, a stale C8S2 means the
SSC drives the data bus for another slot's `$C800-$CFFF` reads, causing bus
contention in the CPLD's output mux.

The original code:

```systemverilog
assign ENA_C8S = {(C8S2 & !a2mem_if.INTCXROM), a2bus_if.addr[15:11]} == 6'b111001;
```

**The fix:**

Add a SLOTROM guard so the SSC only responds to `$C800-$CFFF` when slot 2 was
the most recently accessed `$Csxx` slot:

```systemverilog
assign ENA_C8S = ({(C8S2 & !a2mem_if.INTCXROM), a2bus_if.addr[15:11]} == 6'b111001)
                 && (a2mem_if.SLOTROM == 3'd2);
```

**Cost:** Minor additional logic (one 3-bit comparison).

**Benefit:** Prevents the SSC from driving the bus during another slot's C8-space
reads. This is defense-in-depth that's necessary in the shared-CPLD architecture
even with Fix 1 applied, because `C8S2` can remain stale across slot transitions
without `$CFFF` being accessed.

**Risk:** Very low. The SLOTROM register is already maintained by apple_memory.sv
and tracks which slot was most recently accessed in `$C1xx-$C7xx`. The guard
only prevents the SSC from responding when it demonstrably should not be
responding (another slot is active). SSC expansion ROM access works normally when
slot 2 is selected.

**Testing:** Verified with SSC (slot 2) and Videx (slot 3) both using C8-space
simultaneously. SSC expansion ROM reads work when SLOTROM=2, correctly inhibited
when SLOTROM=3 or other values.

---

## Fix 4: Videx Character ROM Halving (Optimization)

**File:** `hdl/video/apple_video.sv`

**The problem:**

The Videx character ROM stores 256 characters at 16 bytes each = 4 KB. However,
the upper 128 characters ($80-$FF) are simply the inverse (black-on-white vs
white-on-black) of the lower 128 ($00-$7F). Storing both halves wastes 1 BSRAM
block (pROM).

**The fix:**

Store only 128 characters (2 KB) and generate inverse characters in logic:

```systemverilog
// ROM lookup uses only low 7 bits (128 unique characters)
videxrom_a_r <= {char_code[6:0], scan_line[3:0]};

// Inverse generated by XOR with char[7]
wire pixel = videx_rom_data[bit_index] ^ char_code[7];
```

The cursor inversion is combined into the same XOR expression.

**Cost:** Trivial additional logic (one XOR gate per pixel).

**Benefit:** Saves 1 BSRAM block (pROM). On the GW2AR-18C with 46 total BSRAM
blocks, this reduces Videx's BSRAM cost from 4 blocks to 3 blocks (1 SDPB for
VRAM + 1 pROM for character ROM + 1 pROM for firmware ROM).

**Risk:** None. The upper-128 = inverse-of-lower-128 relationship is a property
of the Videx character set, not an approximation. Verified against physical Videx
output.

**Testing:** Verified character rendering on HDMI output matches physical Videx
for all 256 character codes, including inverse and cursor combinations.

---

## Fix 5: SSC C8S2 phi0 Qualification

**STATUS: COMMITTED (880a976).**

**File:** `hdl/ssc/super_serial_card.sv`

**The problem:**

The SSC's C8-space ownership flag (`C8S2`) is set/cleared in an `always` block
that monitors `$C2xx` and `$CFFF` accesses. The case block was not phi0-qualified:

```systemverilog
// Before (bug):
always @(posedge a2bus_if.clk_logic) begin
    if (!a2bus_if.system_reset_n) C8S2 <= 1'b0;
    else begin
        case (a2bus_if.addr[15:8])
            8'hC2: if (!a2mem_if.INTCXROM) C8S2 <= 1'b1;
            8'hCF: if (!a2mem_if.INTCXROM && a2bus_if.addr[7:0] == 8'hFF) C8S2 <= 1'b0;
        endcase
    end
end
```

When the Videx card (or any other card sharing the CPLD) transitions its
`rd_en_o` from active to tristate, the PCB bus transceiver creates real address
bus glitches. These glitches look like valid addresses to the FPGA at 54 MHz
sampling rate. Without phi0 qualification, the SSC's `$CFFF` detection
spuriously fires during these transients, clearing `C8S2` mid-SSC expansion ROM
execution → open bus → SSC FINIT crashes.

**The fix:**

Gate the entire case block with `a2bus_if.phi0`:

```systemverilog
// After (fix):
always @(posedge a2bus_if.clk_logic) begin
    if (!a2bus_if.system_reset_n) C8S2 <= 1'b0;
    else if (a2bus_if.phi0) begin
        case (a2bus_if.addr[15:8])
            8'hC2: if (!a2mem_if.INTCXROM) C8S2 <= 1'b1;
            8'hCF: if (!a2mem_if.INTCXROM && a2bus_if.addr[7:0] == 8'hFF) C8S2 <= 1'b0;
        endcase
    end
end
```

This is the same phi0 qualification pattern applied to `cfff_access` in the
Videx card. Bus transceiver glitches only occur outside phi0 (during
drive/tristate transitions at phi boundaries).

**Cost:** None — one additional gate.

**Benefit:** Prevents PCB bus transceiver glitches from clearing SSC expansion
ROM ownership mid-execution. This is critical for multi-card scenarios where
any card's rd_en_o transition can create glitches that affect other cards.

**Risk:** Very low. phi0 is the valid data phase of the Apple II bus cycle.
All address-sensitive logic should be qualified by phi0 to avoid responding
to transients during phi1.

**Testing:** With this fix, SSC FINIT progresses further (disk reads sometimes
complete, track 0 write appears). Full fix requires the OE cutoff (Fix 1) to
eliminate the remaining bus contention.

---

## Summary

| Fix | File | Type | Severity | Risk | Status |
|-----|------|------|----------|------|--------|
| 1. OE cutoff | apple_bus.sv | Bus timing | High (Pascal boot hang) | Low | **Verified** |
| 2. is_iie / INTC8ROM | apple_memory.sv | Bug fix | High (breaks all ][+ C8 reads) | Very low | Implemented |
| 3. SSC SLOTROM guard | super_serial_card.sv | Bug fix | Medium (SSC bus contention) | Very low | Committed |
| 4. Charrom halving | apple_video.sv | Optimization | Low (saves 1 BSRAM) | None | Committed |
| 5. SSC C8S2 phi0 | super_serial_card.sv | Bug fix | Medium (cross-card glitch) | Very low | Committed |

Fixes 1-5 are independent and can be applied in any order.

Fixes 1 and 2 are the most impactful: Fix 2 is a hard bug on any ][+ system
with a card in slot 3, and Fix 1 eliminates bus contention during I/O writes
from C8 space that breaks disk loading during Pascal boot (and potentially
any other timing-sensitive bus interaction).

Fix 5 is the same class of bug as the Videx `cfff_access` phi0 fix — both
protect address-sensitive ownership logic from PCB bus transceiver glitches.
Any future card emulations that use C8-space ownership should apply the same
phi0 qualification pattern.

Note: The a2mega board has direct bus access (no CPLD bridge) and is not
affected by Fix 1 or Fix 5. Fixes 2-4 apply to all boards.
