# ThunderClock Plus Implementation Specification

## A2FPGA Emulation of the Thunderware ThunderClock Plus

**Status**: Implementation Complete
**Target Board**: A2N20v2 (Tang Nano 20K + GW2AR-18C)
**Slot Assignment**: Slot 1 (configurable via `hdl/slots/slots.hex`)

---

## 1. Overview

The ThunderClock Plus is the **de facto standard** real-time clock card for the Apple II,
originally manufactured by Thunderware Inc. (1980). It is the **only clock card with a
built-in ProDOS driver** — ProDOS scans slots 7-1 for its four signature bytes and
auto-activates the clock. All other Apple II clock cards (No-Slot Clock, TimeMaster H.O.,
DClock, etc.) either emulate the ThunderClock protocol or require a separate driver.

The A2FPGA emulation provides automatic ProDOS file timestamping and software-accessible
date/time without any additional software installation.

### 1.1 Implementation Files

| File | Purpose |
|------|---------|
| `hdl/thunderclock/thunderclock_card.sv` | Card bus interface (slot ROM, expansion ROM, device select, IRQ) |
| `hdl/thunderclock/upd1990.sv` | NEC uPD1990AC serial clock chip emulation |
| `hdl/thunderclock/thunderclock_rom.hex` | 2 KB firmware ROM (`$readmemh` format) |

### 1.2 Resource Cost

| Resource | Cost | Notes |
|----------|------|-------|
| **BSRAM** | 1 pROM | 2 KB firmware ROM |
| **LUT** | ~250 | BCD increment logic, address decode, serial state machine |
| **Registers** | ~160 | 40-bit shift register, 40-bit BCD counter, 26-bit prescaler, state regs |

The ThunderClock is the lowest-cost card in the A2FPGA. For comparison, the full build
with all five emulated cards uses 45/46 BSRAM (98%), 6753/20736 LUT (33%), 4433/15552
registers (29%).

---

## 2. Physical Hardware Reference

### 2.1 Original Card Components

| Component | Function |
|-----------|----------|
| **NEC uPD1990AC** | Serial I/O calendar clock LSI (14-pin DIP), 32.768 kHz crystal |
| **2716 EPROM** | 2 KB firmware ROM (slot ROM + expansion ROM) |
| **74LS174** | Hex D flip-flop — output latch for control register bits |
| **74LS74** | Dual D flip-flop — interrupt edge detection |
| **74LS109** | Dual J-K flip-flop — interrupt enable/disable |
| **74LS08** | Quad AND gate — IRQ generation logic |
| **74LS27** | Triple 3-input NOR gate — address decode |
| **74LS126** | Quad tri-state buffer — bus output drivers |
| **74LS132** | Quad NAND Schmitt trigger — signal conditioning |
| **CD4050** | Hex CMOS buffer — TTL→CMOS level shift for uPD1990 |
| **B1, B2** | Battery holders (backup power) |

### 2.2 What the FPGA Emulates

Only two logical components need emulation:

1. **uPD1990AC clock chip** — 40-bit serial shift register, BCD time counter, command decoder
2. **Bus interface** — 1 device-select register, slot ROM, expansion ROM, IRQ

Everything else (level shifters, buffers, address decode logic) is subsumed by the FPGA.

---

## 3. Bus Interface Specification

### 3.1 Address Map

| Range | Size | Function |
|-------|------|----------|
| `$C0n0` | 1 byte | Device-select register (read/write) |
| `$C0n1-$C0nF` | 15 bytes | Mirror of `$C0n0` on read; ignored on write |
| `$Cn00-$CnFF` | 256 bytes | Slot ROM (first 256 bytes of 2 KB EPROM) |
| `$C800-$CFFF` | 2 KB | Expansion ROM (full 2 KB EPROM) |

Where `n` = 8 + slot number (e.g., slot 1 → `$C090`, `$C100`).

### 3.2 Device-Select Register (`$C0n0`)

