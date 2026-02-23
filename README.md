# A2FPGA Multicard Core — Videx VideoTerm Edition

This is a fork of the [A2FPGA Multicard Core](https://github.com/a2fpga/a2fpga_core) that adds
**Videx VideoTerm 80-column card emulation** along with bus timing bug fixes and HDMI
compatibility improvements. See the [upstream repository](https://github.com/a2fpga/a2fpga_core)
for full documentation on the A2FPGA hardware, board variants, and base card emulation
(Mockingboard, SuperSprite, Super Serial Card).

## What This Fork Adds

### Videx VideoTerm 80-Column Card Emulation

The [Videx VideoTerm](https://en.wikipedia.org/wiki/Videx) was the most popular 80-column
display card for the Apple II and II+ before Apple introduced built-in 80-column support
with the Apple //e. The VideoTerm used a Motorola MC6845 CRT controller with 2 KB of
dedicated video RAM to provide an 80-column by 24-line text display, and was widely
supported by business and productivity software including Apple Pascal, WordStar, and
VisiCalc.

This fork provides a complete VideoTerm emulation including:

- **Firmware ROM** — the original Videx VideoTerm firmware, serving slot ROM ($C300-$C3FF)
  and expansion ROM ($C800-$CFFF)
- **MC6845 CRTC** — register-accurate emulation with full read-back (HD6845SP Type 1
  behavior)
- **2 KB Video RAM** — accessible via the CRTC data register, implemented using a single
  GoWin SDPB block with asymmetric port widths
- **Character ROM** — captured from a physical Videx VideoTerm adapter, with character
  ROM halving (chars $80-$FF are the inverse of $00-$7F) to save BSRAM

The Videx card is emulated in **slot 3** (required by the Apple II's SLOTC3ROM/INTC8ROM
hardware architecture). The A2FPGA card can be physically installed in any slot — all
emulated cards operate independently of the physical slot position.

**Tested with:**
- Apple Pascal 1.3 — boots to 80-column mode, full console I/O working
- Original Videx VideoTerm Demo application
- Custom VIDEX_DIAG test suite (passes all register, ROM, and VRAM tests)
- Concurrent operation with SSC, Mockingboard, and SuperSprite emulation

See [VIDEX_IMPLEMENTATION_SPEC.md](VIDEX_IMPLEMENTATION_SPEC.md) for complete technical
documentation including MC6845 register map, bus protocol details, rendering pipeline
architecture, and annotated firmware disassembly.

### Bug Fixes (Submitted Upstream)

During Videx development, three latent bugs were discovered in the upstream codebase.
These bugs exist regardless of Videx but were not previously triggered because the SSC
was the only emulated card with C8 expansion ROM. Adding any second C8-capable card
(emulated or physical) exposes all three:

- **INTC8ROM permanently blocking expansion ROM on Apple ][+** — IIe-only INTC8ROM logic
  activates on ][+ because SLOTC3ROM defaults to 0, permanently blocking all cards' C8
  reads after the first slot 3 access.
  ([PR #36](https://github.com/a2fpga/a2fpga_core/pull/36))

- **SSC expansion ROM bus timing and ownership bugs** — Missing phi0 qualification allows
  PCB bus transceiver glitches to clear SSC's C8 ownership mid-execution; missing SLOTROM
  guard causes SSC to respond to other slots' C8 reads.
  ([PR #36](https://github.com/a2fpga/a2fpga_core/pull/36))

- **CPLD bus OE held ~100ns into phi1** — CDC denoise pipeline delay causes the CPLD bus
  driver to remain active ~100ns past the real phi0 falling edge, creating bus contention
  during I/O write cycles from expansion ROM.
  ([PR #37](https://github.com/a2fpga/a2fpga_core/pull/37))

### HDMI Compatibility Improvements

- **Samsung TV and strict monitor support** — Fixes missing AVI InfoFrame fields and
  non-deterministic packet content that caused some HDMI sinks to reject the signal entirely.
  ([PR #38](https://github.com/a2fpga/a2fpga_core/pull/38))

- **HDMI control period timing** — Port of upstream hdl-util/hdmi PR #44 fixing control
  period and timing bugs.
  ([PR #35](https://github.com/a2fpga/a2fpga_core/pull/35))

## Getting Started

See the [upstream A2FPGA repository](https://github.com/a2fpga/a2fpga_core) for general
information about A2FPGA hardware, board variants, purchasing from
[ReActiveMicro](https://www.reactivemicro.com/product/a2fpga-multicard/), and DIP switch
settings.

### Updating the Bitstream

To flash this fork's bitstream (with Videx emulation enabled) to an A2N20v2 card:

**Mac/Linux (OpenFPGALoader):**

```
brew install openfpgaloader  # macOS with Homebrew
openfpgaloader -b tangnano20k -f a2n20v2.fs
```

**Windows (GoWin Programmer):**

Download the [GoWin V1.9.8.11 Education Edition IDE](https://dl.sipeed.com/shareURL/TANG/gowin_ide),
launch the Programmer, and flash the `a2n20v2.fs` bitstream file to the GW2AR-18C device
in External Flash Mode (Generic Flash, address 0x000000).

The bitstream file is located at
[boards/a2n20v2/impl/pnr/a2n20v2.fs](boards/a2n20v2/impl/pnr/a2n20v2.fs).

### Slot Configuration

This build emulates the following cards, all from a single physical A2FPGA card:

| Emulated Slot | Card | Notes |
|:---:|--------|-------|
| 2 | Super Serial Card | USB serial for ADTPro (conventional slot for serial/modem) |
| 3 | **Videx VideoTerm** | 80-column display (hardware requirement — must be slot 3) |
| 4 | Mockingboard | Stereo AY-3-8910 sound (conventional slot — most software assumes slot 4) |
| 7 | SuperSprite | TMS9918a sprite graphics (conventional slot 7 default) |

Videx must remain in slot 3 (Apple II hardware requirement). SSC, Mockingboard, and
SuperSprite use their conventional slot assignments (2, 4, and 7 respectively) which most
software expects. These can be reassigned if needed. Slot assignments are configured in
[hdl/slots/slots.hex](hdl/slots/slots.hex).

The physical A2FPGA card can be installed in any slot. With Videx emulation enabled,
**slot 3 is recommended** — since the Videx emulation claims slot 3's address space, no
other physical card can use that slot, so you may as well use it for the A2FPGA itself.
(The upstream project recommends slot 7 for builds without Videx.) Ensure the emulated
slot numbers do not conflict with physical cards in your system.

## Building from Source

1. Install the [GoWin V1.9.8.11 Education Edition IDE](https://dl.sipeed.com/shareURL/TANG/gowin_ide)
   (later versions may not function correctly)
2. Open `boards/a2n20v2/a2n20v2.gprj`
3. Run Synthesize, then Place & Route
4. Flash the resulting `a2n20v2.fs` bitstream

**Note:** GoWin IDE caches project files aggressively. After switching git branches or
pulling changes, close and reopen the project (or perform a clean build) to ensure changed
sources are picked up.

## Credits

### Upstream A2FPGA Project

The A2FPGA core was principally coded by [Ed Anuff](https://github.com/edanuff). Research,
design, documentation, and extensive testing provided by
[Joshua Norrid](https://github.com/jnorrid). Advice and testing by
[JB Langston](https://github.com/jblang) and
[Hans Hübner](https://github.com/hanshuebner), as well as Henry Courbis from
[ReactiveMicro.com](https://www.reactivemicro.com/).

### Videx VideoTerm Emulation

Videx VideoTerm 80-column card emulation by [Brent Rector](https://github.com/BrentRector).
Character ROM data captured from a physical Videx VideoTerm adapter.

### Open Source Cores

The A2FPGA Multicard Core draws from a number of open source FPGA cores:

- Matthew Hagerty's [F18a TMS9918a](https://github.com/dnotq/f18a) core and
  [Felipe Antoniosi's port to the Tang Nano 9K](https://github.com/lfantoniosi/tn_vdp)
- [MiSTer FPGA Apple IIe core](https://github.com/MiSTer-devel/Apple-II_MiSTer), leveraging
  [Stephen A. Edwards' original Apple II core](http://www.cs.columbia.edu/~sedwards/apple2fpga/),
  [Szombathelyi György's revised Apple //e core](https://github.com/gyurco/apple2efpga), and
  [Alan Steremberg's Verilog port](https://github.com/alanswx/Apple-II-Verilog_MiSTer)
- [Sameer Puri's HDMI core](https://github.com/hdl-util/hdmi)
- [MikeJ & Sorgelig's YM2149 core](https://github.com/MiSTer-devel/Apple-II_MiSTer/blob/master/rtl/mockingboard/YM2149.sv)
- [Gideon Zweijtzer's 6522 core](https://github.com/mist-devel/plus_too/blob/master/via6522.vhd)
- [Gary Becker's 6551 core](https://github.com/MiSTer-devel/CoCo3_MiSTer/blob/master/rtl/UART_6551/uart_6551.v)
- [Claire Xenia Wolf's PicoRV32 and PicoSoC](https://github.com/YosysHQ/picorv32) and
  [Lawrie Griffiths' BRAM example](https://github.com/lawrie/pico_ram_soc)
- [Adam Gastineau's SDRAM controller core](https://github.com/agg23/sdram-controller)

None of this possible without Jim Sather's *Understanding the Apple IIe* and Winston D.
Gayler's *The Apple II Circuit Description*.

All of this is an homage to Steve Wozniak for creating the Apple II as well as to the great
chip designers of the 8-bit era, such as Karl Guttag who designed the TI9918a video processor
at Texas Instruments which was used by the SuperSprite card, the emulation of which was the
original impetus for the A2FPGA project.

## License

New Videx emulation code (`hdl/videx/`, `tools/gen_videx_rom.py`) is released under the
[MIT License](LICENSE) (Copyright 2026 Brent Rector).

Upstream A2FPGA code retains its original per-file licenses (ISC, MIT, BSD-3, GPL v2+ — see
individual file headers). All open source code reused in this project is believed to be used
consistently with the licenses under which it is provided.

## Upstream

This is a fork of [a2fpga/a2fpga_core](https://github.com/a2fpga/a2fpga_core). Bug fixes
and HDMI improvements from this fork have been submitted as pull requests to the upstream
repository.
