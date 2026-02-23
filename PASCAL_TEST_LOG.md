# Pascal Boot Test Log

Hardware: Apple ][+, A2FPGA (a2n20v2) in slot 3, physical Disk II in slot 6, FloppyEmu
Emulated cards: Videx (slot 3), SSC (slot 2), Mockingboard (slot 4), SuperSprite (slot 7)

## Baseline Facts

- DOS 3.3 boot: ALWAYS works
- PR#3 (80-col mode): ALWAYS works
- VIDEX_DIAG (all tests T01-T20): ALWAYS passes
- Shadow mode (Videx rd_en_o=0, rom_en_o=0): Pascal ALWAYS works
- The problem is ONLY Pascal boot with Videx actively driving the bus

## Test Results

### Test A1 — 2026-02-22 — State 2 baseline
**Config:** cfff_access phi0 (Videx) + C8S2 phi0 (SSC) + SLOTROM guard (SSC) + apple_bus original
**SSC:** Enabled (slot 2, card_id=3)
**Videx:** Normal mode (rd_en_o active)

**Procedure:** Booted DOS 3.3 first. Loaded VIDEX_DIAG. PR#3 switched to 80-col.
Ran VIDEX_DIAG in 80-col mode — all tests passed. Then inserted Pascal disk 1
and typed PR#6 to boot Pascal while still in 80-col mode.

**Result:** HANG
- Screen switched from 80-col to 40-col (boot ROM reset clears AN0)
- Screen switched back to 80-col (Pascal detected Videx, re-enabled AN0)
- Previous VIDEX_DIAG output erased (Pascal cleared VRAM)
- Cursor appeared top-left (Pascal initialized cursor position)
- NO TEXT printed (never reached "APPLE PASCAL" banner)
- FloppyEmu: constant READs to track 00 (SYSTEM.PASCAL load retry loop)

**Analysis:** Pascal successfully detected Videx (80-col switch), initialized it
(screen clear, cursor), but failed during SYSTEM.PASCAL disk loading. The track 00
retry means disk reads are happening but data is corrupted or disk BIOS is not
properly initialized. Physical Disk II in slot 6 is unrelated to A2FPGA emulation.

---

### Test CPLD_OE — 2026-02-22 — Registered CPLD OE (DISPROVEN)
**Config:** Same as A1 + registered a2_bridge_bus_d_oe_n_o in apple_bus.sv
**Result:** CRASH — massive failure. Apple II resets repeatedly before reaching
80-col mode. 1 out of 5 attempts briefly showed 80-col before crash.
DOS 3.3 + VIDEX_DIAG worked fine.
**Conclusion:** Registering CPLD OE causes bus contention during phi1. REJECTED.

---

### Test B — 2026-02-22 — SSC Disabled
**Config:** Same as A1 but slots.hex slot 2 = 00 (SSC disabled)
**SSC:** DISABLED
**Videx:** Normal mode (rd_en_o active)

**Procedure:** Same as A1 — DOS, VIDEX_DIAG, PR#3, then PR#6 to Pascal.

**Result:** HANG — same symptom as A1
- Screen stays in 80-col mode (no 40-col transition — correction from A1)
- Screen clears top to bottom, previous VIDEX_DIAG output erased
- Cursor appeared top-left, blinking
- NO TEXT printed
- FloppyEmu: constant READs to track 00

**Conclusion:** SSC is NOT involved in the Pascal hang. The problem is purely
between the Videx card and Pascal boot. All SSC-related fixes (phi0, SLOTROM
guard) are irrelevant to this bug.

---

### Test D — 2026-02-22 — Videx ONLY (all other cards disabled)
**Config:** slots.hex = 00 00 00 05 00 00 00 00 (only Videx in slot 3)
**SSC:** DISABLED | **Mockingboard:** DISABLED | **SuperSprite:** DISABLED
**Videx:** Normal mode (rd_en_o active)

**Result:** HANG — same symptom
- Screen stays 80-col, clears, cursor top-left, no text
- FloppyEmu behavior: ~75% of boots show constant track 00 reads,
  ~25% show NO reads at all (hang before disk access begins)
- The no-reads variant means Pascal sometimes hangs before reaching disk I/O

**Conclusion:** The problem is 100% the Videx card driving the bus. No other
emulated card is involved. Combined with shadow mode (rd_en_o=0) working
perfectly, the issue is specifically in the DATA the Videx returns or WHEN
it drives — not cross-card interference, not CPLD glitches, not SSC.

---

### Test E — 2026-02-22 — WRITE_COUNT=5 (stale data window) (DISPROVEN)
**Config:** Same as Test D (Videx only) + apple_bus.sv WRITE_COUNT = CYCLE_COUNT/10 (=5)
**Hypothesis:** Stale data window (~185-260ns) where CPLD OE is active but holds old
GPIO value ($FF). Reducing WRITE_COUNT from 10 to 5 increases timing margin from ~19ns
to ~111ns, eliminating marginal stale reads during Videx INIT instruction fetches.

**Result:** HANG — no change whatsoever. Same symptom as Test D.

**Conclusion:** Stale data window timing is NOT the root cause. Reverted to
WRITE_COUNT = CYCLE_COUNT / 5 (=10). The bus transceiver data latching timing
is not the issue — a 5x improvement in margin produced zero behavioral change.

---

### Test F — 2026-02-22 — PASCAL_INIT = RTS (ROM patch)
**Config:** Same as Test D (Videx only) + videx_rom.hex offset 0x311 changed from
$4C (JMP $C800) to $60 (RTS). PASCAL_INIT returns immediately without entering
expansion ROM. Zero C8-space instruction fetches during INIT.

**Hypothesis:** The burst of hundreds of consecutive C8-space reads during INIT
(CRTC programming + screen clear + AN0 set) is the root cause. Making INIT a no-op
eliminates all expansion ROM bus driving during the Pascal boot sequence.

**Expected side effects:** No 80-col switch (AN0 not set), no CRTC programming,
no VRAM clear. Display stays in 40-col mode. Disk loading is independent of display.

**What to look for:**
- FloppyEmu disk activity: reads to tracks 0,1,2,3,4+ = SUCCESS (disk load works)
- FloppyEmu stuck on track 00 = SAME FAILURE (problem is elsewhere)
- Display: should stay 40-col (confirms ROM patch is active)

**Result:** PARTIAL SUCCESS — disk reads progressed dramatically!
- Test F1 (from 80-col via PR#3): PR#6 keeps 80-col mode. Pascal cleared 80-col screen
  (VIDEX_DIAG results erased). Cursor to top left. Disk reads from track 00 to 25.
  Reads stopped. No further output. Hang.
- Test F2 (cold boot to Pascal): 40-col mode initially. Same reads from track 00 to 25.
  Reads stopped. Cursor changed from large 40-col flashing block to thin (~1 pixel)
  horizontal line, non-flashing. May have switched to 80-col mode. Hang.

**Analysis:**
- INIT=RTS fixed the disk loading! Reads now progress 0→25 instead of stuck on track 0.
- The screen clearing in F1 means PASCAL_WRITE's C8 code executed (clear screen worked).
- The cursor change in F2 means some Videx C8 code executed (cursor/display mode changed).
- The hang occurs AFTER disk loading, during p-machine startup when PASCAL_WRITE enters
  C8 space for text output. INIT's C8 burst was the FIRST problem; WRITE's C8 access
  is the SECOND problem.
- NOTE: PR#6 does NOT switch to 40-col mode when already in 80-col.

**Conclusion:** C8-space bus driving causes Pascal failures. INIT=RTS eliminated the
first failure (disk load). Now PASCAL_WRITE's C8 access causes the second failure
(hang after disk load). Need to test with WRITE also avoiding C8 space.

---

### Test G — 2026-02-22 — PASCAL_INIT + PASCAL_WRITE = RTS (ROM patch)
**Config:** Same as Test F + videx_rom.hex offset 0x31C changed from
$20 (JSR $C9A7) to $A2 $00 $60 (LDX #$00; RTS). Both INIT and WRITE
return immediately without entering expansion ROM. PASCAL_READ and
PASCAL_STATUS are unchanged (STATUS is inline for output-ready check,
READ enters C8 space but is only called at keyboard prompt).

**Hypothesis:** PASCAL_WRITE's C8-space access is the second failure point.
Eliminating WRITE's C8 access should allow the p-machine to progress
past its text output phase. No visible text output (WRITE is a no-op).

**What to look for:**
- FloppyEmu: tracks 0-25 then MORE reads (SYSTEM.LIBRARY etc.) = p-machine progressing
- Keyboard responds to input = system reached command prompt (even if invisible)
- Same hang as Test F = problem is NOT in WRITE, look elsewhere

**Result:** SUCCESS — Pascal fully booted!
- Cold boot: screen stayed 40-col with large block cursor
- Disk reads: 0-4, 0, 5-something, 9, 19, low to 25, back to 0, more reads
- Disk activity eventually stopped (loading complete)
- Keyboard responsive: pressing C or R caused FloppyEmu to show more reads
- A few times pressing R triggered repeated hard reboots, but later R only
  triggered reads (order-dependent, possibly timing-sensitive)

**Analysis:**
- Pascal fully boots when both INIT and WRITE are stubbed out
- Keyboard works = p-machine is running, READ's C8-space execution works fine
- C/R triggering disk reads = Pascal command prompt is active (invisible since WRITE is RTS)
- READ enters C8 space (JSR $C844 → keyboard polling loop: LDA $C000, BPL)
  and works without issue
- This proves C8-space bus driving per se is NOT the problem — READ does it fine
- The difference: INIT and WRITE do writes to CRTC ($C0B0/$C0B1), VRAM ($CC00-$CDFF),
  and soft switches ($C059). READ only reads $C000 (keyboard).

**Conclusion:** The problem is specifically in what INIT and WRITE firmware code DOES
(CRTC writes, VRAM writes, soft switch writes), not in the act of driving the bus
from C8 space. Need to isolate whether INIT alone or WRITE alone causes failure.

---

### Test H — 2026-02-22 — INIT enabled, WRITE=RTS
**Config:** Same as Test D (Videx only) + videx_rom.hex:
- Offset 0x311 = $4C (INIT = JMP $C800, RESTORED to original)
- Offset 0x31C-0x31E = $A2 $00 $60 (WRITE = LDX #$00; RTS, still stubbed)

**Hypothesis:** Test F showed INIT=RTS allowed disk loading to progress (0→25).
But was that because INIT itself was the problem, or because eliminating INIT
also prevented the WRITE failures that follow? This test isolates INIT: if
Pascal hangs with disk stuck on track 0 (like Test A1), then INIT's C8 execution
is sufficient to cause the failure. If disk loading progresses (like Test F/G),
then INIT alone is not the problem and WRITE is the culprit.

**What to look for:**
- FloppyEmu stuck on track 00 = INIT alone breaks disk loading
- FloppyEmu reads to track 25+ = INIT is fine, WRITE was the problem
- 80-col switch + screen clear = INIT executed (expected, since INIT is restored)
- No text output = WRITE is still stubbed (expected)

**Result:** HANG — same as original
- Switched to 80-col (INIT ran, set AN0)
- FloppyEmu: tracks 00, 01, 02, 03, 04, 00 hang (identical to Test A1)
- No text output (WRITE is stubbed, as expected)

**Analysis:**
- INIT alone is sufficient to break disk loading
- Note: user previously ran PR#3 + VIDEX_DIAG in 80-col (all CRTC/VRAM ops work),
  then PR#6 to Pascal — same hang. INIT code already ran successfully during PR#3.
- The INIT code itself is proven to work (PR#3). Something about executing it
  during Pascal boot breaks subsequent disk loading.
- INIT writes: screen holes ($077B, $07FB, $06FB), CRTC ($C0B0/$C0B1),
  VRAM ($CC00-$CDFF via HOME), soft switch ($C059)

**Conclusion:** INIT's C8-space execution alone causes disk load failure.
Combined with Test G (READ's C8 execution works fine), the difference is
INIT does WRITES (CRTC, VRAM, soft switches) while READ only READS ($C000).

---

### Test I — 2026-02-22 — ROM patch: INIT=RTS (repeat of F, confirming isolation)
**Config:** Same as Test D (Videx only) + videx_rom.hex offset 0x311 = $60 (RTS).
INIT returns immediately. No CRTC programming, no VRAM writes, no AN0 set.

**Result:** SUCCESS — all disk tracks loaded, Pascal fully operational
- FloppyEmu: reads tracks 0-4, 5-25, additional reads (SYSTEM.PASCAL, SYSTEM.LIBRARY)
- Display: 40-col (AN0 never set). No visible Pascal output (WRITE still active
  but outputs to screen invisible in 40-col? — or output goes to VRAM but no 80-col)

**Conclusion:** INIT=RTS consistently allows disk loading. Confirms INIT's C8 code
execution is sufficient to break subsequent disk I/O.

---

### Test J — 2026-02-22 — ROM patch: INIT = STA $C059 only
**Config:** Same as Test D (Videx only) + videx_rom.hex offset 0x311 patched to:
`STA $C059; RTS` (3 bytes). INIT only writes to soft switch $C059 (AN0 on),
no CRTC programming, no VRAM clearing.

**Hypothesis:** Isolate whether the soft switch write alone breaks disk loading.
The full INIT does CRTC writes ($C0B0/$C0B1), VRAM writes ($CC00-$CDFF), screen
hole writes ($077B/$07FB/$06FB), and STA $C059. This test eliminates everything
except the soft switch.

**Result:** HANG — disk stuck on track 0
- FloppyEmu: tracks 00, 01, 02, 03, 04, 00 (identical to Test A1/H)

**Conclusion:** A single `STA $C059` from expansion ROM ($C800) space is sufficient
to break Pascal disk loading. This is a 3-byte ROM patch that only writes to a
soft switch — no CRTC, no VRAM, no complex I/O. Something about executing I/O
writes from C8 space breaks the system.

---

### Test K — 2026-02-22 — ROM patch: Full INIT minus AN0
**Config:** Same as Test D (Videx only) + videx_rom.hex: full INIT code but with
$C82A (STA $C059) NOPed out. All CRTC programming, VRAM clearing, screen hole
writes proceed normally — only the STA $C059 is suppressed.

**Result:** HANG — disk stuck on track 0
- Same symptom as Test H (full INIT). Screen switches to 80-col (INIT programs
  CRTC which triggers videx_mode_r), clears screen, cursor top-left.

**Conclusion:** AN0 write is not THE cause (Test J showed it CAN cause failure,
but removing it doesn't fix INIT). Multiple I/O operations from C8 space all
independently trigger the failure. The problem is in HOW the bus transceiver
behaves during I/O writes from C8 space, not in WHAT is being written.

---

### Test L — 2026-02-22 — ROM patch: INIT = STA $0400 only
**Config:** Same as Test D (Videx only) + videx_rom.hex offset 0x311 patched to:
`STA $0400; RTS` (4 bytes). INIT writes to main RAM at $0400 (first byte of
text page 1) — a normal RAM write, not I/O space.

**Hypothesis:** If the problem is bus transceiver timing during ANY write from
C8 space, even a RAM write should fail. If it's specific to I/O writes ($C0xx),
then RAM writes should be fine.

**Result:** SUCCESS — all disk tracks loaded
- FloppyEmu: full read sequence, disk activity stops normally

**Conclusion:** Writes to main RAM from C8 space work fine. The problem is
specifically writes to I/O space ($C0xx range) from C8 space. This narrows the
mechanism: the issue isn't about C8-space bus driving per se, it's about the
bus transceiver behavior during I/O-space write cycles that originate from
C8-space instruction fetches.

---

### Test M — 2026-02-22 — ROM patch: CRTC read/write test from C8 space
**Config:** Same as Test D (Videx only) + videx_rom.hex offset 0x311 patched to
do CRTC register writes and reads ($C0B0/$C0B1) plus two main RAM writes
($0400/$0401).

**Result:** PARTIAL — 2 spontaneous reboots, then all tracks loaded
- First 2 attempts: system rebooted during C8 execution
- Third attempt: full disk read sequence completed

**Conclusion:** CRTC I/O writes from C8 space are marginal — sometimes work,
sometimes cause reboots. Consistent with a bus timing issue where I/O writes
from C8 space create brief bus contention windows. The non-determinism suggests
a narrow timing margin rather than a hard failure.

---

### Summary: ROM Patch Test Results

| Test | $C800 code | Write target | Disk result |
|------|-----------|-------------|-------------|
| H | full INIT | CRTC+VRAM+AN0+screen holes | 0,1,2,3,4,0 hang |
| I | RTS (nothing) | — | all tracks, works |
| J | STA $C059 | soft switch | 0-4, hang |
| K | full INIT minus AN0 | CRTC+VRAM+screen holes | 0,1,2,3,4,0 hang |
| L | STA $0400 | main RAM | all tracks, works |
| M | CRTC R/W test | $C0B0/$C0B1 + $0400/$0401 | 2 reboots then all tracks |

**Key finding:** I/O writes ($C0xx) from C8 space break disk loading. Main RAM
writes ($0400) from C8 space work fine. The problem is bus transceiver timing
during I/O write cycles, not C8-space bus driving in general.

---

### Analysis: Bus Transceiver OE Timing (Root Cause)

The ROM patch tests point to the CPLD bus transceiver OE timing as root cause.

**Why I/O writes fail but RAM writes don't:**

During a CPU write to I/O space ($C0xx), the Videx card is simultaneously driving
the data bus (rd_en_o=1 for C8-space instruction fetches from the preceding cycle)
AND the Apple II motherboard's I/O decode logic is processing the write. The CPLD
OE signal (`a2_bridge_bus_d_oe_n_o`) is combinational — it tracks `data_out_en_i`
directly. When the card's rd_en_o drops at the phi0→phi1 transition, the CPLD OE
doesn't release until the CDC-delayed phi0 drop reaches the FPGA, creating ~100ns
of overlap where the CPLD is still driving while the 6502 is already in its next
cycle.

For I/O writes, the motherboard's address decode logic (GAL/PAL chips) responds
to $C0xx with specific timing. The CPLD's extended bus driving creates contention
with the motherboard's own bus drivers during this critical I/O decode window.
For RAM writes, the motherboard's DRAM controller handles the write with different
timing that is more tolerant of brief bus contention.

**The fix: Phase-counter OE cutoff** (implemented in apple_bus.sv)

```
localparam int CDC_DELAY = 6;   // CDC denoise: 2 sync + 3 debounce + 1 FIFO
localparam int OE_MARGIN = 2;   // Cycles past estimated real phi0 drop
localparam int OE_CUTOFF = PHASE_COUNT - CDC_DELAY + OE_MARGIN;  // = 22

wire oe_early_cutoff = a2bus_if.phi0 && (phase_cycles_r >= OE_CUTOFF[5:0]);
assign a2_bridge_bus_d_oe_n_o = ~(data_out_en_i & BUS_DATA_OUT_ENABLE & ~oe_early_cutoff);
```

The phase counter tracks position within each bus half-cycle. At cycle 22 of 26,
OE is forcibly released — approximately 37ns after the estimated real phi0 falling
edge. This eliminates ~60-70ns of unnecessary bus driving that previously extended
into phi1.

---

### SSC vs Videx Comparison (Agent Analysis)

A detailed comparison of SSC (`super_serial_card.sv`) vs Videx (`videx_card.sv`)
bus driving logic revealed three key differences:

| Aspect | SSC | Videx |
|--------|-----|-------|
| C8-space gating | `card_io_strobe` (uses `io_strobe_n`, includes INTC8ROM) | `rom_c8_active && phi0` (bypasses `io_strobe_n`) |
| ROM data_o | Combinational (zero latency) | 2-cycle pipeline (37ns stale data) |
| C8 ownership guard | `SLOTROM == 2` | Self-clearing `c8_owned` |

The `io_strobe_n` bypass was necessary because INTC8ROM was permanently set on
Apple ][+ (slot 3 + SLOTC3ROM=0 default). The `is_iie` fix in `apple_memory.sv`
resolves this root cause, so Videx could potentially switch to `card_io_strobe`
in the future (added as TODO in code).

The SSC works with Pascal because: (1) SSC FINIT happens at runtime (after
SYSTEM.PASCAL loads), not during the critical boot sequence; (2) SSC's C8 ROM
data is combinational (no stale data window); (3) SSC uses `card_io_strobe`
with INTC8ROM protection.

---

### Test OE_CUTOFF — 2026-02-22 — OE cutoff fix (Videx only)
**Config:** All fixes applied + OE cutoff (apple_bus.sv). slots.hex = `00 00 00 05 00 00 00 00`
(Videx only, no SSC/MB/SSP).

**Result:** SUCCESS — Pascal boots 100%.
- PR#3 → 80-col works
- VIDEX_DIAG T01-T20 all pass
- Pascal 1.3 boots fully, all Pascal apps working

**Conclusion:** OE cutoff fix resolves the Pascal boot hang. OE_MARGIN=2 is correct.

---

### Test ALL_CARDS — 2026-02-23 — All emulated cards enabled
**Config:** All fixes applied + OE cutoff. slots.hex = `00 00 03 05 02 00 00 01`
(SSC slot 2, Videx slot 3, Mockingboard slot 4, SuperSprite slot 7).

**Result:** SUCCESS — Pascal boots 100% with all cards enabled.
- PR#3 → 80-col works
- Pascal 1.3 boots fully, all Pascal apps working
- No regressions observed in basic operation

**Conclusion:** All fixes work together. The OE cutoff eliminates bus contention
for all cards, not just Videx. Multi-card emulation with C8-space usage is now
stable.
