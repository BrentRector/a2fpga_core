# Videx VideoTerm Full Emulation on Apple ][+

## Evaluation: Architectural Approach for Videx Emulation in A2FPGA

---

## 1. Executive Summary

This document evaluates two fundamentally different architectural approaches for building a fully self-contained Videx VideoTerm 80-column card emulation within the A2FPGA, targeting Apple ][+ systems where no external Videx hardware exists.

**The central question:** Should the emulated Videx card translate its operations into the IIe 80-column representation and render through the existing `TEXT80_LINE` pipeline? Or should it build upon the newly added Videx shadow rendering pipeline (`VIDEX_LINE`) by promoting it from passive monitoring to active emulation?

**Key finding:** Both approaches share the same "front end" — a new virtual card module that provides firmware ROM, MC6845 CRTC register emulation, and 2 KB VRAM with full read/write support. They differ only in the "back end" — how VRAM content reaches the screen.

**Recommendation:** Build upon the existing Videx shadow implementation (`VIDEX_LINE`). It is superior on all three axes: **smaller** (no translation logic), **faster** (no sync latency, native scroll support), and **simpler to maintain** (self-contained, no cross-subsystem coupling).

---

## 2. Context: Why These Are the Only Two Approaches

On an Apple ][/][+, no software will ever activate IIe 80-column mode — the COL80 soft switch, STORE80, auxiliary RAM, and the entire IIe memory banking mechanism simply don't exist on these machines. Any 80-column software running on a ][/][+ will look for and expect a **Videx adapter** specifically.

The A2FPGA already has two complete 80-column rendering paths:

1. **`TEXT80_LINE`** — Renders IIe-style 80-column text from the interleaved main/aux `text_vram`. Active on an Apple IIe when `COL80=1`. **Dead code on a ][/][+** since nothing ever sets `COL80`.

2. **`VIDEX_LINE`** — Renders Videx-style 80-column text from the separate `videx_vram` with its own character ROM, 9-scanline geometry, cursor logic, and hardware scrolling support. Currently passive (shadows an external card). **Already Videx-native.**

Both paths exist in the synthesized bitstream when `VIDEX_SUPPORT=1`. The question is which one to wire the new emulated card's output to.

---

## 3. What Both Approaches Share: The Virtual Card Front End

Regardless of rendering approach, a new virtual card module (`videx_card.sv`) is needed. This is identical for both approaches:

### 3.1 Card Module (implements `slot_if`)
- Assigned to slot 3 with a unique card ID
- Follows the established pattern from `super_serial_card.sv`
- `card_enable` / `card_sel` / `card_dev_sel` / `card_io_sel` logic

### 3.2 Firmware ROM (active bus response)
- 256 bytes at $C300-$C3FF (slot ROM, cold-start entry)
- 2 KB at $C800-$CFFF (expansion ROM, full terminal driver)
- Drives `data_o` onto bus during CPU reads (same as SSC ROM serving)
- Videx VideoTerm ROM 2.4 stored as `.hex` in BSRAM

### 3.3 MC6845 CRTC Register File
- 16 registers accessed via index port ($C0B0 even) / data port ($C0B1 odd)
- Read support: return R14/R15 on reads (cursor position, firmware reads these)
- R0-R13 write-only (matches real MC6845 behavior)
- Bank selection: address bits [3:2] select VRAM bank (0-3)

### 3.4 VRAM (2 KB, read/write)
- 4 banks x 512 bytes at $CC00-$CDFF
- Must support CPU reads (the shadow mode only captures writes)
- The existing `sdpram32` pattern already handles the write side
- Read-back requires either a second read port or time-multiplexed access

### 3.5 Bus Response Wiring
- `data_o`, `rd_en_o` signals muxed into the top-level bus multiplexer
- Same pattern as existing cards: `data_out_w = videx_rd ? videx_d_w : ...`

**Estimated effort for the shared front end: ~300-400 lines of SystemVerilog.** This is the same regardless of rendering approach.

---

## 4. Approach A: Translate to IIe TEXT80 Path

### 4.1 Architecture

```
Videx Card (new)           apple_memory           apple_video
┌──────────────┐          ┌──────────────┐       ┌──────────────┐
│ Firmware ROM │          │              │       │              │
│ CRTC Regs    │          │  text_vram   │──────>│  TEXT80_LINE  │───> HDMI
│ VRAM (2KB)   │─ sync ──>│  (main+aux)  │       │  pipeline    │
│ Sync Engine  │  engine  │              │       │              │
│ Char Xlate   │          │              │       │              │
│ Addr Xlate   │          │              │       │              │
└──────────────┘          └──────────────┘       └──────────────┘
```

### 4.2 Additional Components Required

**A. Address Translation Engine** — Converts Videx linear addresses to IIe scrambled text page addresses:
- Division by 80 (multiply-shift: `row = (pos * 13) >> 10`)
- 24-entry row base address lookup table
- Main/aux byte lane selection from column parity
- Display start offset (CRTC R12/R13) handling

**B. Character Encoding Translation** — 256-byte lookup table mapping Videx codes to IIe codes:
- Videx $00-$7F (normal) → IIe $80-$FF (normal range)
- Videx $80-$FF (inverse) → IIe $00-$3F (inverse range)
- **Limitation:** IIe has only 64 inverse glyphs (no inverse lowercase)
- **Limitation:** Uses IIe font, not Videx font (different glyph designs)

**C. Continuous Background Sync Engine** — Free-running state machine:
- Iterates through all 1920 screen positions at 54 MHz (~36 µs per full pass)
- For each position: read Videx VRAM → translate character → translate address → write text_vram
- Handles scrolling automatically (R12/R13 changes just shift the mapping)
- Requires write port arbitration with the Apple II bus

**D. Write Port Arbitration** — Time-multiplexed access to text_vram:
- Bus writes occur on `phi1_posedge` with `data_in_strobe`
- Sync engine writes during other clock cycles
- ~54 FPGA cycles per bus cycle provides ample time

**E. Soft Switch Override** — Force `COL80=1` when Videx active:
- Modifies `a2mem_if.COL80` to activate TEXT80 rendering
- On a ][+, this signal is normally always 0

### 4.3 Visual Compromises

| Issue | Impact |
|-------|--------|
| 8 scanlines/char instead of 9 | Characters with descenders (g,j,p,q,y) lose bottom line. Tighter vertical spacing. |
| IIe font instead of Videx font | Different glyph designs. Not pixel-accurate to real Videx. |
| No inverse lowercase | IIe ROM lacks inverse lowercase glyphs (64 vs 128 inverse chars) |
| Smaller active area | 384 px tall vs 432 px (48 px larger borders) |

### 4.4 Resource Cost (beyond shared front end)

| Component | Cost |
|-----------|------|
| Char translation LUT | 256 x 8 bits ROM |
| Row base address LUT | 24 x 10 bits ROM |
| Division by 80 multiplier | 11-bit x 11-bit |
| Sync state machine | ~200 flip-flops |
| Write port mux logic | ~50 LUTs |
| **Total additional** | **~300 LUTs, 1 multiplier, 0 BSRAM** |

Note: This does NOT save the VIDEX_LINE rendering path or Videx character ROM — those are already synthesized when `VIDEX_SUPPORT=1`. The translation logic is purely **additive**.

---

## 5. Approach B: Build Upon the Videx Shadow Path

### 5.1 Architecture

```
Videx Card (new)           apple_memory           apple_video
┌──────────────┐          ┌──────────────┐       ┌──────────────┐
│ Firmware ROM │          │              │       │              │
│ CRTC Regs ───────────────> a2mem_if.*  │──────>│  VIDEX_LINE   │───> HDMI
│ VRAM (2KB) ──────────────> videx_vram  │──────>│  pipeline    │
│              │          │              │       │              │
└──────────────┘          └──────────────┘       └──────────────┘
```

### 5.2 What Already Works (No Changes Needed)

The existing Videx shadow code in `apple_memory.sv` and `apple_video.sv` already provides:

| Component | Status | Location |
|-----------|--------|----------|
| CRTC register storage (R9-R15) | Working | `apple_memory.sv:183-220` |
| VRAM write capture (2 KB sdpram32) | Working | `apple_memory.sv:229-247` |
| VRAM bank selection (4 x 512B) | Working | `apple_memory.sv:199-200` |
| VIDEX_MODE detection flag | Working | `apple_memory.sv:188,204` |
| 9-scanline character geometry | Working | `apple_video.sv:82-87,172-188` |
| Division by 9 (row/scanline calc) | Working | `apple_video.sv:182-187` |
| Row x 80 linear address calc | Working | `apple_video.sv:461-466` |
| Hardware scroll (R12/R13 base) | Working | `apple_video.sv:173,464` |
| Videx character ROM (4 KB) | Working | `apple_video.sv:209-216` |
| Full rendering pipeline (stages 0-5) | Working | `apple_video.sv:613-643` |
| MC6845 cursor with blink modes | Working | `apple_video.sv:468-491` |
| Frame counter for blink timing | Working | `apple_video.sv:476-482` |

### 5.3 What Needs to Change

The shadow implementation is **passive** — it only snoops bus writes. For active emulation, these changes are needed:

**A. CRTC register source:** Currently, the CRTC register capture logic in `apple_memory.sv:190-211` snoops writes to $C0Bx from an external card. For the emulated card, the registers are managed by the new `videx_card.sv` module instead. The card writes them to `a2mem_if.VIDEX_CRTC_R*` signals directly, or the existing capture logic picks up the card's bus responses (since the card *is* responding on the bus, the snoop logic still sees the writes).

**B. VRAM write source:** Same situation — the CPU writes to $CC00-$CDFF, the card responds (handling bank selection), and the existing VRAM capture logic in `apple_memory.sv:229-247` still snoops those writes into `videx_vram`. The card and the shadow see the same bus transactions.

**C. VRAM read-back:** The shadow `sdpram32` has its read port dedicated to the video scanner. CPU read-back requires either:
- A time-multiplexed read port (read during non-scan cycles)
- A separate small read buffer in the card module
- Or the card maintains its own parallel VRAM copy for reads (adds 2 KB BSRAM)

**D. VIDEX_MODE activation:** Currently set by detecting the first CRTC write. For emulation, could be set explicitly by the card module when it initializes. The existing mechanism works as-is since the Videx firmware's CRTC writes trigger it.

**E. AN0 handling:** The `VIDEX_LINE` mode selection requires `an0_r` to be set (`apple_video.sv:429`). On a real Videx system, the firmware sets AN0 via the annunciator soft switches. The emulated Videx firmware will do the same thing through normal bus access to $C058/$C059.

### 5.4 Visual Fidelity

| Aspect | Result |
|--------|--------|
| 9-scanline characters | Native — full descender support |
| Videx character ROM | Native — correct Videx font |
| Full inverse character set | Native — 128 normal + 128 inverse via pre-inverted ROM |
| 432 px active area | Native — correct vertical geometry |
| Hardware scrolling | Native — R12/R13 directly drive rendering address |
| Cursor blink modes | Native — all 4 MC6845 blink modes supported |

**No visual compromises.**

### 5.5 Resource Cost (beyond shared front end)

| Component | Cost |
|-----------|------|
| VRAM read-back path | ~30 LUTs (mux or buffer) |
| **Total additional** | **~30 LUTs, 0 multipliers, 0 BSRAM** |

Everything else already exists in the shadow implementation.

---

## 6. Head-to-Head Comparison

### 6.1 Space

| | Approach A (TEXT80) | Approach B (VIDEX_LINE) |
|--|---------------------|------------------------|
| Firmware ROM | 2 KB BSRAM | 2 KB BSRAM |
| CRTC registers | 128 FFs | 128 FFs |
| Card VRAM | 2 KB BSRAM | (reuses existing shadow VRAM) |
| Char translation LUT | 256 bytes | **Not needed** |
| Row base address LUT | 240 bits | **Not needed** |
| Sync state machine | ~200 FFs + ~300 LUTs | **Not needed** |
| Write port mux | ~50 LUTs | **Not needed** |
| Div-by-80 multiplier | 1 multiplier | **Not needed** |
| VRAM read-back | (text_vram already readable) | ~30 LUTs |
| Videx char ROM (4 KB) | Still synthesized (VIDEX_SUPPORT=1) | Already present |
| VIDEX_LINE stages | Still synthesized (VIDEX_SUPPORT=1) | Already present |
| **Net additional logic** | **~550 LUTs + 1 mult** | **~30 LUTs** |

**Winner: Approach B.** Approach A adds translation logic but does NOT eliminate the Videx rendering path (it's still in the bitstream). Approach B reuses what's already there with minimal additions.

If `VIDEX_SUPPORT=0` (Videx path stripped), Approach A avoids ~4 KB BSRAM (Videx char ROM + VRAM) but adds ~550 LUTs + 1 multiplier + its own 2 KB VRAM. This is not a meaningful savings — and loses visual fidelity.

### 6.2 Performance

| | Approach A (TEXT80) | Approach B (VIDEX_LINE) |
|--|---------------------|------------------------|
| Character write latency | Up to 36 µs (sync engine cycle) | **0 cycles** (direct VRAM write → immediate render) |
| Scroll latency | Up to 36 µs | **0 cycles** (R12/R13 change takes effect next frame) |
| Write port contention | Arbitration needed (bus vs sync) | **None** (separate VRAM, no contention) |
| Rendering accuracy | 8-scanline approximation | **Exact 9-scanline rendering** |

**Winner: Approach B.** Zero translation latency, zero scroll latency, zero contention.

### 6.3 Maintenance

| | Approach A (TEXT80) | Approach B (VIDEX_LINE) |
|--|---------------------|------------------------|
| Conceptual complexity | High — bridges two different display models | Low — single Videx-native model |
| Cross-module coupling | Card → sync engine → text_vram → TEXT80 pipeline | Card → a2mem_if → VIDEX_LINE pipeline |
| Bug surface area | Address translation, char translation, sync timing, write arbitration | VRAM read-back mux |
| Impact of TEXT80 changes | Could break Videx emulation | **No impact** (independent path) |
| Impact of VIDEX_LINE changes | No impact | Could affect emulation (but same team maintains both) |
| Code to write | ~400 lines (card) + ~300 lines (translation) | ~400 lines (card) + ~30 lines (read-back) |
| Code to debug | Translation correctness for 1920 positions × 256 chars | Standard bus response logic |

**Winner: Approach B.** Self-contained, minimal coupling, dramatically less new code.

### 6.4 Summary Table

| Criterion | Approach A (TEXT80) | Approach B (VIDEX_LINE) |
|-----------|:-------------------:|:-----------------------:|
| Additional LUTs | ~550 | ~30 |
| Additional BSRAM | 0 (but doesn't eliminate Videx BSRAM) | 0 |
| Write latency | Up to 36 µs | 0 |
| Scroll latency | Up to 36 µs | 0 |
| Character fidelity | 8-scanline, IIe font, 64 inverse glyphs | 9-scanline, Videx font, 128 inverse glyphs |
| New code | ~700 lines | ~430 lines |
| Bug surface area | Large (4 translation subsystems) | Small (bus response only) |
| Cross-module coupling | High | Low |

---

## 7. Recommendation

**Build upon the existing Videx shadow implementation (Approach B).**

The `VIDEX_LINE` rendering path already solves the hard problems — 9-scanline geometry, hardware scrolling, cursor blinking, linear VRAM addressing, and Videx character ROM lookup. It was designed to faithfully reproduce Videx video output and it does so. The only thing missing is an active card module to drive the bus side.

Approach A (TEXT80 mapping) adds significant complexity to bridge two fundamentally different display models — scrambled vs. linear addressing, different character encodings, different scanline counts, different character ROMs — and the result is still a visual approximation. Meanwhile, the rendering infrastructure it tries to reuse (TEXT80) is dead code on a ][/][+ anyway, while the infrastructure it tries to avoid (VIDEX_LINE) is already synthesized and working.

The Videx shadow path was built to render Videx output faithfully. Promoting it from "passive shadow" to "active emulation" is the natural evolution.

---

## 8. Implementation Plan (Approach B)

### Phase 1: Virtual Card Module
1. Create `hdl/videx/videx_card.sv` implementing `slot_if`
2. Add card ID to the slot system (e.g., ID=5)
3. Implement firmware ROM serving ($C300-$C3FF, $C800-$CFFF)
4. Implement CRTC register file with read-back (R14/R15)
5. Implement VRAM bank selection and write handling
6. Implement VRAM CPU read-back (time-multiplexed or buffered)

### Phase 2: Integration
1. Wire card into board top-level (`top.sv`) with `data_o`/`rd_en_o`
2. Add to bus data multiplexer alongside existing cards
3. Verify the existing CRTC capture and VRAM shadow logic works with the card's bus responses
4. Ensure `VIDEX_MODE` activates correctly from the card's CRTC initialization
5. Verify AN0 is set by the Videx firmware through normal annunciator access

### Phase 3: Testing
1. Test with Videx firmware initialization (CRTC setup, VRAM clear)
2. Test character output (Apple Writer II, WordStar, CP/M)
3. Test hardware scrolling
4. Test cursor positioning and blink modes
5. Test on actual Apple ][+ hardware

### Phase 4: Refinements
1. Handle edge cases in VRAM read-back timing
2. Support for Videx-compatible software that directly manipulates CRTC/VRAM
3. Optional: multiple character set support (Videx supported up to 11 sets)

---

## 9. Detailed Analysis: What Changes for Each Module

### 9.1 New: `hdl/videx/videx_card.sv` (~400 lines)

```
Module ports:
  a2bus_if.slave     — Bus signals (addr, data, rw_n, phi1, etc.)
  a2mem_if.slave     — Memory interface (to set VIDEX_MODE, CRTC regs)
  slot_if.card       — Slot interface (dev_select_n, io_select_n, io_strobe_n)
  output [7:0] data_o     — Data to drive on bus
  output rd_en_o          — Read enable
  output irq_n_o          — Interrupt (active low, directly active)

Internal components:
  - Firmware ROM (2 KB BSRAM, loaded from videx_rom.hex)
  - CRTC register file (16 x 8-bit registers)
  - CRTC index register (5 bits)
  - VRAM bank offset (11 bits)
  - Bus response mux (ROM / CRTC / VRAM read selection)
```

### 9.2 Modified: `apple_memory.sv`

The existing `videx_gen` generate block (lines 175-262) may need minor adjustments:
- The CRTC capture logic already snoops $C0Bx writes — this continues to work because the CPU's writes to $C0Bx are still visible on the bus even when the card is responding
- The VRAM capture logic already snoops $CC00-$CDFF writes — same principle
- **Possible change:** The VRAM read port is currently dedicated to the video scanner. If CPU read-back is needed from this same VRAM (rather than a separate copy in the card), a read-port mux would be added here
- **Possible change:** Allow `VIDEX_MODE` to be set by the card module directly (belt and suspenders alongside the automatic detection)

### 9.3 Unchanged: `apple_video.sv`

No changes needed. The `VIDEX_LINE` rendering path, all geometry calculations, cursor logic, and character ROM lookup work as-is. The video module reads from `videx_vram_data_i` and `a2mem_if.VIDEX_CRTC_R*` — both are populated by the shadow capture logic which continues to function.

### 9.4 Modified: Board `top.sv`

- Instantiate `videx_card` module alongside existing cards
- Add to bus data multiplexer: `data_out_w = videx_rd ? videx_d_w : ...`
- Add `rd_en_o` to `data_out_en_w` OR chain
- Wire `slot_if` from `slotmaker` to the new card
- Connect Videx VRAM read port (if read-back is routed through `apple_memory`)

---

## 10. Open Questions

### 10.1 Firmware ROM Source
The Videx VideoTerm ROM is copyrighted. Options:
- User provides their own ROM dump (loaded via `.hex` file)
- Open-source terminal firmware (would need to be written)
- Investigate abandonware/fair-use status

### 10.2 VRAM Read-Back Architecture
The shadow `sdpram32` read port is used by the video scanner. For CPU reads of $CC00-$CDFF, options:
- **Option A:** Card maintains its own copy of VRAM for reads (adds 2 KB BSRAM, simplest)
- **Option B:** Time-multiplex the shadow VRAM read port between scanner and CPU (requires careful timing)
- **Option C:** Replace `sdpram32` with true dual-port RAM (if FPGA supports it)
- **Recommendation:** Option A is simplest. 2 KB BSRAM is cheap on the target FPGAs.

### 10.3 Interaction Between Shadow and Emulation
When the emulated card is active, the existing shadow capture logic still runs (it snoops the same bus transactions the card generates). This is actually beneficial — the shadow populates the same VRAM and CRTC registers that the VIDEX_LINE renderer reads. No conflict exists because the shadow and the card agree on the bus state.

However, if both an external Videx card AND the emulated card were active simultaneously (shouldn't happen, but defensive design), there would be bus contention. The card should only be enabled on ][/][+ systems, or when explicitly configured.

### 10.4 Apple ][+ Bus Signal Handling
The `m2sel_n` signal used in slot decode (`apple_memory.sv:197`, `slotmaker.sv`) is an IIe signal. On a ][/][+:
- Verify the A2FPGA bus interface drives `m2sel_n` correctly for ][+ (should be active/low for all I/O access)
- The slot decode logic in `slotmaker.sv` uses `!a2bus_if.m2sel_n` as a guard — this must pass on a ][+

---

## 11. Resource Summary (Approach B)

| Resource | Existing (shadow) | New (card) | Total |
|----------|-------------------|------------|-------|
| Firmware ROM | — | 2 KB BSRAM | 2 KB |
| CRTC register file | 128 FFs (in shadow) | Duplicated or shared | 128 FFs |
| VRAM (scanner-facing) | 2 KB BSRAM (shadow) | — | 2 KB |
| VRAM (CPU read-back) | — | 2 KB BSRAM (if Option A) | 2 KB |
| Videx character ROM | 4 KB BSRAM (shadow) | — | 4 KB |
| Bus response logic | — | ~200 LUTs | ~200 LUTs |
| VIDEX_LINE pipeline | Existing | — | Existing |
| **Total new** | | **2-4 KB BSRAM + ~200 LUTs** | |

This is comparable to the Super Serial Card's resource footprint and well within the capacity of all target FPGAs.
