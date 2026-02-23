# Pascal Boot Debug Summary

## Hardware Configuration
- Apple ][+ test system
- Slot 0: RamX 128K (physical)
- Slot 2: A2FPGA emulates SSC (BYTES[5,7,11]=$38,$18,$01 → Pascal type 6, same as Videx!)
- Slot 3: A2FPGA emulates Videx VideoTerm
- Slot 4: A2FPGA emulates Mockingboard
- Slot 6: Disk II controller (physical), FloppyEmu attached
- Slot 7: A2FPGA emulates SuperSprite
- Pascal disk: Apple Pascal 1.3 (UCSD p-System Interpreter II nucleus)

## Key Facts Established
- Pascal v1.1–1.3: same BIOS, same slot scan, same p-System II nucleus
- Disk II has NO C8 ROM
- Pascal detects Videx as **type 6 (firmware)** via bytes[5,7,11]=$38,$18,$01
- Pascal also detects SSC (slot 2) as **type 6 (firmware)** — same bytes
- Bus arbiter priority: Videx > SSC > SuperSprite > Mockingboard
- Mockingboard and SuperSprite have NO C8 expansion ROM logic
- Pascal FINIT (Videx) called once during boot step 3, before disk I/O
- SSC FINIT called at runtime (after SYSTEM.PASCAL loads), NOT during boot
- Stack is wiped between Videx FINIT and disk I/O — no register corruption path

## Critical Comparison: What Works vs What Doesn't
| Configuration | Pascal result |
|---|---|
| A2FPGA normal mode (all reads active) | HANGS — see test results below |
| A2FPGA shadow mode (rd_en_o=0) | WORKS — Pascal boots normally |
| A2DVI v4.4 in slot 3 | WORKS — even though it drives the bus with Videx emulation |
| Videx disabled (slot 3 = 00) | WORKS — Pascal uses SSC as console |
| Physical Videx card | WORKS (confirmed via shadow mode rendering) |

### Key insight from A2DVI comparison
A2DVI v4.4 drives the bus with its emulated Videx AND Pascal works.
A2DVI FAILS VIDEX_DIAG tests T08 (exp ROM) and T09-T16 (VRAM) — returns open bus for those reads.
A2FPGA PASSES T08-T20 — actively serves expansion ROM and VRAM reads.
**A2FPGA is over-responsive: serves C8-space reads that real hardware and A2DVI don't serve.**

## VIDEX_DIAG Cross-Platform Results
| Test | Physical Videx | A2DVI v4.4 | A2FPGA |
|------|---------------|------------|--------|
| T01-T07 (slot ROM, CRTC) | Mostly OK | OK | OK |
| T08 (exp ROM read-back) | FAIL ($FF) | FAIL (open bus) | OK |
| T09-T16 (VRAM read-back) | FAIL (garbage) | FAIL (open bus) | OK |
| T17-T20 | OK | OK | OK |
| T21 (multi-slot) | — | — | FAIL |

## Pascal Boot Sequence (Pascal v1.1 BIOS, same for v1.3)
1. Disk II boots from disk ($C600) — loads Pascal nucleus to language card RAM
2. Pascal BIOS slot scan — detects Videx (slot 3, type 6) and SSC (slot 2, type 6)
3. Console FINIT (slot 3 Videx) — JMP $C311 → JMP $C800 → INIT_FULL → CRTC programmed → 80-col switch → AN0 on → returns. c8_owned=1 after.
4. JMP $FEF5 — P-machine starts from language card RAM
5. P-machine calls RIINIT (slot 2 SSC FINIT) — SSC's C8 expansion ROM runs
6. P-machine loads SYSTEM.PASCAL from disk (track 0 area)
7. SYSTEM.PASCAL initializes — writes volume directory update (track 0 write = normal)
8. Pascal command interpreter starts

## Root Causes Found

### 1. cfff_access Not phi0-Qualified (Non-Determinism)
**ROOT CAUSE OF NON-DETERMINISM**: `cfff_access` in `videx_card.sv` was not
phi0-qualified. Address bus transients during phi1 spuriously fired cfff_access
→ cleared c8_owned → open bus for $C8xx fetches → 6502 executes $FF bytes.

**FIX**: `wire cfff_access = a2bus_if.phi0 && (a2bus_if.addr == 16'hCFFF);`

**Result**: 12/12 boots deterministic. Non-determinism completely eliminated.

### 2. SSC C8S2 Not phi0-Qualified (Cross-Card Interference)
**MECHANISM**: When Videx rd_en_o transitions from active to tristate, the PCB
bus transceiver creates real address bus glitches that the FPGA sees as valid
addresses. SSC's C8S2 had unqualified $CFFF logic → C8S2 cleared mid-SSC
expansion ROM execution → open bus → SSC FINIT crashes.

**FIX**: `else if (a2bus_if.phi0)` gate around entire C8S2 case block in
super_serial_card.sv. Same phi0 qualification as cfff_access fix.

**Evidence**: State 2 (SSC phi0 fix) → disk reads sometimes completed, track 0
write appeared. State 1 (no fix) → always track 0 constant retry.

### 3. CPLD Bus OE Extended Driving (Primary Remaining Issue)
**ROOT CAUSE OF DETERMINISTIC HANG**: The CPLD bus data OE
(`a2_bridge_bus_d_oe_n_o`) was purely combinational, tracking `data_out_en_i`
directly. When cards deassert `rd_en_o` at the phi0→phi1 transition, the CPLD OE
doesn't release until the CDC-delayed phi0 drop reaches the FPGA — creating
~100ns of bus contention where the CPLD drives the Apple II data bus while the
6502 is already in its next cycle.

This ~100ns overlap is especially harmful during I/O write cycles ($C0xx) that
originate from C8-space instruction fetches, because the Apple II motherboard's
I/O decode logic (GAL/PAL) responds to $C0xx with timing that is sensitive to
bus contention. Main RAM writes from C8 space are unaffected.

**FIX**: Phase-counter OE cutoff in `apple_bus.sv`. OE is forcibly released at
`phase_cycles_r >= 22` during phi0 — approximately 37ns after the estimated
real phi0 falling edge. This eliminates ~60-70ns of unnecessary bus driving.

```systemverilog
localparam int CDC_DELAY = 6;   // CDC denoise: 2 sync + 3 debounce + 1 FIFO
localparam int OE_MARGIN = 2;   // Cycles past estimated real phi0 drop
localparam int OE_CUTOFF = PHASE_COUNT - CDC_DELAY + OE_MARGIN;  // = 22

wire oe_early_cutoff = a2bus_if.phi0 && (phase_cycles_r >= OE_CUTOFF[5:0]);
assign a2_bridge_bus_d_oe_n_o = ~(data_out_en_i & BUS_DATA_OUT_ENABLE & ~oe_early_cutoff);
```

**Status**: IMPLEMENTED, awaiting hardware test.

**Why shadow mode works**: Videx rd_en_o=0 → no bus transceiver driving → no
OE-to-tristate transitions → no bus contention during I/O writes.

**Why registering CPLD OE doesn't work**: Hardware-tested — 1-cycle delay extends
CPLD drive INTO phi1 → bus contention with 6502 → Apple II resets. WORSE than
the current problem. The combinational OE is correct design; the fix is to cut
it off early using the phase counter.

## ROM Patch Test Results (Binary Search)

| Test | $C800 code | Write target | Disk result |
|------|-----------|-------------|-------------|
| H | full INIT | CRTC+VRAM+AN0+screen holes | 0,1,2,3,4,0 hang |
| I | RTS (nothing) | — | all tracks, works |
| J | STA $C059 | soft switch | 0-4, hang |
| K | full INIT minus AN0 | CRTC+VRAM+screen holes | 0,1,2,3,4,0 hang |
| L | STA $0400 | main RAM | all tracks, works |
| M | CRTC R/W test | $C0B0/$C0B1 + $0400/$0401 | 2 reboots then all tracks |

**Key finding**: I/O writes ($C0xx) from C8 space break disk loading. Main RAM
writes ($0400) from C8 space work fine. Test M's non-determinism (2 reboots then
success) suggests a narrow timing margin in I/O write bus contention.

