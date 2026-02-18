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

Regardless of rendering approach, a new virtual card module (`videx_card.sv`) is needed. This is identical for both approaches.

**Critical distinction:** The existing Videx shadow logic in `apple_memory.sv` is **passive** — it snoops bus writes that a real Videx card handles and stores copies for the renderer. Without a real card present, the emulated card must **actively implement every hardware behavior** that software depends on. The shadow was designed to observe; the card must replace.

### 3.1 Card Module (implements `slot_if`)
- Assigned to slot 3 with a unique card ID
- Follows the established pattern from `super_serial_card.sv`
- `card_enable` / `card_sel` / `card_dev_sel` / `card_io_sel` logic

### 3.2 Firmware ROM (active bus response)
- 256 bytes at $C300-$C3FF (slot ROM, cold-start entry)
- 2 KB at $C800-$CFFF (expansion ROM, full terminal driver)
- Drives `data_o` onto bus during CPU reads (same as SSC ROM serving)
- Videx VideoTerm ROM 2.4 stored as `.hex` in BSRAM
- Expansion ROM ownership protocol: set flag on $C300-$C3FF access, clear on $CFFF

### 3.3 MC6845 CRTC Register Emulation

The card must emulate the MC6845 CRTC's register behavior, not just capture writes:

**Register I/O protocol ($C0Bx):**
- Even addresses ($C0B0, $C0B2, ...): latch 5-bit register index
- Odd addresses ($C0B1, $C0B3, ...): read or write the indexed register
- ALL $C0Bx accesses: capture bits [3:2] for VRAM bank selection

**Write behavior by register:**
| Register | Write Effect | Shadow Captures? | Card Must Emulate |
|----------|-------------|-------------------|-------------------|
| R0-R3 | Horizontal timing | No | Store value (R0-R3 are write-only on MC6845; no read-back needed; HDMI handles timing independently) |
| R4-R7 | Vertical timing | No | Store value (same — timing is irrelevant to HDMI output) |
| R8 | Interlace mode | No | Store value; renderer assumes R8=0 (no interlace) |
| R9 | Max scanline | Yes → `VIDEX_CRTC_R9` | Store value; if ≠ 8, rendering geometry may break |
| R10-R11 | Cursor shape/blink | Yes → `VIDEX_CRTC_R10/R11` | Store value; renderer uses for cursor appearance |
| R12-R13 | Display start addr | Yes → `VIDEX_CRTC_R12/R13` | Store value; renderer uses for hardware scrolling |
| R14-R15 | Cursor position | Yes → `VIDEX_CRTC_R14/R15` | **Store value AND support read-back** (see below) |

**Read behavior (CRITICAL):**
On the real MC6845, R14 and R15 are **read-write**. When software reads $C0B1 with index 14 or 15, the MC6845 returns the cursor position. This is essential for:
- **Card detection:** Software writes a test value to R14, reads it back — if it matches, a Videx is present
- **Cursor position queries:** Firmware and applications read R14/R15 to find the current cursor location
- The current shadow has **NO read-back path** — it only captures writes. The emulated card must actively drive `data_o` with R14/R15 values during reads.

**VRAM bank selection:**
Any access to $C0Bx (read or write, even or odd) causes the card to capture address bits [3:2] as the VRAM bank selector. This determines which 512-byte bank within the 2 KB VRAM is addressed by subsequent $CC00-$CDFF accesses. The shadow does this too (`videx_bankofs <= {addr[3:2], 9'b0}`, `apple_memory.sv:200`), but the card must replicate it independently for its own VRAM addressing.

### 3.4 VRAM Emulation (2 KB, read/write)

The card must actively manage 2 KB of VRAM (4 banks × 512 bytes):

**Writes ($CC00-$CDFF):**
- CPU writes to $CC00-$CDFF store a byte at `bankofs + addr[8:0]`
- The shadow already captures these writes (it snoops the bus)
- The card must also store the write in its own VRAM for read-back