**Write** — Control signals to uPD1990AC:

| Bit | Signal | Direction | Function |
|-----|--------|-----------|----------|
| 0 | DATA IN | FPGA→uPD1990 | Serial data input |
| 1 | CLK | FPGA→uPD1990 | Shift clock (rising edge shifts data) |
| 2 | STB | FPGA→uPD1990 | Strobe (rising edge latches command) |
| 3 | C0 | FPGA→uPD1990 | Command bit 0 |
| 4 | C1 | FPGA→uPD1990 | Command bit 1 |
| 5 | C2 | FPGA→uPD1990 | Command bit 2 |
| 6 | — | — | Unused |
| 7 | — | — | Unused |

**Read** — Status from uPD1990AC:

| Bit | Signal | Function |
|-----|--------|----------|
| 0-4 | — | Read as 0 |
| 5 | IRQ | Interrupt status (1 = ThunderClock caused IRQ). Read clears IRQ. |
| 6 | — | Read as 0 |
| 7 | DATA OUT | Serial data output from uPD1990AC shift register LSB |

### 3.3 ProDOS Identification Bytes

These bytes in the slot ROM trigger ProDOS auto-detection:

| Offset | Address | Value | 6502 Opcode |
|--------|---------|-------|-------------|
| `$00` | `$Cn00` | `$08` | PHP |
| `$02` | `$Cn02` | `$28` | PLP |
| `$04` | `$Cn04` | `$58` | CLI |
| `$06` | `$Cn06` | `$70` | BVS |

These bytes serve double duty as both the ProDOS signature and valid executable code
(the firmware entry point). ProDOS scans slots 7 down to 1, checking these four bytes.

### 3.4 Firmware Entry Points

| Offset | Address | Function | Convention |
|--------|---------|----------|------------|
| `$08` | `$Cn08` | READ | X = `$Cn` (slot page). Returns time in current mode. |
| `$0B` | `$Cn0B` | WRITE | A = mode byte (e.g., `$A3` for integer mode). |

### 3.5 ROM Details

| Property | Value |
|----------|-------|
| **File** | `hdl/thunderclock/thunderclock_rom.hex` |
| **Size** | 2048 bytes (2716 EPROM) |
| **Format** | `$readmemh` — one hex byte per line, 2048 lines |
| **CRC-32** | `1b99c4e3` |
| **SHA-1** | `60f434f5325899d7ea257a6e56e6f53eae65146a` |
| **Source** | MAME ROM set (pending replacement with physical ROM dump) |
| **Mapping** | Bytes 0x000-0x0FF → `$Cn00-$CnFF` (slot ROM) |
| | Bytes 0x000-0x7FF → `$C800-$CFFF` (expansion ROM) |

---

## 4. uPD1990AC Emulation

### 4.1 Command Codes

Commands are latched on the rising edge of STB from the 3-bit C2:C1:C0 field:

| C2 | C1 | C0 | Value | Command | Function |
|----|----|----|-------|---------|----------|
| 0 | 0 | 0 | 0 | REGISTER HOLD | Normal timekeeping; DATA OUT = 1 Hz pulse |
| 0 | 0 | 1 | 1 | SHIFT | Shift register rotates right on CLK rising edge |
| 0 | 1 | 0 | 2 | TIME SET | Load shift register → time counter |
| 0 | 1 | 1 | 3 | TIME READ | Copy time counter → shift register |
| 1 | 0 | 0 | 4 | TP 64 Hz | Timer pulse output at 64 Hz |
| 1 | 0 | 1 | 5 | TP 256 Hz | Timer pulse output at 256 Hz |
| 1 | 1 | 0 | 6 | TP 2048 Hz | Timer pulse output at 2048 Hz |
| 1 | 1 | 1 | 7 | TP 4096 Hz | Timer pulse output at 4096 Hz |

All commands are implemented.

### 4.2 40-Bit Shift Register Format (BCD)

Data is shifted out LSB first. The register contains 10 BCD nibbles:

