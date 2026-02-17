# HDMI Output Path Investigation Report

**Date:** 2026-02-15
**Scope:** Complete investigation of HDMI output path in A2FPGA project
**Boards analyzed:** a2mega, a2p25, a2n20v1, a2n20v2, a2n20v2-Enhanced, a2n9

---

## 1. HDMI Module Instantiation

All 6 boards instantiate the HDMI core identically in their respective `top.sv` files:

| Board | File | Line |
|---|---|---|
| a2mega | `boards/a2mega/hdl/top.sv` | 598–636 |
| a2p25 | `boards/a2p25/hdl/top.sv` | 573–611 |
| a2n20v1 | `boards/a2n20v1/hdl/top.sv` | 535–566 |
| a2n20v2 | `boards/a2n20v2/hdl/top.sv` | 613–644 |
| a2n20v2-Enhanced | `boards/a2n20v2-Enhanced/hdl/top.sv` | 933–964 |
| a2n9 | `boards/a2n9/hdl/top.sv` | 430–461 |

### Parameters (all boards)

| Parameter | Value | Status |
|---|---|---|
| VIDEO_ID_CODE | 2 | Correct for 720×480p |
| DVI_OUTPUT | 0 | HDMI mode (InfoFrames enabled) |
| IT_CONTENT | 1 | Correct for direct framebuffer |
| VIDEO_REFRESH_RATE | 59.94 | Correct for NTSC-compatible |
| AUDIO_RATE | 44100 | Standard audio |
| START_X | 0 | Default |
| START_Y | 0 | Default |

### Signal Connections (all boards)

| Port | Signal | Notes |
|---|---|---|
| clk_pixel_x5 | `clk_hdmi_w` | 135 MHz |
| clk_pixel | `clk_pixel_w` | 27 MHz |
| clk_audio | `clk_audio_w` or `clk_audio_r` | 44.1 kHz derived |
| rgb | `{rgb_r_w, rgb_g_w, rgb_b_w}` | Via SuperSprite/DebugOverlay |
| reset | `~device_reset_n_w` or `!device_reset_n_w` | Active-high |
| tmds | `tmds[2:0]` | To ELVDS buffer |
| tmds_clock | `tmdsClk` | **Unused — see finding #4** |
| cx | `hdmi_x` | Fed back to video generators |
| cy | `hdmi_y` | Fed back to video generators |

**Verdict: PASS** — Parameters and connections are consistent and correct across all boards.

---

## 2. PLL / Clocking Configuration

### A2N20V2, A2N20V1, A2N9 (27 MHz input crystal)

```
clk (27 MHz)
  └─ clk_logic rPLL (FBDIV=2, IDIV=1)
       ├─ clkout:  54 MHz  → clk_logic_w
       └─ clkoutd: 27 MHz  → clk_pixel_w
                                └─ clk_hdmi rPLL (FBDIV=5, IDIV=1, ODIV=4)
                                     └─ clkout: 135 MHz → clk_hdmi_w
```

### A2MEGA, A2P25 (50 MHz input crystal)

```
clk (50 MHz)
  └─ PLLA (VCO configuration)
       ├─ clkout0: 27 MHz  → clk_27m_w (a2mega) / clk_pixel_w (a2p25)
       ├─ clkout1: 135 MHz → clk_hdmi_w (a2mega) / [varies]
       └─ clkout2: 54 MHz  → clk_logic_w
  └─ CLKDIV (DIV_MODE=5, a2mega only)
       └─ 135 MHz / 5 = 27 MHz → clk_pixel_w
```

### Expected vs Actual Frequencies

| Clock | Expected (VIC 2 @ 59.94 Hz) | Actual | Match |
|---|---|---|---|
| Pixel clock | 27.027 × (1000/1001) = 27.000 MHz | 27.000 MHz | **YES** |
| TMDS clock (5x) | 135.000 MHz | 135.000 MHz | **YES** |
| TMDS bit rate | 270 Mbps (DDR) | 135 MHz × 2 = 270 Mbps | **YES** |

