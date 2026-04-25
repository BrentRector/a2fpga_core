# Resume Prompt — SoftCard Emulation Planning

> Hand this file to a fresh Claude Code session to pick up where the previous one left off. Read it top-to-bottom before doing anything else; it's self-contained.

## Where you are

You are working in the **`e:\a2fpga_core`** repo — a fork of `a2fpga/a2fpga_core` (an FPGA core for an Apple II coprocessor / video card on the Tang Nano 20K, board variant `a2n20v2`). The fork adds Videx VideoTerm and ThunderClock Plus emulation on top of upstream's Mockingboard, SuperSprite, and Super Serial Card emulations.

The active work is **planning Microsoft Z-80 SoftCard emulation** to enable CP/M on the FPGA. The user (Brent Rector) is the developer of this fork.

## What's been completed (in date order)

### Videx ROM preservation (mostly done)

Three Videoterm firmware ROM variants are dumped, disassembled, and analyzed:

| ROM | Year | Frame | Use |
|---|---|---|---|
| 2.4 | (pre-1982) | PAL 50 Hz | Original European; baseline for diffs |
| **VT-FRM-600** | 1982 | NTSC 60 Hz | First refactored variant; SETUP loop + NTSC retune |
| **VT-FRM-602** | 1983 | PAL 50 Hz | FRM-600 with R2-R5 reverted to PAL |

Files in [`hdl/videx/`](hdl/videx/):
- `Videx Videoterm ROM 2.4.bin` + `.asm` (disassembly)
- `Videx Videoterm ROM VT-FRM-600.bin` + `.asm`
- `Videx Videoterm ROM VT-FRM-602.bin` + `.asm`
- 8 source-image JPGs from screen dumps

Analysis in [`docs/Videx ROM Version Differences Analysis.md`](docs/Videx%20ROM%20Version%20Differences%20Analysis.md): detailed comparison; bottom line is that all three are byte-identical outside the 13-17 byte SETUP/CRTC region, and the CRTC differences don't affect the A2FPGA's HDMI rendering pipeline (so all three would render identically on this hardware).

The user-facing BASIC ROM viewer used to dump these is at [`tools/videx_rom_viewer.bas`](tools/videx_rom_viewer.bas).

### SoftCard CP/M disk image archive (done)

Eight disk images at [`docs/SoftCard CP-M Disk Images/`](docs/SoftCard%20CP-M%20Disk%20Images/) covering the full Microsoft SoftCard CP/M release history 1980-1984:
- 2.20 (1980, original)
- 2.20B (1980, three variants — 44K master, 56K disk 1, 56K disk 2)
- **2.23 (1982) — first version with Pascal-1.1 firmware-card recognition (the "CP/M compatibility fix" historical sources reference). Filename is `CPMV233.DSK` despite the misleading "V233" — boot string confirms 2.23.**
- 2.25 (1983, Premium SoftCard IIe)
- 2.26 (1983, standard SoftCard IIe)
- 2.28B (1984, SoftCard II)

The 2.23 disk is the boot reference for the SoftCard emulation work — its 6502 boot stub + I/O dispatch BIOS is what the emulated hardware must accept.

### SoftCard feasibility analysis (done)

[`docs/SoftCard Feasibility Analysis.md`](docs/SoftCard%20Feasibility%20Analysis.md) is the primary planning document. Headlines:

- **Verdict:** Feasible as a bitstream project, conditional on two unverified bridge-IC behaviors. Estimated 3-4 weekends to first reliable CP/M boot, 5-6 with polish.
- **Bridge protocol** (in `boards/a2n20v2/hdl/bus/apple_bus.sv`) already declares `IO_WRITE_ADDR`, `a2_bridge_bus_a_oe_n_o`, and `control_out_r[4]` (DMA-out) as output paths but never uses them. The signal naming and protocol structure strongly suggest the bridge IC is designed to support bus-mastering; **needs empirical verification** (V1 = address-bus drive works; V2 = `control_out_r[4]=0` halts the 6502).
- **Resource budget** (from `boards/a2n20v2/impl/pnr/a2n20v2.rpt.txt`): 39% logic, **98% BSRAM** (1 block free), 29% registers. Z-80 64K main memory must live in the largely-unused 8 MB SDRAM, not BSRAM. **Recommended: disable SuperSprite/F18A** to free 10 BSRAM blocks + 1500 LUTs of headroom — F18A has no value to CP/M users.
- **No existing emulation uses any bus-master features.** All cards are passive slot peripherals. The SoftCard would be the only consumer of `IO_WRITE_ADDR` / DMA-out, so adding it is purely additive — no feature contention.
- **Default slot:** 4 (matches SoftCard convention; slot 3 = Videx, 6 = Disk II in typical Apple II configs).