| Bits | Byte | Field | Format | Range |
|------|------|-------|--------|-------|
| 0-3 | 0 low | Seconds ones | BCD | 0-9 |
| 4-7 | 0 high | Seconds tens | BCD | 0-5 |
| 8-11 | 1 low | Minutes ones | BCD | 0-9 |
| 12-15 | 1 high | Minutes tens | BCD | 0-5 |
| 16-19 | 2 low | Hours ones | BCD | 0-9 |
| 20-23 | 2 high | Hours tens | BCD | 0-2 |
| 24-27 | 3 low | Day ones | BCD | 0-9 |
| 28-31 | 3 high | Day tens | BCD | 0-3 |
| 32-35 | 4 low | Day of week | BCD | 0-6 (Sun=0) |
| 36-39 | 4 high | Month | Binary | 1-12 |

**Total**: 40 bits = 5 bytes. Month is binary (not BCD). No year register.

### 4.3 Serial Protocol — Read Time Sequence

The firmware performs this sequence to read the current time:

```
1. Set TIME_READ command:
   Write $C0n0 = $18  (C2:C1:C0 = 011, STB=0, CLK=0, DI=0)
   Write $C0n0 = $1C  (STB=1 → rising edge latches TIME_READ)
   Write $C0n0 = $18  (STB=0 → complete strobe pulse)
   — Time counter is now copied into shift register —

2. Set SHIFT command:
   Write $C0n0 = $08  (C2:C1:C0 = 001)
   Write $C0n0 = $0C  (STB=1 → rising edge latches SHIFT)
   Write $C0n0 = $08  (STB=0)

3. Clock out 40 bits (LSB first):
   For each bit:
     Read  $C0n0 → bit 7 = DATA OUT (current shift register LSB)
     Write $C0n0 = $0A  (CLK=1 → rising edge shifts register right)
     Write $C0n0 = $08  (CLK=0)

4. Return to REGISTER HOLD:
   Write $C0n0 = $00  (C2:C1:C0 = 000)
   Write $C0n0 = $04  (STB=1)
   Write $C0n0 = $00  (STB=0)
```

### 4.4 Serial Protocol — Set Time Sequence

```
1. Set SHIFT command (same as read step 2)
2. Clock in 40 bits (LSB first):
   For each bit:
     Write $C0n0 = $08 | (bit_value & 1)  (set DATA IN)
     Write $C0n0 = $0A | (bit_value & 1)  (CLK=1 → shift in)
     Write $C0n0 = $08 | (bit_value & 1)  (CLK=0)
3. Set TIME_SET command:
   Write $C0n0 = $10  (C2:C1:C0 = 010)
   Write $C0n0 = $14  (STB=1 → loads shift register into time counter)
   Write $C0n0 = $10  (STB=0)
4. Return to REGISTER HOLD
```

### 4.5 Timer Pulse (TP) and IRQ

The uPD1990AC's TP output produces a square wave at the rate selected by commands 4-7.
On the physical card, TP feeds through a 74LS74 flip-flop and 74LS08 AND gate to
generate the Apple II IRQ signal.

| Command | TP Frequency | Half-period (FPGA cycles at 54 MHz) |
|---------|-------------|-------------------------------------|
| 4 | 64 Hz | 421,875 |
| 5 | 256 Hz | 105,469 |
| 6 | 2048 Hz | 13,184 |
| 7 | 4096 Hz | 6,592 |

In the emulation, IRQ is set on the TP rising edge and cleared when the CPU reads the
device-select register (bit 5). The `irq_n_o` output is active-low and AND'd into the
bus IRQ chain with Mockingboard, SuperSprite VDP, and SSC IRQs.

---

## 5. Implementation Architecture

### 5.1 Module Hierarchy