### SDC Constraints

| Board | SDC File | Clock Chain |
|---|---|---|
| a2n20v2 | `boards/a2n20v2/hdl/a2n20v2.sdc` | 27 MHz → ×2 → /2 → ×5 |
| a2mega | `boards/a2mega/hdl/a2mega.sdc` | 50 MHz → ×54/50 → /2 → ×5 |

**Verdict: PASS** — All clock frequencies match the CEA-861 specification for VIC 2.

---

## 3. Timing Block Verification (VIDEO_ID_CODE = 2)

**File:** `hdl/hdmi/hdmi.sv:116–130`

| Parameter | Expected (CEA-861) | Actual | Match |
|---|---|---|---|
| frame_width | 858 | 858 | **YES** |
| frame_height | 525 | 525 | **YES** |
| screen_width | 720 | 720 | **YES** |
| screen_height | 480 | 480 | **YES** |
| hsync_pulse_start | 16 | 16 | **YES** |
| hsync_pulse_size | 62 | 62 | **YES** |
| vsync_pulse_start | 9 | 9 | **YES** |
| vsync_pulse_size | 6 | 6 | **YES** |
| invert (sync polarity) | 0 (active-HIGH) | 0 | **YES** |

The `invert = 0` value is correct. The code comments indicate this was previously `invert = 1` (active-LOW), which was incorrect for VIC 2/3 and has already been fixed.

The `VIDEO_RATE` localparam at `hdmi.sv:206–214` computes:
```
VIDEO_RATE = 27.027E6 * (1000.0/1001.0) = 27.000027E6 ≈ 27.000 MHz
```

This matches the PLL output.

**Verdict: PASS** — The HDMI core is the Sameer Puri implementation with correct VIC 2 timing.

---

## 4. HDMI vs DVI Mode

`DVI_OUTPUT = 0` on all boards.

This means:
- AVI InfoFrames **ARE** sent (via `packet_picker` module)
- Audio InfoFrames **ARE** sent
- Data island periods **ARE** active
- Video guard bands **ARE** generated

This is the correct configuration for maximum monitor compatibility. DVI mode would strip InfoFrames and could cause some monitors to reject the signal or default to incorrect color space / timing assumptions.

**Verdict: PASS** — HDMI mode is correctly enabled.

---

## 5. RGB Signal Path

The RGB signal path is identical in architecture across all boards:

```
                            cx/cy from HDMI core
                                    │
                                    ▼
    Memory ──► apple_video ──► apple_vga_r/g/b
                                    │
                                    ▼
                               vgc (VGC) ──► vgc_vga_r/g/b
                                    │
                                    ▼
                            SuperSprite ──► rgb_r/g/b_w
                                    │           (VDP overlay mux)
                                    ▼
                    [Scanline dimming: {1'b0, rgb[7:1]} on odd lines]
                                    │
                                    ▼
                    [DebugOverlay on a2n20v2/Enhanced]
                                    │
                                    ▼
                              HDMI .rgb input
```

### Key details:

- **apple_video** (`hdl/video/apple_video.sv`): Maps cx/cy to a 560×384 Apple II display centered in 720×480 with 80-pixel horizontal and 48-pixel vertical borders.
- **VGC** (`hdl/video/vgc.sv`): Maps cx/cy to a 640×400 display with 40-pixel borders.
- **SuperSprite** (`hdl/supersprite/supersprite.sv`): Overlays VDP (TMS9918A) graphics on top of Apple video. Transparent VDP pixels pass through the Apple video RGB.
- **Scanline dimming**: `scanline_en = scanlines_w && hdmi_y[0]` — right-shifts RGB by 1 bit on odd-numbered scanlines to simulate CRT scanlines.
- **DebugOverlay** (a2n20v2/Enhanced only): Optionally overlays debug text; passes through RGB when disabled.