## SSC vs Videx Comparison

| Aspect | SSC | Videx |
|--------|-----|-------|
| C8-space gating | `card_io_strobe` (includes `io_strobe_n` / INTC8ROM) | `rom_c8_active && phi0` (bypasses `io_strobe_n`) |
| ROM data_o | Combinational (zero latency) | 2-cycle pipeline (37ns stale data) |
| C8 ownership guard | `SLOTROM == 2` | Self-clearing `c8_owned` |
| CFFF clearing | phi0-qualified, within case block | phi0-qualified exact match |
| Other-slot clearing | No (relies on SLOTROM guard) | Yes, monitors $C1xx-$C7xx |

The `io_strobe_n` bypass was necessary because INTC8ROM was permanently set on
Apple ][+ (slot 3 + SLOTC3ROM=0 default). The `is_iie` fix resolves this root
cause. On ][+ with is_iie=0, INTC8ROM stays 0, so switching Videx to
`card_io_strobe` would not change behavior — but would add INTC8ROM protection
for future IIe support (added as TODO in code).

## Current Code State

All changes in working copy, ready for hardware test build:

| File | Change | Status |
|------|--------|--------|
| `apple_bus.sv:305-310` | Phase-counter OE cutoff | **Uncommitted** |
| `apple_memory.sv:76-82` | is_iie detection | **Uncommitted** |
| `apple_memory.sv:152-163` | INTC8ROM gated by is_iie | **Uncommitted** |
| `super_serial_card.sv:120` | C8S2 phi0 qualification | **Committed** (880a976) |
| `videx_card.sv:95` | cfff_access phi0 qualification | **Committed** |
| `videx_card.sv:311-316` | Comment update + TODO | **Uncommitted** |
| `videx_rom.hex` | Original ROM restored | All test patches reverted |
| `slots.hex` | `00 00 00 05 00 00 00 00` | Videx only (no SSC) |

VRAM read-back: DISABLED (commented out). Real Videx and A2DVI both return open
bus for VRAM reads; only scanner reads VRAM.

## Resolved Questions

1. **What causes disk loop (State 1)?** → I/O writes from C8 space during INIT
   create bus contention via extended CPLD OE driving (~100ns into phi1). This
   corrupts subsequent bus cycles including Disk II I/O.

2. **Why did SSC phi0 fix cause spontaneous reboots (State 2)?** → The SSC phi0
   fix allowed SSC FINIT to progress further, which meant MORE C8-space I/O writes
   (SSC expansion ROM doing UART initialization), creating more bus contention
   opportunities. The underlying OE timing issue amplified the instability.

3. **What does A2DVI do differently?** → A2DVI has its own bus transceiver (not
   shared CPLD). Its OE timing is controlled directly by its own FPGA, without the
   CDC pipeline delay. Also, A2DVI doesn't serve C8-space reads for VRAM or expansion
   ROM (returns open bus), reducing the total bus driving time.

4. **Does SSC access $CFFF mid-execution?** → No. SSC's expansion ROM code does not
   contain STA $CFFF. The issue was phi0-unqualified CFFF detection in SSC's C8S2
   logic, triggered by PCB bus transceiver glitches.

5. **Videx c8_owned vs SSC ENA_C8S interaction?** → Not the root cause. Self-clearing
   c8_owned correctly releases ownership on other-slot access. The problem is bus
   transceiver OE timing, not ownership logic.

## Hardware Test Plan

1. Build FPGA bitstream with OE cutoff fix + all current fixes
2. Basic test: PR#3 → 80-col, VIDEX_DIAG T01-T20
3. Pascal test: PR#6 with Pascal 1.3 disk
4. If Pascal still hangs: reduce OE_MARGIN from 2 to 1 (more aggressive cutoff)
5. If cards fail to respond: increase OE_MARGIN to 3 or 4
6. Once Videx works: add SSC back and retest Pascal boot