```
thunderclock_card (thunderclock_card.sv)
├── Card enable logic (standard A2FPGA pattern)
├── C8-space ownership (phi0-qualified, self-clearing)
├── Firmware ROM (2 KB pROM)
├── Device-select register (6-bit write, read mux)
├── IRQ logic (TP edge detect, read-to-clear)
└── upd1990 (upd1990.sv)
    ├── 1 Hz prescaler (54 MHz → 1 Hz)
    ├── Timer pulse prescaler (variable rate)
    ├── 40-bit serial shift register
    ├── 40-bit BCD time counter with calendar rollover
    └── Command decoder (STB/CLK edge detection)
```

### 5.2 C8-Space Ownership

The ThunderClock uses dynamic slot detection — it learns its own slot number from
slotmaker at runtime via `my_slot`/`my_slot_known`, rather than hardcoding the slot
number as the SSC and Videx cards do. This means the ThunderClock can be assigned to
any slot without code changes.

C8-space ownership follows the same phi0-qualified pattern proven during Videx
development:

- **Claimed** when the slot ROM is accessed (`card_io_sel`)
- **Released** when `$CFFF` is accessed or another slot's `$Csxx` is accessed
- **phi0 gating** prevents address bus transients during phi1 from spuriously
  clearing ownership (the root cause of non-deterministic boot failures fixed in
  the Videx and SSC cards)

### 5.3 Reset Domain Separation

The emulation uses two distinct reset domains:

| Reset Signal | Scope | Used By |
|-------------|-------|---------|
| `device_reset_n` | FPGA power-on only (PLL lock) | uPD1990AC (time counter, shift register, prescaler) |
| `system_reset_n` | Apple II reset + FPGA power-on | Bus interface (card_enable, c8_owned, control_reg, IRQ) |

This separation is critical: the uPD1990AC time counter survives Apple II resets (PR#6,
Ctrl-Reset) and, if the FPGA remains powered via USB-C, also survives Apple II power
cycles. This matches the behavior of a real battery-backed uPD1990AC.

### 5.4 Time Persistence

The emulated ThunderClock functions like a "ThunderClock Plus with no batteries":