### Repo housekeeping (done)

- All HDMI fix branches (Samsung compat, OE cutoff, hdl-util PR #44 port) are merged into `main` as commits `35ae550`, `c19ddf8`, `dd7617d`. The branches and their associated upstream PRs (#35, #36, #37, #38) were deleted to avoid future confusion. Upstream `a2fpga/a2fpga_core` is dormant (no merges since 2025-07-12) so the PRs were unlikely to land anyway.
- Documentation moved to `docs/` (was at repo root).
- `.asm` and `.bin` files for Videx live next to each other in `hdl/videx/` with consistent naming.

## Where to pick up: SoftCard implementation

The next step is **Phase 0 — bridge verification** from §6.1 of the feasibility doc. Until V1 and V2 confirm, no further implementation work is justified. **Do this first.**

### Phase 0 deliverables

1. **V1 test:** A diagnostic bitstream that, on FPGA boot:
   - Asserts DMA via `control_out_r[4] = 1'b0`
   - Issues `IO_WRITE_ADDR` to drive a known Apple RAM address
   - Issues `IO_WRITE_DATA` to write a sentinel byte
   - Releases DMA
   - A small Apple-side stub (boot ROM or autostart BASIC line) reads that address and prints the value to text page 1

2. **V2 test:** Drive `control_out_r[4]` low for measured intervals while the 6502 increments a counter at `$0200` in a tight loop. Counter should freeze for the duration of the DMA assertion.

If both tests pass, proceed to Phase 1 (bus-master scaffolding). If either fails, fall back to the Appli-Card co-processor architecture in §9 of the feasibility doc — same Z-80 core, same CP/M, but private 64 KB RAM and SD-card-virtualized disks instead of bus-mastering Apple RAM and using a real Disk II.

### Architecture overview (from feasibility doc §5)

New top-level card module: `hdl/softcard/softcard.sv` (analogous to `hdl/videx/videx_card.sv`). Internal modules:

- `softcard_z80.sv` — T80 Z-80 core wrapper (recommended core: T80 by Daniel Wallner, ~1500-2200 LUTs, public domain)
- `softcard_memmap.sv` — Z-80↔Apple address swap (Z-80 A15 ↔ Apple A12) and routing between Apple memory shadow (fast path, reads only) and bus-master (writes + uncached reads)
- `softcard_busmaster.sv` — DMA arbitration with Apple phi clocks; drives `apple_bus.sv` extensions

Extensions to `apple_bus.sv`:
- New input ports for bus-master requests: `bm_addr`, `bm_data_w`, `bm_rw`, `bm_req`, with `bm_data_r`, `bm_ack` outputs
- Drive `control_out_r[4]` low when a bus-master cycle is pending
- Issue `IO_WRITE_ADDR` and assert `a2_bridge_bus_a_oe_n_o` low when bus-mastering

Slot interface: a single device-select port at `$C0n0` (n = slot+8) with bit 0 = Z-80 enable, bit 1 = Z-80 reset.

### Key open questions before/during Phase 0

- Does the bridge IC actually drive Apple address bus on `IO_WRITE_ADDR`? (V1)
- Does the bridge IC actually pull `DMA_n` low when `control_out_r[4] = 0`? (V2)
- What's the exact bit-swap pattern for the SoftCard memory map? Microsoft's SoftCard schematic should be located and consulted (the structurally-correct guess in feasibility doc §5.3 should be confirmed against primary source).
- Does the SoftCard CP/M boot disk's 6502 dispatch code probe the slot to detect SoftCard presence? (Likely yes — the boot is slot-agnostic per period docs.) If so, the FPGA's slot port behavior must respond correctly to whatever probe pattern the disk uses.

## Repo orientation for new sessions

- **Top-level board file:** `boards/a2n20v2/hdl/top.sv` — instantiates all enabled cards. Add `SOFTCARD_ENABLE` parameter and instantiation here when implementing.
- **Bus interface:** `boards/a2n20v2/hdl/bus/apple_bus.sv` — the file that needs extension for bus-mastering.
- **Synthesis report:** `boards/a2n20v2/impl/pnr/a2n20v2.rpt.txt` — current resource utilization. Re-run synthesis after major changes; check BSRAM doesn't exceed 100%.
- **Existing card examples:** `hdl/videx/videx_card.sv` (most complex, MC6845 + render pipeline + VRAM), `hdl/thunderclock/` (simpler, slot-port + IRQ pattern).
- **PicoRV32 / picosoc:** Present in `hdl/picosoc/` source tree, but **not instantiated in stock a2n20v2 build** (only in `a2n20v2-Enhanced`). Don't assume picosoc/SD-card infrastructure is wired up unless verified.
- **Disk emulation modules:** `hdl/disk/apple_disk.sv` and `hdl/disk/drive_ii.sv` are upstream-experimental; **not instantiated in any board's top.sv**. Treat as dead code until otherwise confirmed.

## User interaction notes

The user (Brent Rector) values:
- **Intellectual honesty.** Don't claim something is verified when it's inferred. Don't conflate "exists in source tree" with "shipping in the bitstream." If you don't know, say so.
- **Cited claims.** Every factual assertion should trace to a specific file, commit, or external source. The user has caught at least three cases of overclaiming in this conversation; expect them to do it again.
- **Surgical commits.** Don't introduce drive-by changes. Each commit does one thing, has a clear message including a co-author trailer for AI work.
- **No throwaway scripts.** Memory file says "remove one-off analysis scripts before staging." Inline `python3 -c '...'` for analysis is fine; `tools/something_one_off.py` should not be committed.
- **Explicit confirmation for destructive ops.** Branch/PR deletion, force-push, etc. always confirm consequences first.

## Useful commands for the next session

```bash
# Sanity check: are we on the right branch / clean state?
cd e:/a2fpga_core && git status && git log --oneline -5

# Resource budget snapshot
cat "boards/a2n20v2/impl/pnr/a2n20v2.rpt.txt" | head -80

# Open feasibility doc
cat "docs/SoftCard Feasibility Analysis.md"

# Confirm SoftCard 2.23 disk image is intact (boot string check)
python3 -c "
import re
data = open('docs/SoftCard CP-M Disk Images/CPMV233.DSK','rb').read()
for m in re.finditer(rb'Softcard CP/M[^\\x00]*', data):
    print(m.group(0)[:80])
" | head -5

# Survey the bridge protocol surface
grep -n "IO_\|control_out_r\|control_in_r\|a2_bridge" \
  boards/a2n20v2/hdl/bus/apple_bus.sv | head -40
```

## Reference materials

- [`docs/SoftCard Feasibility Analysis.md`](docs/SoftCard%20Feasibility%20Analysis.md) — primary planning document
- [`docs/Videx ROM Version Differences Analysis.md`](docs/Videx%20ROM%20Version%20Differences%20Analysis.md) — sister analysis for the Videx ROM family
- [`docs/SoftCard CP-M Disk Images/README.md`](docs/SoftCard%20CP-M%20Disk%20Images/README.md) — index of CP/M disk images
- Pausch Apple CP/M reference: <http://stjarnhimlen.se/apple2/Apple.CPM.ref.txt>
- Apple II Pascal 1.1 ATTACH-BIOS spec: <https://mirrors.apple2.org.za/ftp.apple.asimov.net/documentation/programming/pascal/Apple%20II%20Pascal%20ATTACH.pdf>
- T80 Z-80 core: search OpenCores for "T80 Daniel Wallner"
- TV80 Z-80 core: <https://github.com/hutch31/tv80>

## Suggested first prompt to a fresh session

> Read `resume-prompt.md` first, then walk me through what you'd do for Phase 0 bridge verification. I want a small standalone test bitstream that proves the bridge IC can drive the Apple address bus and assert DMA. Outline the modules you'd add, where they'd live in the tree, and what the success criteria look like before you write any code. Don't make assumptions about bridge behavior — it's the unknown the test is designed to resolve.
