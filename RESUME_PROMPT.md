# Resume Prompt: Samsung TV HDMI Compatibility Investigation

**Last updated:** 2026-02-16
**Branch:** `claude/fix-cicd-build-failure-w56RF` (7 commits ahead of `main`)
**Repository:** `BrentRector/a2fpga_core` (fork of `edanuff/a2fpga_core`)

---

## Context

This is an Apple II FPGA coprocessor card project (A2FPGA) targeting the Sipeed Tang Nano 20K (Gowin GW2AR-18C FPGA). It outputs HDMI video at 720x480p (CEA-861 VIC 2, 27 MHz pixel clock). The HDMI implementation uses the hdl-util/hdmi library by Sameer Puri.

A reference project, **A2DVI** (RP2040-based, using the PicoDVI library), outputs the same 720x480p resolution and works correctly on all tested displays, including a Samsung TV. A2FPGA works on an Ingnok portable monitor but does NOT work on the Samsung TV.

The goal is to make A2FPGA's HDMI output work on the Samsung TV.

---

## What Has Been Done (all on this branch)

### Changes already committed and pushed

1. **CI/CD build fixes** (commits `8ffbae1`, `d517d17`, `f64f943`):
   - Fixed `gowin_pack` device name from `GW2AR-18C` to `GW2A-18C` (Apycula only recognizes the die name)
   - Added openFPGALoader flashing instructions

2. **HDMI protocol fixes** — port of upstream hdl-util/hdmi PR #44 (commit `0825bd5`):
   - VSync off-by-one: added `-1` to start/end cy comparisons (`hdl/hdmi/hdmi.sv:195,197`)
   - Video guard/preamble: exclude last active line (`hdmi.sv:257-258`)
   - Data island timing: shifted +4 px for minimum control periods (`hdmi.sv:275,277,289,290`)
   - Max packets formula: corrected accounting (`hdmi.sv:270`)
   - Blocking assignment: `control_data = 6'd0` → `control_data <= 6'd0` (`hdmi.sv:324`)

