# A2FPGA Multicard Core — Videx & ThunderClock Edition

This is a fork of the [A2FPGA Multicard Core](https://github.com/a2fpga/a2fpga_core) that adds
**Videx VideoTerm 80-column card emulation** and **ThunderClock Plus clock card emulation**,
along with bus timing bug fixes and HDMI compatibility improvements. See the
[upstream repository](https://github.com/a2fpga/a2fpga_core) for full documentation on the
A2FPGA hardware, board variants, and base card emulation (Mockingboard, SuperSprite, Super
Serial Card).

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
- **80-column rendering pipeline** — character ROM lookup, cursor blink, inverse video,
  line doubling, and color palette support (Apple II and IIgs palettes) rendered at
  640x432 within the 720x480 VGA frame
- **40/80-column switching** — controlled by AN0 ($C058/$C059), matching real Videx
  hardware; Ctrl-Reset restores 40-column mode

The Videx card is emulated in **slot 3** (required by the Apple II's SLOTC3ROM/INTC8ROM
hardware architecture). The A2FPGA card can be physically installed in any slot — all
emulated cards operate independently of the physical slot position.

**Tested with:**
- Apple Pascal 1.3 — boots to 80-column mode, full console I/O working
- Original Videx VideoTerm Demo application
- Custom VIDEX_DIAG test suite (passes all register, ROM, and VRAM tests)
- Concurrent operation with SSC, Mockingboard, SuperSprite, and ThunderClock emulation

See [VIDEX_IMPLEMENTATION_SPEC.md](VIDEX_IMPLEMENTATION_SPEC.md) for complete technical
documentation including MC6845 register map, bus protocol details, rendering pipeline
architecture, and annotated firmware disassembly.

### ThunderClock Plus Clock Card Emulation

The [ThunderClock Plus](https://en.wikipedia.org/wiki/Thunderware) by Thunderware was the
de facto standard clock card for the Apple II family. It is the only clock card with a
built-in ProDOS clock driver — ProDOS automatically detects and uses it without any
additional software installation, providing date and time stamps for all file operations.

The ThunderClock Plus uses a NEC uPD1990AC serial I/O calendar clock chip to maintain
the current date and time, communicating with the Apple II through a 6-bit control
register and 1-bit serial data output at a single device-select address.

This fork provides a complete ThunderClock Plus emulation including:

- **NEC uPD1990AC clock chip** — full emulation of the serial calendar clock with 40-bit
  BCD time register (seconds, minutes, hours, day-of-month, day-of-week, month), all 7
  command modes (register hold, shift, time set, time read, and 4 timer pulse rates),
  edge-triggered serial shift clock and strobe, and 1 Hz timekeeping derived from the
  FPGA's 54 MHz logic clock
- **2 KB firmware ROM** — the original ThunderClock Plus firmware with built-in ProDOS
  clock driver, serving slot ROM ($C1xx) and expansion ROM ($C800-$CFFF). Contains the
  ProDOS auto-detection signature bytes ($08, $28, $58, $70 at offsets 0, 2, 4, 6) that
  enable automatic clock discovery during ProDOS boot
- **Device-select register** — single I/O address ($C090 for slot 1) providing write
  access to the uPD1990AC control signals (data-in, shift clock, strobe, and 3-bit
  command code) and read access to serial data output and IRQ status
- **IRQ support** — active-low interrupt output driven by the uPD1990AC timer pulse,
  supporting interrupt-driven time-of-day updates at selectable rates (64, 256, 2048,
  or 4096 Hz)
- **Time persistence across resets** — the emulated uPD1990AC uses the FPGA's
  device-only reset (power-on reset) rather than the Apple II system reset, so the
  clock retains its time across Apple II soft resets (e.g., PR#6, Ctrl-Reset) just like
  the real battery-backed chip. If the FPGA remains powered (e.g., via USB-C from an
  always-on Raspberry Pi), the clock also survives Apple II power cycles
- **C8-space ownership** — phi0-qualified expansion ROM ownership with dynamic slot
  detection (learns its slot number at runtime from slotmaker) and self-clearing on
  $CFFF access or other-slot ROM access

**How time works:** The emulated ThunderClock functions like a "ThunderClock Plus with
no batteries." On FPGA power-up, the clock initializes to midnight, January 1 (Sunday).
Use the ThunderClock utilities (e.g., Thunderware's `TIME` program) or any compatible
clock-setting software to set the current date and time. The clock then keeps time
accurately using the FPGA's crystal oscillator.

**USB-C power persistence:** The A2FPGA's Tang Nano 20K has a USB-C connector that can
receive power independently from the Apple II's slot power. If you connect a USB-C cable
from an always-on device — such as a Raspberry Pi, USB power adapter, or USB power bank
— to the A2FPGA's USB-C connector, the FPGA remains powered even when the Apple II is
turned off. This keeps the emulated ThunderClock's internal time counter running
continuously, providing battery-like time persistence across Apple II power-off/power-on
cycles without any batteries. You only need to set the time once after connecting
USB-C power; subsequent Apple II reboots and power cycles will retain the correct time.
Disconnecting the USB-C cable while the Apple II is also powered off will cause the
emulated clock to lose its time setting.

**ProDOS integration:** ProDOS scans slots 7 through 1 during boot, looking for the
ThunderClock signature bytes. When found, ProDOS installs the firmware's built-in clock
driver, which is called automatically for every file create, write, and directory
operation. No additional clock driver software or configuration is needed — just boot
ProDOS and file timestamps work.

**Tested with:**
- ProDOS 2.4.3 — automatic clock detection and file timestamping
- Thunderware ThunderClock utility disk — `TIME` program for setting date/time,
  `CLOCK` program for continuous time display
- Concurrent operation with Videx, SSC, Mockingboard, and SuperSprite emulation

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

To flash this fork's bitstream (with Videx and ThunderClock emulation enabled) to an
A2N20v2 card:

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
| 1 | **ThunderClock Plus** | ProDOS auto-detect clock card (any slot works) |
| 2 | Super Serial Card | USB serial for ADTPro (conventional slot for serial/modem) |
| 3 | **Videx VideoTerm** | 80-column display (hardware requirement — must be slot 3) |
| 4 | Mockingboard | Stereo AY-3-8910 sound (conventional slot — most software assumes slot 4) |
| 7 | SuperSprite | TMS9918a sprite graphics (conventional slot 7 default) |

Videx must remain in slot 3 (Apple II hardware requirement). The ThunderClock can be
assigned to any slot — ProDOS scans all slots 7 through 1 during boot. SSC, Mockingboard,
and SuperSprite use their conventional slot assignments (2, 4, and 7 respectively) which
most software expects. All assignments can be reassigned if needed. Slot assignments are
configured in [hdl/slots/slots.hex](hdl/slots/slots.hex).

The physical A2FPGA card can be installed in any slot. With Videx emulation enabled,
**slot 3 is recommended** — since the Videx emulation claims slot 3's address space, no
other physical card can use that slot, so you may as well use it for the A2FPGA itself.
(The upstream project recommends slot 7 for builds without Videx.) Ensure the emulated
slot numbers do not conflict with physical cards in your system.

### Resource Utilization (A2N20v2, GW2AR-18C)

With all five emulated cards enabled (Videx, ThunderClock, SSC, Mockingboard, SuperSprite):

| Resource | Used | Available | Utilization |
|----------|-----:|----------:|:-----------:|
| BSRAM    |   45 |        46 | 98% |
| LUT      | 6753 |    20736  | 33% |
| Register | 4433 |    15552  | 29% |

The ThunderClock adds 1 BSRAM block (2 KB pROM for firmware ROM), ~250 LUTs, and ~160
registers — the smallest resource cost of any emulated card.

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

### ThunderClock Plus Emulation

ThunderClock Plus clock card emulation by [Brent Rector](https://github.com/BrentRector).
NEC uPD1990AC clock chip behavior referenced from the uPD1990AC datasheet, MAME's
`thunderclock.cpp` / `upd1990a.cpp` implementations, and izapple2's `microPD1990ac.go`.

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

New Videx and ThunderClock emulation code (`hdl/videx/`, `hdl/thunderclock/`,
`tools/gen_videx_rom.py`) is released under the
[MIT License](LICENSE) (Copyright 2026 Brent Rector).

Upstream A2FPGA code retains its original per-file licenses (ISC, MIT, BSD-3, GPL v2+ — see
individual file headers). All open source code reused in this project is believed to be used
consistently with the licenses under which it is provided.

## Upstream

This is a fork of [a2fpga/a2fpga_core](https://github.com/a2fpga/a2fpga_core). Bug fixes
and HDMI improvements from this fork have been submitted as pull requests to the upstream
repository.