The `rgb` input to the HDMI core receives the processed pixel data as `{R[7:0], G[7:0], B[7:0]}` — a 24-bit concatenation. The HDMI core samples this on the `clk_pixel` rising edge and assigns it to `video_data` (`hdmi.sv:333`).

**Verdict: PASS** — The RGB path is correctly driven with valid pixel data. cx/cy feedback loop is correct.

---

## 6. Reset Behavior

### A2MEGA and A2P25 (with Reset_Sync)

```verilog
// boards/a2mega/hdl/top.sv:675-691
module Reset_Sync (
    input clk, input ext_reset, output resetn
);
    reg [3:0] reset_cnt = 0;
    always @(posedge clk or negedge ext_reset) begin
        if (~ext_reset) reset_cnt <= 4'b0;
        else reset_cnt <= reset_cnt + !resetn;
    end
    assign resetn = &reset_cnt;
endmodule
```

- Asynchronous assert (negedge ext_reset clears counter)
- Synchronous deassert (counter counts to 0xF over 16 clk cycles)
- Output `resetn` goes high only when counter saturates
- **This is a proper CDC reset synchronizer**

### A2N20V1, A2N20V2, A2N20V2-Enhanced, A2N9 (combinational)

```verilog
// boards/a2n20v2/hdl/top.sv:114
wire device_reset_n_w = rst_n & clk_logic_lock_w & clk_hdmi_lock_w;
```

- No flip-flop synchronization
- Direct combinational AND of external reset and PLL lock signals
- PLL lock signals may glitch during startup

### Reset polarity at HDMI module

All boards invert `device_reset_n_w` when connecting to the HDMI core:
- `~device_reset_n_w` (a2n20v2, a2n20v1, a2n9, a2n20v2-Enhanced)
- `!device_reset_n_w` (a2mega, a2p25)

The HDMI core expects active-high reset (`if (reset)` at `hdmi.sv:219`). The inversion is correct.

**Verdict: MARGINAL** — Reset works but the combinational reset on a2n20v1/v2/v2-Enhanced/a2n9 is not ideal. Not likely the cause of HDMI output failures, but a design quality concern.

---

## 7. TMDS Serializer and Output

### Serializer Architecture

All Gowin boards use the `OSER10` primitive for 10:1 DDR serialization:

| Board | Serializer File | Mode |
|---|---|---|
| a2mega | `boards/a2mega/hdl/hdmi/serializer.sv` | GW_IDE_INVERTED |
| a2p25 | `boards/a2p25/hdl/hdmi/serializer.sv` | GW_IDE_INVERTED |
| a2n20v1, a2n20v2, a2n20v2-Enhanced, a2n9 | `hdl/hdmi/serializer.sv` | GW_IDE |

The OSER10 primitive:
- PCLK = `clk_pixel` (27 MHz) — parallel load clock
- FCLK = `clk_pixel_x5` (135 MHz) — serial shift clock
- DDR output: 2 bits per FCLK cycle × 5 cycles = 10 bits per PCLK cycle
- Effective bit rate: 270 Mbps per lane

### TMDS Clock Output — Finding

**In the serializer**, the `tmds_clock` output is:
- GW_IDE mode: `assign tmds_clock = clk_pixel;` (`hdl/hdmi/serializer.sv:163`)
- GW_IDE_INVERTED mode: `assign tmds_clock = ~clk_pixel;` (`boards/a2mega/hdl/hdmi/serializer.sv:166`)

**In all top.sv files**, the ELVDS output buffer is wired:
```verilog
ELVDS_OBUF tmds_bufds[3:0] (
    .I({clk_pixel_w, tmds}),     // <-- Uses clk_pixel_w directly
    ...
);
```

The `tmdsClk` signal (connected to `hdmi.tmds_clock`) is **declared but never used**.