**Reads ($CC00-$CDFF) — CRITICAL GAP:**
- The shadow provides **NO read-back** to the CPU — its read port is dedicated to the video scanner
- The emulated card must return the stored VRAM byte on CPU reads
- This is essential: advanced programs (WordStar, Apple Writer II) read VRAM directly
- Requires the card to maintain its own 2 KB VRAM copy (simplest: dedicated BSRAM block)

### 3.5 How Shadow and Card Interact

When the emulated card is on the bus:
1. CPU writes to $C0B1 → card accepts the write → same bus transaction is visible to the shadow → shadow captures the same value
2. CPU writes to $CC00 → card accepts the write → shadow captures the same write
3. CPU reads $C0B1 → **only the card responds** (shadow has no read path)
4. CPU reads $CC00 → **only the card responds** (shadow has no read path)

This means the shadow continues to passively capture the SAME data it always has (CRTC registers and VRAM writes), feeding the VIDEX_LINE renderer. The card handles all the response behavior the shadow cannot provide (ROM serving, register read-back, VRAM read-back, bus driving).

### 3.6 Bus Response Wiring
- `data_o`, `rd_en_o` signals muxed into the top-level bus multiplexer
- Same pattern as existing cards: `data_out_w = videx_rd ? videx_d_w : ...`

### 3.7 Complete Side-Effect Summary

| Access | Address | Card Active Response | Shadow Passive Capture |
|--------|---------|---------------------|----------------------|
| ROM read | $C300-$C3FF | Drive firmware byte onto bus | — |
| Expansion ROM read | $C800-$CFFF | Drive ROM byte (if owns $C800) | — |
| CRTC index write | $C0B0 (even) | Latch index; update bank select | Latch index; update bank select |
| CRTC data write | $C0B1 (odd) | Store to register file | Store to shadow regs (R9-R15) |
| CRTC data read | $C0B1 (odd) | **Return R14/R15 on bus** | **Nothing (gap)** |
| VRAM write | $CC00-$CDFF | Store in card VRAM | Store in shadow VRAM |
| VRAM read | $CC00-$CDFF | **Return byte from card VRAM** | **Nothing (gap)** |

**Estimated effort for the shared front end: ~400-500 lines of SystemVerilog.** This is the same regardless of rendering approach.

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

## 8. How Software Interacts with the Emulated Card