- On FPGA power-up, the clock initializes to **midnight, Sunday, January 1**
- The user sets the correct date/time using ThunderClock utilities (e.g., `TIME`)
- Time is kept accurately using the FPGA's crystal oscillator (±25 ppm, ~2 sec/day)
- **Time survives Apple II soft resets** (PR#6, Ctrl-Reset) — bus interface state
  resets but the BCD counter continues running
- **Time survives Apple II power cycles** if the FPGA remains powered via USB-C
  (see below)
- Time is only lost when the FPGA itself loses power (both Apple II and USB-C
  disconnected)

#### USB-C Power Persistence

The A2FPGA's Tang Nano 20K has a USB-C connector that can receive power independently
from the Apple II's slot power. If a USB-C cable is connected from an always-on device
— such as a Raspberry Pi, USB power adapter, or USB power bank — to the A2FPGA's
USB-C connector, the FPGA remains powered even when the Apple II is turned off. (The
FPGA's LED remains illuminated, confirming continuous operation.)

This keeps the emulated ThunderClock's internal BCD time counter running continuously,
providing battery-like time persistence across Apple II power-off/power-on cycles. The
user only needs to set the time once after connecting USB-C power; subsequent Apple II
reboots and power cycles will retain the correct time.

Disconnecting the USB-C cable while the Apple II is also powered off causes the FPGA
to lose power entirely, resetting the time counter to midnight January 1. Reconnecting
power and setting the time again restores normal operation.

**Technical detail**: The FPGA's `device_reset_n` signal (used by the uPD1990AC) is
derived from `rst_n & clk_logic_lock_w & clk_hdmi_lock_w`. This signal only goes low
when the FPGA loses power (PLLs lose lock) or when the S1 button is pressed on the
Tang Nano 20K board. It remains high through Apple II power cycles as long as USB-C
provides continuous 5V power to the FPGA. The Apple II's reset line only drives
`system_reset_n`, which resets the bus interface but not the clock chip.

### 5.5 BCD Counter

A free-running BCD counter driven by a 1 Hz tick derived from the 54 MHz system clock:

```
54,000,000 Hz ÷ 54,000,000 = 1 Hz tick
→ 26-bit prescaler counter
→ 40-bit BCD time counter (seconds, minutes, hours, day, dow, month)
```

BCD increment uses a `bcd_inc` function with carry chain:

| Field | Nibbles | Max BCD | Carry condition |
|-------|---------|---------|-----------------|
| Seconds | 2 | 59 | sec_ones == 9 && sec_tens == 5 |
| Minutes | 2 | 59 | min_ones == 9 && min_tens == 5 |
| Hours | 2 | 23 | hr_ones == 3 && hr_tens == 2 |
| Day | 2 | 28/30/31 | Month-dependent lookup |
| Day-of-week | 1 | 6 | dow == 6, wraps to 0 |
| Month | 1 | 12 | month == 12, wraps to 1 |

Days-per-month uses a case lookup matching the real uPD1990AC behavior: Feb=28 (no
leap year — the chip has no year register), Apr/Jun/Sep/Nov=30, all others=31.

### 5.6 Integration (top.sv)

The ThunderClock is instantiated in `boards/a2n20v2/hdl/top.sv`:

```systemverilog
thunderclock_card #(
    .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ),
    .ENABLE(THUNDERCLOCK_ENABLE),
    .ID(THUNDERCLOCK_ID)
) thunderclock (
    .a2bus_if(a2bus_if),
    .a2mem_if(a2mem_if),
    .slot_if(slot_if),
    .data_o(tc_d_w),
    .rd_en_o(tc_rd),
    .irq_n_o(tc_irq_n),
    .rom_en_o(tc_rom_en)
);
```

Bus arbiter priority chain (highest to lowest):

```
Videx > SSC > ThunderClock > SuperSprite > Mockingboard
```

IRQ chain (active-low AND):

```systemverilog
assign irq_n_w = mb_irq_n && vdp_irq_n && ssc_irq_n && tc_irq_n;
```

### 5.7 Slot Configuration

Current `hdl/slots/slots.hex`:

```
00 06 03 05 02 00 00 01
```

| Slot | Card ID | Card |
|------|---------|------|
| 0 | 0 | (config) |
| 1 | 6 | **ThunderClock Plus** |
| 2 | 3 | Super Serial Card |
| 3 | 5 | Videx VideoTerm |
| 4 | 2 | Mockingboard |
| 5 | 0 | Empty |
| 6 | 0 | Empty (physical Disk II) |
| 7 | 1 | SuperSprite |

The ThunderClock can be reassigned to any slot by editing `slots.hex`. ProDOS scans
slots 7→1 and uses the first clock card found, so slot assignment does not affect
ProDOS compatibility.

---

## 6. ProDOS Integration

### 6.1 Clock Detection

ProDOS scans slots 7 through 1 during boot, checking for the ThunderClock signature:

```
for slot = 7 downto 1:
    base = $C000 + (slot * $100)
    if PEEK(base+0) == $08
    && PEEK(base+2) == $28
    && PEEK(base+4) == $58
    && PEEK(base+6) == $70:
        install_clock_driver(slot)
        break
```

When found, ProDOS installs the firmware's built-in clock driver at `$BF06-$BF08`.

### 6.2 Clock Driver Interface

ProDOS stores the clock driver entry point at `$BF06-$BF08`:
- No clock: `$BF06` = `$60` (RTS)
- Clock present: `$BF06` = `$4C` (JMP), `$BF07-$BF08` = driver address

ProDOS calls `JSR $BF06` during CREATE, DESTROY, RENAME, SET_FILE_INFO, CLOSE, FLUSH,
and GET_TIME. The driver populates:
- `$BF90-$BF91` (DATE): `YYYYYYYMMMMDDDDD` (year bits 15-9, month bits 8-5, day bits 4-0)
- `$BF92-$BF93` (TIME): `000HHHHH00MMMMMM` (hour bits 12-8, minute bits 5-0)

For the ThunderClock, ProDOS loads A=`$A3` and calls `$Cn0B` (WRITE), then calls `$Cn08`
(READ). The firmware bit-bangs the uPD1990 and deposits an ASCII time string at `$0200`
(GETLN buffer), which ProDOS then parses.

### 6.3 Year Inference

The uPD1990AC has no year register. ProDOS infers the year from a lookup table indexed
by day-of-week + month. Coverage by ProDOS version:

| ProDOS Version | Year Coverage |
|----------------|--------------|
| 1.x-2.0.3 | 1980s-1990s |
| 2.4.2 | 2018-2023 |
| 2.4.3 | Through 2028 |

After 2028, a further ProDOS update will be needed. This is a limitation of the
ThunderClock protocol, not the emulation.

---

## 7. Comparison with Alternative Clock Cards

| Feature | ThunderClock Plus | No-Slot Clock (DS1215) |
|---------|------------------|------------------------|
| ProDOS built-in driver | **Yes** | No (requires NS.CLOCK.SYSTEM) |
| Slot required | Yes (1 slot) | No (sits under ROM chip) |
| Year register | No (inferred by ProDOS) | Yes (8-bit BCD) |
| Interface | Serial (uPD1990 bit-bang) | 64-bit magic unlock sequence |
| Battery backup | External batteries | CR2032 coin cell (built-in) |
| Software compatibility | Universal (de facto standard) | Good (driver required) |
| FPGA emulation complexity | Low (serial protocol) | Medium (magic pattern detection) |

The ThunderClock wins on ProDOS compatibility (zero-install). The No-Slot Clock wins on
year support but requires a boot-time driver.

---

## 8. Testing Results

### 8.1 Verified Working

| Test | Method | Result |
|------|--------|--------|
| ProDOS detection | Boot ProDOS 2.4.3 | Clock driver installed at `$BF06` (JMP, not RTS) |
| File timestamps | `CREATE /RAM/TEST`, `CATALOG` | Correct date/time shown |
| TIME_READ | Thunderware `CLOCK` program | Time reads and increments correctly |
| TIME_SET | Thunderware `TIME` program | Set time persists across reads |
| Soft reset persistence | Set time, PR#6, read time | Time continues running — not reset |
| USB-C power persistence | Set time, Apple II power off (USB-C on), power on | Time continues running |
| $CFFF C8 clear | Access $CFFF then $C800 | Expansion ROM no longer active |
| C8 ownership transfer | Access another slot's $Csxx | ThunderClock relinquishes C8 |
| Concurrent operation | Videx + SSC + Mockingboard + SuperSprite | All cards function simultaneously |

### 8.2 Software Compatibility

| Software | Status |
|----------|--------|
| ProDOS 2.4.3 | Working — auto-detect and file timestamping |
| Thunderware `TIME` utility | Working — date/time setting |
| Thunderware `CLOCK` utility | Working — continuous time display |
| Apple Pascal 1.3 | Working — concurrent with Videx 80-column |

---

## 9. Reference Implementations

### 9.1 MAME (`a2thunderclock.cpp` + `upd1990a.cpp`)

MAME provides a complete, well-tested emulation:

- **Card class** (`a2bus_thunderclock_device`): Handles `read_c0nx`, `write_c0nx`,
  `read_cnxx`, `read_c800`. Write only responds to offset 0. Read returns DATA OUT on
  bit 7 from all offsets.
- **uPD1990 class** (`upd1990a_device`): Full state machine with edge detection on
  CLK/STB, 40-bit shift register, BCD time counter with calendar rollover, timer pulse
  output.
- **IRQ**: Not implemented in MAME (the TP output is unconnected).
- **Time source**: Host system time via `device_rtc_interface`.

### 9.2 izapple2 (`cardThunderClockPlus.go` + `microPD1990ac.go`)

A minimal ~120-line Go implementation:

- **Simplifications**: TIME_SET ignored, commands 4-7 ignored, no TP output, no IRQ.
- **Time source**: Host `time.Now()` — zero drift, always accurate.

### 9.3 Key Differences from References

| Feature | A2FPGA | MAME | izapple2 |
|---------|--------|------|----------|
| TIME_SET | Implemented | Implemented | Ignored |
| Timer pulse | Implemented (4 rates) | State machine (unconnected) | Not implemented |
| IRQ | Implemented | Not implemented | Not implemented |
| Calendar rollover | Full (month-aware) | Full | N/A (reads host time) |
| Time source | FPGA crystal (±25 ppm) | Host RTC | Host `time.Now()` |
| Reset survival | Yes (`device_reset_n`) | N/A | N/A |

The A2FPGA implementation is the most complete of the three, being the only one with
working IRQ support and reset survival.

---

## 10. Future Enhancement: Persistent Time via External RTC

The A2FPGA v2 has no free FPGA GPIO pins. A future board revision could add I2C access
to a DS3231 RTC module for persistent time across full power loss.

An alternative approach uses the existing USB-C port: a small carrier board with a
DS3231 + MCU sends the current time to the FPGA via the BL616 USB-to-UART bridge on
boot. This requires no FPGA hardware changes — only a passive UART listener in HDL
(~80-120 lines, ~50-80 LUTs, 0 BSRAM, 0 I/O pins).

For most users, the USB-C power persistence (§5.4) provides adequate timekeeping without
additional hardware.

---

## Appendix A: uPD1990AC Datasheet Reference

- **Manufacturer**: NEC (now Renesas)
- **Package**: 14-pin DIP
- **Operating voltage**: 2.5V-6.0V (CMOS)
- **Crystal**: 32.768 kHz (external)
- **Power consumption**: ~1 µW (with 3V battery backup)
- **Shift register**: 40 bits, serial in/out, LSB first
- **Calendar**: Seconds, minutes, hours, day-of-month, day-of-week, month (BCD)
- **No year register** (confirmed by multiple sources including MAME, izapple2, and NEC documentation)
- **Timer pulse**: 64/256/2048/4096 Hz programmable output
- **Datasheet**: NEC uPD1990AC-006

## Appendix B: References

- [ThunderClock Plus Manual](https://archive.org/details/ThunderClock_Plus) — Thunderware official documentation
- [ProDOS Technical Note #1](https://prodos8.com/docs/technote/01/) — Clock driver interface
- [ProDOS TechRef: Adding Routines](https://prodos8.com/docs/techref/adding-routines-to-prodos/) — Clock driver protocol
- [MAME a2thunderclock.cpp](https://github.com/mamedev/mame/blob/master/src/devices/bus/a2bus/a2thunderclock.cpp) — MAME emulation source
- [MAME upd1990a.cpp](https://github.com/mamedev/mame/blob/master/src/devices/machine/upd1990a.cpp) — uPD1990A/AC chip emulation
- [izapple2 cardThunderClockPlus.go](https://github.com/ivanizag/izapple2/blob/master/cardThunderClockPlus.go) — Go emulator implementation
- [izapple2 microPD1990ac.go](https://github.com/ivanizag/izapple2/blob/master/component/microPD1990ac.go) — uPD1990AC chip emulation
- [Michaelangel007/apple2_thunderclock](https://github.com/Michaelangel007/apple2_thunderclock) — Hardware teardown, parts list
- [uPD1990AC Datasheet](https://www.alldatasheet.com/datasheet-pdf/pdf/113488/NEC/UPD1990AC.html) — NEC specifications
- [erikp9000/necclock](https://github.com/erikp9000/necclock) — uPD1990AC documentation project
- [MiSTer Apple-II_MiSTer](https://github.com/MiSTer-devel/Apple-II_MiSTer) — MiSTer FPGA core (has clock in slot 1)