For GW_IDE (non-inverted) boards: `tmds_clock = clk_pixel`, so `clk_pixel_w == tmdsClk`. No issue — they are the same signal.

For GW_IDE_INVERTED (a2mega, a2p25): `tmds_clock = ~clk_pixel`, but the top-level uses `clk_pixel_w` (non-inverted). The data channels ARE inverted, but the clock channel is NOT. If the board layout error that necessitated `GW_IDE_INVERTED` applies to all 4 differential pairs (including clock), then the clock should also be inverted. However, if only the data pairs are swapped, this is correct.

### ELVDS Output Buffers

| Board | Buffer Type | OEN Control |
|---|---|---|
| a2mega | `ELVDS_OBUF` (always on) | None |
| a2p25 | `ELVDS_OBUF` (always on) | None |
| a2n20v1/v2/v2-Enhanced | `ELVDS_TBUF` (tri-state) | `sleep_w && HDMI_SLEEP_ENABLE` |
| a2n9 | `ELVDS_TBUF` (tri-state) | `sleep_w && HDMI_SLEEP_ENABLE` |

### Pin Constraints

All boards specify `IO_TYPE=LVCMOS33D` for HDMI TMDS pins (differential LVDS at 3.3V):

| Board | Clock P/N | D0 P/N | D1 P/N | D2 P/N | Drive |
|---|---|---|---|---|---|
| a2mega | G16/G15 | H14/J14 | H15/J15 | J17/K17 | 8mA |
| a2p25 | G2/G1 | J4/K4 | K1/K2 | L2/L1 | 8mA |
| a2n20v2 | 33/34 | 35/36 | 37/38 | 39/40 | 8mA |
| a2n9 | 69/68 | 71/70 | 73/72 | 75/74 | default |

**Verdict: PASS** — Serializer and output are correctly configured.

---

## 8. Summary of All Findings

### Confirmed Correct

| Subsystem | Status |
|---|---|
| VIDEO_ID_CODE = 2 (720×480p) | ✅ Correct |
| Timing parameters (858×525, sync polarity) | ✅ Correct (invert=0 already fixed) |
| Pixel clock = 27.000 MHz | ✅ Matches VIC 2 at 59.94 Hz |
| TMDS clock = 135 MHz (5× pixel) | ✅ Correct |
| DVI_OUTPUT = 0 (HDMI mode) | ✅ Correct |
| RGB path driven with valid pixel data | ✅ Correct |
| cx/cy feedback to video generators | ✅ Correct |
| Reset polarity (active-high to HDMI core) | ✅ Correct |
| Pin constraints (LVCMOS33D) | ✅ Correct |
| OSER10 serializer configuration | ✅ Correct |

### Minor Concerns (non-blocking)

| Finding | Severity | Details |
|---|---|---|
| Combinational reset on a2n20v1/v2/v2-Enhanced/a2n9 | Low | No synchronizer — could have metastability on PLL lock glitches |
| A2N9 missing explicit DRIVE=8 on HDMI pins | Low | Uses device default, likely fine |
| `tmdsClk` signal declared but unused | Info | Top-level uses `clk_pixel_w` directly — functionally identical for non-inverted boards |

### No Code-Level Bugs Found

The HDMI output path has **no incorrect parameters, no clock mismatches, and no signal routing errors** at the RTL level. The sync polarity issue (`invert`) has already been corrected in the current codebase.

---

## 9. Hypothesis List: Remaining Failure Modes

If the HDMI output is still not working despite the RTL being correct, the following hardware-level issues should be investigated:

### A. TMDS Serializer Phase Alignment
- The OSER10 primitive requires PCLK and FCLK to have a specific phase relationship (both derived from the same PLL or CLKDIV)
- On the a2n20v2/a2n20v1/a2n9, clk_pixel comes from `clk_logic.clkoutd` and clk_hdmi comes from a **separate rPLL** (`clk_hdmi`) fed by `clk_pixel_w`
- The two PLLs may not maintain stable phase alignment → potential TMDS data eye closure
- **Test:** Check if both clocks can be generated from a single PLL (as the a2mega/a2p25 do with PLLA + CLKDIV)