3. **HDMI data island packet fixes** (merged from PR #7, commit `3e1c981` on `main`):
   - Null packet: `8'dX` → `8'd0` for deterministic BCH ECC
   - ACR packet: removed `ifdef MODEL_TECH` guard
   - `packet_type` reset: `8'dx` → `8'd0`

4. **AVI InfoFrame improvements** (commits `f09f504`):
   - Set `PICTURE_ASPECT_RATIO` to match VIC (4:3 for VIC 2, 16:9 for VIC 3) — `hdl/hdmi/packet_picker.sv:136`
   - Set `ACTIVE_FORMAT_INFO_PRESENT=1` — `packet_picker.sv:139`
   - Set `SCAN_INFO=2'b10` (underscan) — `packet_picker.sv:141`
   - Set `RGB_QUANTIZATION_RANGE=2'b10` (full-range RGB) — `packet_picker.sv:144`

5. **TMDS clock phase alignment** (commit `e4ff5d4`):
   - Replaced `assign tmds_clock = clk_pixel` with 4th OSER10 serializer (`hdl/hdmi/serializer.sv:167-185`)
   - Pattern `0000011111` produces pixel-rate clock phase-aligned to data channels
   - Updated `boards/a2n20v2/hdl/top.sv:649` to use `tmdsClk` instead of `clk_pixel_w`

### What was tested and ruled out

| Hypothesis | Result |
|------------|--------|
| Resolution mismatch | A2DVI works on Samsung at 720x480 too — ruled out |
| HDMI vs DVI mode | A2FPGA tested with `DVI_OUTPUT=1` — still fails on Samsung |
| Sync polarity | Both use negative (active-LOW, `invert=1`) — identical |
| TMDS clock phase | Tested both raw PLL clock and OSER10-serialized — neither fixed Samsung |
| VSync PR #44 off-by-one | Original baseline (before PR #44) also never worked on Samsung |
| AVI InfoFrame content | Added aspect ratio, scan info, quantization range — no change (also irrelevant since DVI fails too) |
| Null/ACR packet BCH errors | Fixed X values — no change |
| TMDS control character encoding | Verified identical to DVI 1.0 spec |

---

## What Remains To Be Tested

There are exactly **two untested hypotheses** that could explain Samsung's failure:

### Hypothesis 1: TMDS Voltage Swing Too Low

**The problem:** Gowin's `LVCMOS33D` output with `DRIVE=8` produces approximately 300-400 mV differential swing. The DVI/HDMI specification requires a minimum of 400 mV. A2DVI (RP2040) uses external resistor networks targeting 400-600 mV.

**The fix:** Change `DRIVE=8` to `DRIVE=16` for all four TMDS pins in `boards/a2n20v2/hdl/a2n20v2.cst` (lines 27, 30, 33, 36):
```
IO_PORT "tmds_clk_p" IO_TYPE=LVCMOS33D PULL_MODE=NONE DRIVE=16;
IO_PORT "tmds_d_p[0]" IO_TYPE=LVCMOS33D PULL_MODE=NONE DRIVE=16;
IO_PORT "tmds_d_p[1]" IO_TYPE=LVCMOS33D PULL_MODE=NONE DRIVE=16;
IO_PORT "tmds_d_p[2]" IO_TYPE=LVCMOS33D PULL_MODE=NONE DRIVE=16;
```

**Caveats:** Verify that the Gowin GW2AR-18C supports `DRIVE=16` for LVCMOS33D pins. If not, `DRIVE=12` or the maximum supported value should be used. Higher drive strength increases power consumption and EMI but is necessary if the swing is below spec minimum.

### Hypothesis 2: VSync Transition Point Within a Line

**The problem:** A2FPGA transitions VSync at the HSync pulse start position (cx=736), not at line boundaries. The code at `hdl/hdmi/hdmi.sv:191-201` has special-case handling:
- On the VSync-start line: VSync goes active only after cx reaches the HSync position
- On the VSync-end line: VSync goes inactive at the HSync position
- Between those lines: VSync is active for the entire line

A2DVI transitions VSync at **line boundaries** (effectively cx=0 — the DMA interrupt fires at end of back porch and the new VSync level takes effect from the first pixel of the next line).

**The fix:** Simplify VSync to be purely line-based (remove the mid-line transition logic):
```systemverilog
always_comb begin
    hsync <= invert ^ (cx >= screen_width + hsync_pulse_start && cx < screen_width + hsync_pulse_start + hsync_pulse_size);
    vsync <= invert ^ (cy >= screen_height + vsync_pulse_start && cy < screen_height + vsync_pulse_start + vsync_pulse_size);
end
```
This eliminates the `if/else if` for `cy == screen_height + vsync_pulse_start - 1` and `cy == screen_height + vsync_pulse_start + vsync_pulse_size - 1`.

**Caveats:** The HDMI spec says VSync should transition at HSync, so the current code is technically more correct per spec. But if Samsung's sync detector expects line-aligned transitions, the simpler version may work. Test both approaches.

---

## Key Files

| File | Purpose |
|------|---------|
| `hdl/hdmi/hdmi.sv` | Main HDMI controller — timing, sync, preambles, guard bands, data islands |
| `hdl/hdmi/serializer.sv` | TMDS 10:1 serializer (OSER10) including clock channel |
| `hdl/hdmi/packet_picker.sv` | Selects which HDMI packet to send (AVI, audio, ACR, null) |
| `hdl/hdmi/packet_assembler.sv` | Assembles packet headers/subpackets with BCH ECC |
| `hdl/hdmi/tmds_channel.sv` | TMDS 8b/10b encoding with DC balance |
| `hdl/hdmi/auxiliary_video_information_info_frame.sv` | AVI InfoFrame generation |
| `hdl/hdmi/audio_clock_regeneration_packet.sv` | ACR (N/CTS) packet |
| `boards/a2n20v2/hdl/top.sv` | Board top-level — PLL, HDMI instantiation, ELVDS buffers |
| `boards/a2n20v2/hdl/a2n20v2.cst` | Pin constraints including TMDS drive strength |
| `boards/a2n20v2/hdl/a2n20v2.sdc` | Timing constraints |
| `HDMI_INVESTIGATION_REPORT.md` | Detailed investigation report from earlier session |

---

## Architecture Quick Reference

### Clock chain (a2n20v2)
```
Crystal 27 MHz
  └─ PLL1 (clk_logic): FBDIV=2, IDIV=1
       ├─ clkout:  54 MHz  → clk_logic_w (main bus logic)
       └─ clkoutd: 27 MHz  → clk_pixel_w (pixel clock)
                                └─ PLL2 (clk_hdmi): FBDIV=5, IDIV=1, ODIV=4
                                     └─ clkout: 135 MHz → clk_hdmi_w (TMDS 5x clock)
```

### TMDS output chain
```
hdmi.sv (24-bit RGB → TMDS 8b/10b encoding → 10-bit parallel symbols)
  └─ serializer.sv (4x OSER10: 10-bit parallel → serial at 270 Mbps)
       └─ top.sv (ELVDS_TBUF: single-ended → differential TMDS pairs)
            └─ a2n20v2.cst (pin mapping, IO_TYPE=LVCMOS33D, DRIVE=8)
```

### Video timing (VIC 2, 720x480p @ 59.94 Hz)
```
H: |<-- 720 active -->|<- 16 fp ->|<- 62 sync ->|<- 60 bp ->| = 858 total
V: |<-- 480 active -->|<- 9 fp  ->|<- 6 sync  ->|<- 30 bp ->| = 525 total
Sync polarity: Negative (active-LOW, invert=1)
```

---

## How to Build and Test

### Build with Gowin IDE
Open `boards/a2n20v2/a2n20v2.gprj` in Gowin IDE, synthesize, place & route, generate bitstream.

### Build with OSS toolchain
```bash
cd boards/a2n20v2 && bash oss/prepare_build.sh
# Follow the printed yosys/nextpnr/gowin_pack commands
# Flash: openFPGALoader -b tangnano20k -f a2n20v2.fs
```

### Test procedure
1. Flash bitstream to Tang Nano 20K
2. Install card in Apple IIe
3. Connect HDMI cable to Samsung TV
4. Power on Apple IIe
5. Check if Samsung displays the 720x480p signal
6. Also verify Ingnok monitor still works (regression test)

---

## Important Notes

- The upstream repo is `edanuff/a2fpga_core`. Our fork is `BrentRector/a2fpga_core`.
- The `invert` parameter for VIC 2/3 is set to `1` (negative polarity). An earlier session incorrectly changed it to `0`; that was reverted. **Do not change `invert` — it is correct at `1`.**
- `DVI_OUTPUT=0` is the default (HDMI mode with InfoFrames). Setting `DVI_OUTPUT=1` (pure DVI) was tested and also fails on Samsung, so the issue is not in the HDMI packet layer.
- The Samsung TV model is a Samsung Odyssey G9.
- The Gowin OSER10 requires PCLK (27 MHz) and FCLK (135 MHz) from related clock domains. Currently they come from two cascaded PLLs which may introduce phase uncertainty, but this hasn't caused observable issues on the Ingnok monitor.
- See also `HDMI_INVESTIGATION_REPORT.md` in the repo root for the earlier detailed output-path investigation.

---

## Appendix: A2DVI vs A2FPGA Comprehensive Comparison Report

This appendix is the full side-by-side comparison of A2DVI and A2FPGA, covering every known difference between the two implementations. It represents the complete state of understanding as of 2026-02-16.

### Test Environment

| | A2DVI | A2FPGA |
|--|-------|--------|
| **Platform** | RP2040 (Raspberry Pi Pico) | Gowin GW2AR-18C (Tang Nano 20K) |
| **Library** | PicoDVI (by Luke Wren) | hdl-util/hdmi (by Sameer Puri) |
| **Video Mode** | 720x480p @ 59.94 Hz (VIC 2) | 720x480p @ 59.94 Hz (VIC 2) |
| **Pixel Clock** | 27.0 MHz | 27.0 MHz |
| **Protocol** | Pure DVI (no data islands) | HDMI (data islands, InfoFrames, audio) |
| **Samsung TV** | Works | Does not work |
| **Ingnok Monitor** | Works | Works |

### Timing Parameters (Identical)

Both implementations use the same CEA-861-D VIC 2 timing:

| Parameter | A2DVI | A2FPGA |
|-----------|-------|--------|
| Active pixels | 720 x 480 | 720 x 480 |
| H front porch | 16 px | 16 px |
| H sync width | 62 px | 62 px |
| H back porch | 60 px | 60 px |
| H total | 858 px | 858 px |
| V front porch | 9 lines | 9 lines |
| V sync width | 6 lines | 6 lines |
| V back porch | 30 lines | 30 lines |
| V total | 525 lines | 525 lines |
| Sync polarity | Negative (active-LOW) | Negative (active-LOW, `invert=1`) |

### Differences Ruled Out by Testing

| Hypothesis | How Tested | Result |
|------------|-----------|--------|
| **Resolution mismatch** | A2DVI confirmed working on Samsung in 720x480 mode | Both use 720x480 -- ruled out |
| **HDMI vs DVI mode** | A2FPGA tested with `DVI_OUTPUT=1` (pure DVI) | Still fails on Samsung -- ruled out |
| **Sync polarity** | Both use negative polarity for VIC 2 | Identical -- ruled out |
| **TMDS clock phase-locked to data** | A2FPGA tested both with raw PLL1 clock (`assign tmds_clock = clk_pixel`, not phase-locked) and OSER10 serialized clock (phase-locked) | Neither worked on Samsung -- ruled out |
| **VSync PR #44 off-by-one** | Original baseline code (before PR #44) also never worked on Samsung | Pre-existing issue -- ruled out |
| **AVI InfoFrame content** | Added PICTURE_ASPECT_RATIO, ACTIVE_FORMAT_INFO_PRESENT, SCAN_INFO, RGB_QUANTIZATION_RANGE | Still fails; also irrelevant since DVI mode fails too -- ruled out |
| **Null/ACR packet BCH ECC errors** | Fixed `X` values to deterministic zeros | Still fails -- ruled out |
| **TMDS control character encoding** | Verified identical to DVI 1.0 spec in both implementations | Identical -- ruled out |

### Remaining Differences (Not Yet Tested)

#### 1. VSync Transition Point Within a Line

**A2DVI**: VSync transitions at **line boundaries** (effectively cx=0). The DMA interrupt fires at the end of the back porch, advances the vertical state machine, and the new VSync level takes effect from the first pixel of the next line. VSync is purely a function of line number.

**A2FPGA**: VSync transitions at the **HSync pulse start position** (cx=736). The code explicitly aligns VSync edges to HSync: on the line where VSync starts, it goes active only after cx reaches the HSync position. On the line where VSync ends, it goes inactive at the HSync position. Between those two lines, VSync is active for the entire line.

The DVI/HDMI spec does not strictly mandate where within a line VSync must transition, but Samsung's sync detector may expect or prefer line-boundary-aligned VSync transitions.

This difference exists in the **original baseline code** (before any of our changes), which is consistent with Samsung never having worked.

#### 2. Electrical Output Voltage Swing

**A2DVI**: RP2040 GPIO pins at 3.3V with external resistor networks to set the TMDS differential swing. PicoDVI implementations typically target the DVI-spec-compliant 400-600 mV differential range. Drive strength is set to 2 mA with slew rate limiting.

**A2FPGA**: Gowin LVCMOS33D differential output (`ELVDS_TBUF`) with `DRIVE=8`. The Gowin LVCMOS33D typical differential swing is approximately 300-400 mV. The HDMI/DVI specification requires a minimum of 400 mV. If the Gowin output is at the low end of its range, it may fall below the minimum that Samsung's TMDS receiver requires, while the more tolerant Ingnok receiver accepts it.

This is a hardware/configuration difference that has been present since the original design. The Tang Nano 20K board does not include external TMDS level-shifting circuitry.

### Other Differences (Unlikely Root Causes)

#### 3. TMDS DC Balance Approach

**A2DVI**: Uses precomputed lookup tables with "perfectly balanced" TMDS symbol pairs (net DC offset of 0 per pair). DC balance never drifts during active video.

**A2FPGA**: Uses standard runtime TMDS 8b/10b encoding with a running DC balance accumulator (`acc`) that resets to 0 at every mode transition (video to control and back). This is the standard approach per the DVI/TMDS spec.

Both approaches are spec-compliant. Unlikely to cause receiver rejection.

#### 4. Blanking Period Content

**A2DVI**: Pure DVI. During horizontal blanking, only TMDS control characters are sent. No preambles, guard bands, or data islands. Channels 1 and 2 always send `{C1,C0}={0,0}` during blanking.

**A2FPGA (HDMI mode)**: During horizontal blanking, sends a sequence of: control period (4 px) -> data island preamble (8 px) -> DI leading guard (2 px) -> DI data packets (up to 96 px) -> DI trailing guard (2 px) -> control period (16 px) -> video preamble (8 px) -> video guard (2 px). Channels carry TERC4-encoded data during data islands.

**A2FPGA (DVI mode)**: Identical to A2DVI -- only control characters during blanking. But DVI mode also fails on Samsung, so this difference is not the cause.

#### 5. TMDS Serialization Method

**A2DVI**: PIO state machines on RP2040 serialize 10-bit TMDS symbols at the system clock rate (270 MHz). Two symbols are packed per 32-bit word. A 2-instruction PIO program uses `out pc, 1` with side-set for differential output.

**A2FPGA**: Gowin OSER10 hardware serializer converts 10-bit parallel data to serial at FCLK (135 MHz DDR = 270 Mbps effective). This is dedicated serialization hardware.

Both produce the same serial bitstream. Not a functional difference.

#### 6. TMDS Clock Waveform

**A2DVI**: PWM-generated 50% duty cycle clock at pixel rate. The code comments: "The DVI spec allows for phase offset between clock and data links."

**A2FPGA**: Currently OSER10-generated with pattern `0000011111` (50% duty cycle at pixel rate, phase-aligned to data). Previously was raw PLL1 pixel clock (not phase-aligned). Both were tested; neither worked on Samsung.

Not a functional difference for receiver acceptance.

### Changes Made to A2FPGA from Upstream Fork

All changes are relative to commit `35240a4` (upstream `edanuff/a2fpga_core`). Parameters `invert` (VIC 2/3) and `DVI_OUTPUT` are unchanged from the original values.

**Commit 3e1c981** -- Fix HDMI data island packet issues (PR #7):
1. Null packet header/body: `8'dX` -> `8'd0` (deterministic BCH ECC)
2. ACR packet header: removed `ifdef MODEL_TECH`, always `{8'd0, 8'd0, 8'd1}`
3. `packet_type` reset: `8'dx` -> `8'd0` (deterministic mux output)
4. AVI InfoFrame: added `.PICTURE_ASPECT_RATIO(VIDEO_ID_CODE == 3 ? 2'b10 : 2'b01)` (required by CTA-861)

**Commit 0825bd5** -- Port upstream hdl-util/hdmi PR #44:
5. VSync conditions: added `-1` to both start and end cy comparisons
6. Video guard/preamble: `cy < screen_height` -> `cy < screen_height - 1` (exclude last active line)
7. Data island timing: shifted +4 px (preamble starts at `screen_width + 4`, data at `screen_width + 14`)
8. Max packets formula: updated to account for two 4px minimum control periods
9. Blocking assignment fix: `control_data = 6'd0` -> `control_data <= 6'd0`

**Commit f09f504** -- AVI InfoFrame Samsung compatibility:
10. Added `.ACTIVE_FORMAT_INFO_PRESENT(1'b1)`
11. Added `.SCAN_INFO(2'b10)` (underscan)
12. Added `.RGB_QUANTIZATION_RANGE(2'b10)` (full-range RGB)

**Commit e4ff5d4** -- TMDS clock serialization:
13. Replaced `assign tmds_clock = clk_pixel` with 4th OSER10 (pattern `0000011111`)
14. In `top.sv`: ELVDS_TBUF input changed from `clk_pixel_w` to `tmdsClk`

Changes 5-9 fixed HDMI mode on the Ingnok monitor. None of the changes fixed Samsung.

### Recommended Next Steps

Two untested hypotheses remain. Both can be implemented as small changes:

1. **Increase DRIVE strength**: Change `DRIVE=8` to `DRIVE=16` for all TMDS pins in `boards/a2n20v2/hdl/a2n20v2.cst`. This increases the differential voltage swing from the Gowin FPGA, potentially bringing it above the 400 mV DVI/HDMI minimum.

2. **Line-aligned VSync**: Simplify VSync generation to transition at line boundaries (like A2DVI) instead of at the HSync position. Remove the special-case `if/else if` for VSync start/end lines and use only the line-based comparison.

Both changes address differences that have existed since the original codebase and are consistent with Samsung never having worked.