This is the critical section. The virtual card must present a complete Videx hardware and software interface — firmware ROM, CRTC registers, and VRAM — so that Apple ][/][+ software can discover, initialize, and use the 80-column adapter exactly as it would a real Videx VideoTerm. Both approaches A and B require the identical bus-facing card module described here; they differ only in the rendering back end.

### 8.1 PR#3: Activating the Videx Card

When the user types `PR#3` at the Applesoft BASIC prompt, the Apple II firmware executes this sequence:

```
1. CPU reads $C300        ← Slot 3 ROM entry point
   └─ slotmaker decodes addr[10:8]=3, asserts io_select_n for slot 3
   └─ videx_card sees io_select_n LOW, drives firmware ROM byte onto data_o
   └─ apple_memory sets SLOTROM=3 and INTC8ROM=1 (slot 3 claims $C800 space)

2. Firmware at $C300 contains a JMP to $C800+ expansion ROM
   CPU reads $C800-$CFFF  ← Expansion ROM
   └─ slotmaker decodes addr[15:11]=5'b11001, asserts io_strobe_n
   └─ videx_card sees io_strobe_n LOW + rom ownership, drives ROM bytes

3. Videx firmware in expansion ROM executes initialization:
   a. Writes to $C0B0 (even): set CRTC register index
      └─ slotmaker decodes addr[6:4]=3, asserts dev_select_n
      └─ videx_card captures index value
      └─ apple_memory shadow also captures (snoops same bus write)

   b. Writes to $C0B1 (odd): write CRTC register data
      └─ videx_card stores register value
      └─ apple_memory shadow stores same value in videx_crtc_regs[]
      └─ First CRTC write sets videx_mode_r = 1 (Videx detected)

   c. Firmware programs CRTC R0-R8 (timing), R9 (max scanline = 8),
      R10-R11 (cursor), R12-R13 (display start = 0)

   d. Firmware writes to $CC00-$CDFF: clear VRAM
      └─ videx_card handles write (bank select from prior $C0Bx access)
      └─ apple_memory shadow captures same writes into videx_vram

   e. Firmware writes $C059: set AN0 (annunciator 0 ON)
      └─ apple_memory captures AN0=1
      └─ apple_video mode select: videx_mode_r & text_mode_r & an0_r → VIDEX_LINE

   f. Firmware patches CSW ($36/$37): redirect COUT to Videx output routine
      └─ All subsequent text output goes through Videx firmware
      └─ Firmware writes characters to VRAM, updates CRTC cursor position

4. Result: 80-column text appears on HDMI via VIDEX_LINE rendering
```

This is identical to what happens with a real Videx card in a real Apple ][+. The FPGA's virtual card responds on the bus; the 6502 CPU runs the actual Videx firmware ROM; the firmware initializes the hardware and patches into the Apple II OS.

### 8.2 Software Detection: Finding the Videx

Programs detect Videx-compatible cards using several methods:

**A. ROM signature bytes** — Most Videx-aware software reads specific bytes from $C300-$C3FF to identify the card. The Videx VideoTerm ROM contains known signature bytes at fixed offsets. Since the virtual card serves the actual Videx ROM, these checks pass automatically.

**B. CRTC probe** — Some software writes a value to a CRTC register via $C0B0/$C0B1 and reads it back (R14/R15 are readable on the MC6845). If the read-back matches, a Videx is present. The virtual card must support reads from $C0B1 returning R14/R15 data. This is the CRTC read-back requirement listed in Section 3.3.

**C. PR#3 and IN#3** — The simplest detection: if `PR#3` doesn't crash and produces 80-column output, the card is present. This works because the virtual card serves valid firmware ROM.

**D. Slot scan** — ProDOS and some applications scan slots 1-7 by reading $Cn00 and checking for device type signatures. The Videx ROM at $C300 contains the proper identification byte.

### 8.3 The Videx API: How Applications Use 80-Column Output

The Videx VideoTerm API is entirely software — it's the 6502 firmware code in the ROM. The FPGA provides hardware support; the firmware provides the API:

**Standard output (most applications):**
```
Application calls COUT ($FDED)
  → Apple II ROM checks CSW ($36/$37), which Videx firmware patched to point to $C300+
  → CPU jumps to Videx firmware in $C800 expansion ROM
  → Firmware writes character to VRAM at cursor position ($CC00-$CDFF)
  → Firmware advances cursor (updates CRTC R14/R15)
  → Firmware handles scroll if needed (updates CRTC R12/R13, writes new line to VRAM)
  → Return to application
```

**Control codes (cursor movement, clear screen, etc.):**
```
Videx firmware interprets control characters:
  $08 (BS)  → move cursor left
  $0A (LF)  → move cursor down, scroll if at bottom
  $0C (FF)  → clear screen (writes spaces to all VRAM, resets R12-R15)
  $0D (CR)  → move cursor to start of line
  $15 (NAK) → home cursor
  etc.
```

**Direct VRAM access (advanced programs like WordStar, Apple Writer II):**
```
Some programs bypass the firmware API and write directly to VRAM:
  1. Select VRAM bank: access $C0B0-$C0BF (address bits [3:2] select bank)
  2. Write character: store byte at $CC00-$CDFF
  3. Update cursor: write CRTC R14/R15 via $C0B0/$C0B1
```

All of these work automatically because:
- The CPU runs real Videx firmware code (served from the card's ROM)
- CRTC register writes are handled by the card AND snooped by the shadow
- VRAM writes are handled by the card AND snooped by the shadow
- The VIDEX_LINE renderer reads from the shadow VRAM and CRTC registers

### 8.4 Key Insight: The Firmware IS the API

The Videx "API" is not something the FPGA implements — it's 6502 code in the firmware ROM that the Apple ][+ CPU executes natively. The FPGA's job is to provide:

1. **ROM bytes on demand** — so the CPU can execute the firmware
2. **MC6845 register I/O** — so the firmware can program the display hardware
3. **VRAM read/write** — so the firmware can store and retrieve character data
4. **Video output** — so the VRAM contents appear on screen

The virtual card handles #1-3. The existing shadow capture + VIDEX_LINE pipeline handles #4. This is why promoting the shadow path to active emulation is the natural approach — it already does #4, and #1-3 are the same regardless of rendering back end.

---

## 9. 9-Scanline Rendering: Current Status

The VIDEX_LINE rendering path in `apple_video.sv` contains code for 9-scanline character rendering:

- **Vertical geometry** (`apple_video.sv:82-86`): `VIDEX_WINDOW_HEIGHT = 432` (24 rows × 9 scanlines × 2 doubling)
- **Content Y** (`apple_video.sv:177-178`): `videx_content_y_w` uses `VIDEX_V_BORDER` (24), range 0-215
- **Division by 9** (`apple_video.sv:180-183`): multiply-shift approximation, exact for 0-215
- **Scanline extraction** (`apple_video.sv:185-187`): `videx_scanline_w` is 4-bit, ranges 0-8
- **Character ROM address** (`apple_video.sv:616`): `{char[7:0], videx_scanline_w[3:0]}` — uses 4-bit scanline, NOT the TEXT80 path's 3-bit `window_y_w[2:0]`
- **Active window** (`apple_video.sv:92-94`): switches to 432-pixel tall window when Videx mode detected

**However:** This code was added in the most recent commit as part of the passive shadow support and has NOT been tested on real hardware. Key risks:

1. **The divide-by-9 approximation** (`content_y * 57 >> 9`) — needs verification that it produces correct row/scanline values for all 216 content lines (0-215)
2. **The vertical window geometry** — `window_y_w` at line 102 still uses `V_BORDER` (48) not `VIDEX_V_BORDER` (24), which would produce incorrect values for screen lines 24-47. The VIDEX_LINE path uses its own `videx_content_y_w` instead, but any shared logic that depends on `window_y_w` during those lines could malfunction.
3. **The character ROM** (`videx_charrom.hex`) — needs verification that the 9th scanline data (scanline index 8) is correctly positioned in the ROM file
4. **Interaction with mixed mode** — the `GR` signal at line 189 depends on `window_y_w`, which may have incorrect values during the extended Videx vertical window

Until these are validated through testing, the 9-scanline rendering should be treated as **implemented but unverified**. This applies equally to both approaches — Approach B uses it directly, while Approach A would need to reimplement it if full 9-scanline fidelity is desired.

---

## 10. Implementation Plan (Approach B)

### Phase 1: Virtual Card Module (`videx_card.sv`)
1. Create `hdl/videx/videx_card.sv` implementing `slot_if.card`
2. Add card ID to slot system and update `slots.hex` to assign it to slot 3 (currently empty: `slot_cards[3] = 0`)
3. Implement firmware ROM storage (2 KB BSRAM, loaded from `videx_rom.hex`)
4. Implement expansion ROM ownership protocol:
   - Set ownership flag when $C300-$C3FF is accessed (mirrors `apple_memory.sv` INTC8ROM behavior)
   - Clear on $CFFF access
   - Respond to $C800-$CFFF reads when ownership flag is set
5. Implement MC6845 CRTC register file:
   - Index port at $C0B0 (even addresses): latch 5-bit register index
   - Data port at $C0B1 (odd addresses): write register data, read R14/R15
   - Bank selection from address bits [3:2] on any $C0Bx access
6. Implement VRAM read/write:
   - Write: accept byte writes to $CC00-$CDFF with bank offset
   - Read-back: return stored VRAM byte when CPU reads $CC00-$CDFF
7. Drive `data_o` and `rd_en_o` for all three address spaces

### Phase 2: Integration into Board Top-Level
1. Instantiate `videx_card` in `top.sv` alongside existing cards
2. Add to bus data multiplexer: `data_out_w = videx_rd ? videx_d_w : ...`
3. Add `rd_en_o` to `data_out_en_w` OR chain
4. Wire `slot_if` from `slotmaker`
5. Verify the existing shadow capture logic in `apple_memory.sv` correctly
   picks up bus transactions generated by the card's interaction with the CPU
6. Verify `VIDEX_MODE` activates on first CRTC write (existing mechanism)
7. Verify AN0 set by Videx firmware via normal $C058/$C059 access

### Phase 3: Validate 9-Scanline Rendering
1. Verify divide-by-9 produces correct row/scanline for all 216 content lines
2. Verify `videx_charrom.hex` scanline 8 data is correct for all characters
3. Verify `window_y_w` underflow in lines 24-47 does not affect VIDEX_LINE path
4. Test character display accuracy against real Videx output
5. Verify cursor rendering at correct scanline positions

### Phase 4: Software Compatibility Testing
1. PR#3 activation from Applesoft BASIC prompt
2. IN#3 for input redirection
3. Apple Writer II (direct VRAM access)
4. WordStar under CP/M (heavy 80-column use)
5. ProDOS slot scan / device detection
6. Programs that probe CRTC register read-back for card detection
7. Hardware scrolling behavior (rapid text output)
8. Test on actual Apple ][+ hardware

### Phase 5: Refinements
1. Handle edge cases in VRAM read-back timing
2. Support for Videx-compatible software that directly manipulates CRTC/VRAM
3. Optional: multiple character set support (Videx supported up to 11 sets)

---

## 11. Detailed Analysis: What Changes for Each Module

### 11.1 New: `hdl/videx/videx_card.sv` (~400 lines)

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

### 11.2 Modified: `apple_memory.sv`

The existing `videx_gen` generate block (lines 175-262) may need minor adjustments:
- The CRTC capture logic already snoops $C0Bx writes — this continues to work because the CPU's writes to $C0Bx are still visible on the bus even when the card is responding
- The VRAM capture logic already snoops $CC00-$CDFF writes — same principle
- **Possible change:** The VRAM read port is currently dedicated to the video scanner. If CPU read-back is needed from this same VRAM (rather than a separate copy in the card), a read-port mux would be added here
- **Possible change:** Allow `VIDEX_MODE` to be set by the card module directly (belt and suspenders alongside the automatic detection)

### 11.3 Unchanged: `apple_video.sv`

No changes needed. The `VIDEX_LINE` rendering path, all geometry calculations, cursor logic, and character ROM lookup work as-is. The video module reads from `videx_vram_data_i` and `a2mem_if.VIDEX_CRTC_R*` — both are populated by the shadow capture logic which continues to function.

### 11.4 Modified: Board `top.sv`

- Instantiate `videx_card` module alongside existing cards
- Add to bus data multiplexer: `data_out_w = videx_rd ? videx_d_w : ...`
- Add `rd_en_o` to `data_out_en_w` OR chain
- Wire `slot_if` from `slotmaker` to the new card
- Connect Videx VRAM read port (if read-back is routed through `apple_memory`)

---

## 12. Open Questions

### 12.1 Firmware ROM Source
The Videx VideoTerm ROM is copyrighted. Options:
- User provides their own ROM dump (loaded via `.hex` file)
- Open-source terminal firmware (would need to be written)
- Investigate abandonware/fair-use status

### 12.2 VRAM Read-Back Architecture
The shadow `sdpram32` read port is used by the video scanner. For CPU reads of $CC00-$CDFF, options:
- **Option A:** Card maintains its own copy of VRAM for reads (adds 2 KB BSRAM, simplest)
- **Option B:** Time-multiplex the shadow VRAM read port between scanner and CPU (requires careful timing)
- **Option C:** Replace `sdpram32` with true dual-port RAM (if FPGA supports it)
- **Recommendation:** Option A is simplest. 2 KB BSRAM is cheap on the target FPGAs.

### 12.3 Interaction Between Shadow and Emulation
When the emulated card is active, the existing shadow capture logic still runs (it snoops the same bus transactions the card generates). This is actually beneficial — the shadow populates the same VRAM and CRTC registers that the VIDEX_LINE renderer reads. No conflict exists because the shadow and the card agree on the bus state.

However, if both an external Videx card AND the emulated card were active simultaneously (shouldn't happen, but defensive design), there would be bus contention. The card should only be enabled on ][/][+ systems, or when explicitly configured.

### 12.4 Apple ][+ Bus Signal Handling
The `m2sel_n` signal used in slot decode (`apple_memory.sv:197`, `slotmaker.sv`) is an IIe signal. On a ][/][+:
- Verify the A2FPGA bus interface drives `m2sel_n` correctly for ][+ (should be active/low for all I/O access)
- The slot decode logic in `slotmaker.sv` uses `!a2bus_if.m2sel_n` as a guard — this must pass on a ][+

---

## 13. Multiple Character Set Support

### 13.1 Background: Real Videx Character ROMs

The original Videx VideoTerm had two character ROM sockets (U17 and U20), each accepting a 2716 EPROM (2 KB). Bit 7 of each VRAM character byte selected which ROM to read: bit 7 = 0 read from the "normal" ROM (U20), bit 7 = 1 read from the "alternate" ROM (U17). To change character sets, you physically swapped EPROM chips.

Available character sets included: US (Normal), Uppercase-only, French, German, Spanish, Katakana, APL, Super/Subscript, Epson, Symbol, Graphics, Norwegian, Russian, and Inverse. At any given time, only 2 could be installed.

Each character set ROM: 128 characters × 16 bytes/character = 2,048 bytes. Only 9 of the 16 bytes per character are displayed (scanlines 0-8, matching MC6845 R9=8). Character cells are 7 pixels wide × 9 scanlines tall.

### 13.2 A2DVI Implementation

A2DVI supports 10 selectable Videx character sets at runtime (sourced from the ThorstenBr/A2DVI-Firmware repository):

| Index | Set | Source File |
|-------|-----|-------------|
| 1 | US (Normal) | `videx_normal.c` |
| 2 | Uppercase | `videx_uppercase.c` |
| 3 | German | `videx_german.c` |
| 4 | French | `videx_french.c` |
| 5 | Spanish | `videx_spanish.c` |
| 6 | Katakana | `videx_katakana.c` |
| 7 | APL | `videx_apl.c` |
| 8 | Super/Sub | `videx_super_sub.c` |
| 9 | Epson | `videx_epson.c` |
| 10 | Symbol | `videx_symbol.c` |

Plus `videx_inverse.c` (always paired as the alternate/bit-7 set). Each source file is 2,048 bytes (128 chars × 16 bytes). The user selects the active character set via the A2DVI on-screen configuration menu. The RP2040 processor has ample flash to store all sets simultaneously.

### 13.3 Current A2FPGA State

The current Videx character ROM in A2FPGA contains **only 1 normal set (US) + 1 inverse set**:

```
File: hdl/video/videx_charrom.hex (4,096 entries, one byte per line)
  Entries 0x000-0x7FF: US Normal (128 chars × 16 bytes = 2,048 bytes)
  Entries 0x800-0xFFF: Inverse (128 chars × 16 bytes = 2,048 bytes)

Instantiation: apple_video.sv:211
  reg [7:0] videxrom_r[4095:0];
  initial $readmemh("videx_charrom.hex", videxrom_r, 0);

Addressing: videxrom_a_r = {char[7:0], scanline[3:0]}  (12 bits)
Storage: distributed SSRAM (LUT-based), ~150 SSRAM units
```

The ROM is generated by `tools/gen_videx_rom.py`, which fetches only `videx_normal.c` and `videx_inverse.c` from the A2DVI GitHub.

### 13.4 BSRAM Budget Reality

**Is the full character ROM data currently loaded?** No. Only 1 of 10 normal character sets is present.

**Does the FPGA have capacity for all 10?** This is constrained. The synthesis report for the a2n20v2 board (`boards/a2n20v2/impl/pnr/a2n20v2.rpt.txt`) shows:

```
GW2AR-18C BSRAM utilization: 40/46 blocks (87%)
  28 SDPB + 8 DPB + 2 DPX9B + 2 pROM = 40 blocks used
  6 blocks free (~13.5 KB)
```

The Videx emulated card itself needs BSRAM:
| Card Component | BSRAM Blocks |
|---------------|-------------|
| Firmware ROM (2 KB) | 1 |
| Card VRAM for CPU read-back (2 KB) | 1 |
| **Subtotal: card baseline** | **2** |
| **Remaining for character ROM** | **4 blocks (~9 KB)** |

With only 4 blocks remaining after the card's baseline needs, the options for character ROM are severely constrained:

| Configuration | Bytes | Blocks Needed | Fits in 4? |
|--------------|-------|---------------|------------|
| Current: 1 normal + 1 inverse (SSRAM) | 4,096 | 0 (stays in SSRAM) | Yes |
| 4 normal + 1 inverse | 10,240 | 5-6 | No |
| All 10 normal + 1 inverse | 22,528 | 10-12 | No |
| 32 KB banked ROM (16 banks) | 32,768 | 15 | No |

**The 32 KB banked ROM approach proposed earlier is NOT feasible on the standard a2n20v2.** It would need 15 blocks but only 4 are available after card baseline allocation.

(Note: the a2n20v2-Enhanced board uses only 28/46 blocks (61%), leaving 18 free — enough for the full multi-set ROM. But the standard board is the primary target.)

### 13.5 Feasible Approaches Given BSRAM Constraints

**Option A: Keep current SSRAM, single character set (recommended for initial implementation)**
- Keep the 4 KB Videx char ROM in distributed SSRAM (~150 SSRAM units, as today)
- Only 1 normal + 1 inverse set available
- Card firmware ROM (2 KB) and VRAM read-back (2 KB) use 2 BSRAM blocks
- 4 blocks remain free for other future needs
- User selects character set at build time by regenerating `videx_charrom.hex`

**Option B: Move char ROM to BSRAM, fit 2-3 selectable sets**
- Move the Videx char ROM from SSRAM to BSRAM, freeing ~150 SSRAM units
- Expand to 3 normal sets + 1 inverse = 4 × 2 KB = 8 KB ≈ 4 BSRAM blocks
- Combined with card baseline: 2 + 4 = 6 blocks total (all 6 free blocks used)
- Allows runtime selection among 3 character sets via config register
- Tight but feasible; leaves 0 blocks free

**Option C: Build-time selection from full library**
- `gen_videx_rom.py` fetches all 10 A2DVI character sets
- User selects which normal set to include at build time (parameter or config)
- The hex file always contains 1 normal + 1 inverse (4 KB in SSRAM)
- No BSRAM cost for character ROM; full library available but requires rebuild
- **Recommended as the practical compromise for the standard board**

**Option D: Enhanced board gets full runtime selection**
- On a2n20v2-Enhanced (18 free blocks): use the 32 KB banked ROM approach
- On standard a2n20v2 (6 free blocks): fall back to Option A or C
- Make the ROM size a synthesis parameter: `VIDEX_CHARSET_COUNT`

### 13.6 Proposed Architecture

For the initial implementation (Option A/C):
```
Character ROM: 4 KB SSRAM (unchanged from current passive shadow)
  Entries 0x000-0x7FF: Selected normal set (default: US)
  Entries 0x800-0xFFF: Inverse
  Addressing: videxrom_a_r = {char[7:0], scanline[3:0]}  (12 bits)
  Character set selection: build-time (gen_videx_rom.py parameter)
```

For enhanced boards or future BSRAM optimization (Option D):
```
Character ROM: 32 KB BSRAM (banked)
  Size: 32,768 entries × 8 bits (15-bit address)
  Layout: 16 banks × 128 chars × 16 bytes/char
    Banks 0-9: US, Uppercase, German, French, Spanish, Katakana, APL, Super/Sub, Epson, Symbol
    Bank 15: Inverse
  Addressing:
    if (char_code[7] == 0)  // Normal character
      rom_addr = {config_set_select[3:0], char_code[6:0], scanline[3:0]}
    else                    // Inverse character (bit 7 set)
      rom_addr = {INVERSE_BANK[3:0],     char_code[6:0], scanline[3:0]}
  Configuration register: 4-bit, selects normal set bank (0-9)
```

### 13.7 Implementation Changes

**`tools/gen_videx_rom.py`:**
- Expand to fetch all 10 A2DVI character sets + inverse
- Add `--charset` parameter to select which normal set to include (default: US)
- For single-set mode: output 4,096-line hex file (as today)
- For multi-set mode: output 32,768-line hex file with bank layout

**`hdl/video/apple_video.sv` (multi-set only):**
- Expand ROM array and address width
- Add bank select mux on char code bit 7

**`hdl/videx/videx_card.sv` (multi-set only):**
- Add configuration register for character set selection
- Accessible via `slot_if.card_config` mechanism or unused CRTC register index

### 13.8 Phase Recommendation

Multiple character set support is **Phase 5** (Refinements). Initial implementation should use the current single-set SSRAM approach (Option A) with build-time character set selection (Option C). This avoids BSRAM pressure and keeps the initial card implementation focused on correctness.

The `gen_videx_rom.py` enhancement to fetch all 10 sets and accept a `--charset` parameter is low-effort and should be done early so users can select their preferred character set from day one.

---

## 14. Resource Summary (Approach B)

### 14.1 Actual BSRAM Budget

From synthesis report (`boards/a2n20v2/impl/pnr/a2n20v2.rpt.txt`):
```
BSRAM: 40/46 blocks used (87%)
Free: 6 blocks (~13.5 KB)
```

### 14.2 Resource Allocation

| Resource | Existing (shadow) | New (card) | BSRAM Blocks |
|----------|-------------------|------------|-------------|
| Firmware ROM | — | 2 KB BSRAM | **1** |
| CRTC register file | 128 FFs (shadow) | 128 FFs (card) | 0 |
| VRAM (scanner-facing) | 2 KB BSRAM (shadow) | — | 0 (existing) |
| VRAM (CPU read-back) | — | 2 KB BSRAM | **1** |
| Videx character ROM (single set) | 4 KB SSRAM | — | 0 (stays in SSRAM) |
| Bus response logic | — | ~200 LUTs | 0 |
| VIDEX_LINE pipeline | Existing | — | 0 (existing) |
| **Total new BSRAM** | | | **2 blocks** |
| **Remaining free** | | | **4 blocks** |

### 14.3 Multi-Character-Set Cost (if enabled)

| Configuration | Additional BSRAM | Total Card BSRAM | Remaining Free |
|--------------|-----------------|-----------------|----------------|
| Single set (SSRAM, default) | 0 | 2 blocks | 4 blocks |
| 3 selectable sets + inverse | 4 blocks (replaces SSRAM) | 6 blocks | 0 blocks |
| All 10 sets (Enhanced board only) | 15 blocks | 17 blocks | n/a (needs Enhanced) |

With a single character set, the card uses only 2 of 6 available BSRAM blocks — a comfortable fit. Multi-set support on the standard board is tight but possible for a small number of sets.