### B. PLL Cascade Stability
- On a2n20v2/a2n20v1/a2n9, the HDMI PLL is cascaded: `clk (27 MHz) → clk_logic PLL → clkoutd (27 MHz) → clk_hdmi PLL → 135 MHz`
- Cascading PLLs can introduce jitter accumulation
- The `clk_hdmi` PLL receives its input from the divided output of `clk_logic` PLL, not directly from the crystal
- **Test:** Route the crystal clock directly to the HDMI PLL input instead of the divided PLL output

### C. Incorrect Pin Constraints (PCB routing)
- The pin assignments in `.cst` files must match the physical board layout
- If TMDS pairs are routed to wrong pins, the output will be garbled or absent
- **Verify:** Check PCB schematic against `.cst` file pin numbers

### D. Wrong I/O Standard on HDMI Pins
- LVCMOS33D is the standard choice for TMDS on Gowin FPGAs
- Some older Gowin devices may need `LVDS25` instead
- **Verify:** Check the Gowin device datasheet for supported LVDS I/O standards on the specific bank containing HDMI pins

### E. Missing Differential Pair Constraints
- Gowin automatically pairs P/N pins from the `IO_LOC` specification (two pin numbers)
- If the pin numbers are in the wrong order (N listed before P), polarity could be swapped
- **Verify:** Check that the first pin number in each `IO_LOC` is the positive pin per the device package pinout

### F. TMDS Clock Routing on A2MEGA
- The a2mega uses `GW_IDE_INVERTED` to invert data but sends `clk_pixel_w` (non-inverted) to the clock ELVDS buffer
- If the board layout requires ALL differential pairs (including clock) to be inverted, the clock should use `tmdsClk` (which is `~clk_pixel`) instead of `clk_pixel_w`
- **Test:** Change `.I({clk_pixel_w, tmds})` to `.I({tmdsClk, tmds})` in `boards/a2mega/hdl/top.sv:649`

### G. HDMI Connector / Physical Layer
- Bad solder joints on HDMI connector
- Missing AC coupling capacitors on TMDS lines
- Incorrect pull-up/pull-down resistors on HPD (Hot Plug Detect) or DDC lines
- **Verify:** Physical inspection and continuity testing

### H. Monitor EDID / Handshake
- Some monitors require DDC (I2C) communication before accepting HDMI input
- The FPGA does not implement DDC — the monitor must accept the signal without EDID negotiation
- Most monitors handle this, but some Samsung models may require it
- **Test:** Try a different monitor or an HDMI-to-VGA adapter (which typically has no EDID requirement)

### I. TMDS Voltage Levels
- LVCMOS33D on Gowin produces approximately ±300mV differential swing
- HDMI spec requires 400-600mV differential swing
- If the swing is too low, the monitor's TMDS receiver may not lock
- **Test:** Measure differential voltage on TMDS pins with an oscilloscope
- **Fix:** Some Gowin devices support `DRIVE=` settings higher than 8 for LVDS — check if DRIVE=12 or DRIVE=16 is available

### J. Audio Clock Accuracy
- The audio clock on a2n9 is generated by a simple counter divider, not a proper fractional divider
- AUDIO_CLK_COUNT = (27,000,000 / 2) / 44100 = 306 (integer division)
- Actual audio rate = 13,500,000 / 306 = 44,117.6 Hz (0.04% error)
- This is within HDMI spec tolerance, but the audio CTS/N values in the HDMI core are computed assuming exactly 44,100 Hz
- This is unlikely to cause display issues but could cause audio drift or clicks

---

## 10. HDMI vs DVI Mode Failure Analysis (Follow-up)

**Observation:** DVI mode (DVI_OUTPUT=1) produces video on the Ingnok flat panel,
but HDMI mode (DVI_OUTPUT=0) does not. Samsung Odyssey G9 fails in both modes.

### What differs in HDMI mode

When `DVI_OUTPUT=0`, the following additional logic is activated:
- Video preambles (8-pixel control sequences before video guard bands)
- Video guard bands (2-pixel fixed TMDS patterns before active video)
- Data island preambles (8-pixel control sequences before data islands)
- Data island guard bands (2-pixel TERC4/guard patterns)
- Data island periods (96 pixels per H blank = 3 × 32-pixel packets)
- TERC4 encoding for data islands
- Packet generation: AVI InfoFrame, Audio InfoFrame, ACR, SPD, audio samples, null

### Issues found in the HDMI packet layer

**Issue 1: Null packet and ACR header use `X` (don't-care) values in synthesis.**
Files: `packet_picker.sv:42-46`, `audio_clock_regeneration_packet.sv:63`

The null packet header bytes HB1/HB2 and all subpacket data were assigned `8'dX`
/ `56'dX`. While the HDMI spec says sinks "shall ignore" these bytes, the BCH ECC
is computed over whatever values the synthesizer substitutes for `X`. If the
synthesizer's optimization produces values inconsistent between the data path and
the ECC path, every null packet would have a BCH error. Some HDMI sinks may
reject a signal with persistent ECC errors.

**Fix:** Changed all `X` values to deterministic `0` values.

**Issue 2: `packet_type` set to `X` on `video_field_end`.**
File: `packet_picker.sv:163`

On each `video_field_end` event, `packet_type` was reset to `8'dx`. This causes
`headers[X]` and `subs[X]` to produce undefined mux outputs during the brief
window between video_field_end and the next packet_enable. While this window
doesn't overlap with data island periods, the combinational mux glitch propagates
to the packet_assembler's BCH computation inputs.

**Fix:** Changed to `8'd0` (null packet type).

**Issue 3: AVI InfoFrame PICTURE_ASPECT_RATIO left at "no data".**
File: `packet_picker.sv:130-133`

The AVI InfoFrame was instantiated with only `VIDEO_ID_CODE` and `IT_CONTENT`
overridden. `PICTURE_ASPECT_RATIO` defaulted to `2'b00` ("no data"). Per CTA-861,
VIC 2 requires 4:3 aspect ratio (`2'b01`) and VIC 3 requires 16:9 (`2'b10`).
Some HDMI sinks validate that the aspect ratio in the InfoFrame is consistent
with the declared VIC, and reject signals where it's missing.

**Fix:** Set `PICTURE_ASPECT_RATIO` to `2'b01` (4:3) for VIC 2.

### Samsung Odyssey G9 — separate issue

The Samsung fails in BOTH DVI and HDMI modes. Since DVI mode works on the Ingnok
(proving basic TMDS signaling is correct), the Samsung issue is at a different
level. Possible causes:
- Samsung requires DDC/EDID negotiation before accepting HDMI input
- TMDS differential voltage swing too low for Samsung's receiver
- Samsung firmware doesn't support 480p (VIC 2) at all over its HDMI port
- Samsung requires HPD (Hot Plug Detect) signaling

### Recommended next steps

1. Test with the fixes above (null packet cleanup + aspect ratio) on the Ingnok
2. If Ingnok still rejects HDMI mode, try setting `VIDEO_ID_CODE` to 0 in the
   AVI InfoFrame only (while keeping timing at VIC 2) — this tells the sink to
   treat the signal as IT/PC timing rather than a CEA mode
3. For Samsung: compare the A2DVI output parameters (VIC, resolution, pixel clock)
   against the A2FPGA output to identify what A2DVI does differently
4. Measure TMDS differential voltage on the physical HDMI connector with an
   oscilloscope

5. **Measure TMDS differential swing** with an oscilloscope to confirm adequate voltage levels.
