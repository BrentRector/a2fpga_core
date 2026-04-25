# Microsoft Z-80 SoftCard Emulation on the A2FPGA — Feasibility Analysis and Implementation Plan

> **Status of this document.** Resource numbers are drawn from the actual `boards/a2n20v2/impl/pnr/a2n20v2.rpt.txt` synthesis report. Bridge-protocol observations are drawn from `boards/a2n20v2/hdl/bus/apple_bus.sv`. Two key bridge behaviors that the plan depends on are explicitly flagged as **unverified**; if they fail to confirm, the recommendations in §3.3 apply.

---

## 1. Executive summary

Emulating the Microsoft Z-80 SoftCard on the existing A2FPGA hardware is **feasible as a bitstream development project**, conditional on two bridge-IC behaviors that need empirical verification before substantial work begins. The current resource budget has comfortable logic headroom (39% used) but only one BSRAM block free; the SoftCard fits without displacing existing cards if its 64 KB of Z-80 main memory is parked in the otherwise-idle 8 MB SDRAM. Disabling SuperSprite/F18A is recommended regardless — it has no value to CP/M users and frees ~10 BSRAM blocks plus ~1,500 LUTs of comfortable margin.

The single most important architectural insight is that **no existing card emulation uses any of the bus-master features the SoftCard requires**. Every shipping emulation is a passive slot peripheral. The bridge protocol exposes `IO_WRITE_ADDR` (drive Apple address bus) and `control_out_r[4]` (assert DMA on Apple bus) as currently-unused output paths. If those paths terminate in a bridge IC that physically wires through to the Apple II edge connector — which the signal naming and protocol structure strongly suggest — the SoftCard project is purely an HDL-and-firmware effort, not a hardware change.

A working CP/M boot to a `B>` prompt on a real SoftCard 2.23 (or later) disk is estimated at **3-4 person-weekends** of focused work after bridge verification, plus another 2-4 weekends for compatibility polish. The Microsoft SoftCard CP/M disk images already in [`docs/SoftCard CP-M Disk Images/`](SoftCard%20CP-M%20Disk%20Images/) provide both the boot media and the BIOS reference for I/O routines.

**Recommendation:** Spend two evenings on the bridge-verification work in §6.1 before committing to the full plan. If verification succeeds, proceed with the phased implementation in §6. If it fails, fall back to the Appli-Card-style co-processor architecture in §9.

---

## 2. Background

### 2.1 What the Microsoft Z-80 SoftCard does

The Microsoft Z-80 SoftCard, introduced in April 1980, was Microsoft's first hardware product. It's a single-slot Apple II expansion card that hosts a Z-80 CPU running at a nominal 4 MHz (about 2 MHz effective, due to shared bus cycles with the Apple's video circuitry). The card has **no on-card RAM** — it runs CP/M out of the Apple II's main DRAM by halting the 6502 via the slot bus's `DMA` line and bus-mastering the Apple's address and data buses itself.

The Z-80 sees the Apple II's memory through a fixed address-line swap that puts CP/M's TPA at low addresses and the 6502's I/O page at the top of the Z-80's view, where CP/M expects ROM. Specifically (from the SoftCard schematic), the Z-80's `A15` and `A12` are routed to the Apple's `A12` and `A15` respectively — a high-nibble bit-swap that rotates the I/O hole out of the way for Z-80-side execution.

CP/M I/O (disk, console) is handled by briefly handing control back to the 6502: writes to the SoftCard's slot port toggle the DMA line, the Z-80 stalls, the 6502 services the request through normal Apple firmware, then the 6502 toggles the port back and the Z-80 resumes.

### 2.2 Why emulate it

The Apple II CP/M ecosystem (1980-1985) included nearly every important CP/M-80 application of the era: WordStar, dBase II, MBASIC, Turbo Pascal, CB80, Multiplan, and many others. Native Apple II software cannot run any of these. A working SoftCard emulation expands the A2FPGA's compatible software corpus by an entire operating system's worth of titles.

The CP/M disks that have survived the era are predominantly SoftCard-format. The Microsoft Z-80 SoftCard is the de facto reference for "what CP/M on Apple II means," not the lesser-distributed Appli-Card or PCPI cards. Faithful emulation lets archived disks boot directly without re-mastering.

### 2.3 The CP/M compatibility update (context)

A historical complication: SoftCard CP/M BIOS versions 2.20 and 2.20B (the first two releases) cannot identify Apple Pascal 1.1 firmware cards, so they fail to talk to the Videoterm correctly. **SoftCard CP/M BIOS 2.23 (1982)** added Pascal-1.1 firmware-card recognition; this is the version that "made CP/M work with the Videoterm." The full release history with all relevant disk images is preserved in [`docs/SoftCard CP-M Disk Images/`](SoftCard%20CP-M%20Disk%20Images/).

For the SoftCard emulation to drive the existing Videoterm emulation in slot 3 with 80-column output, the CP/M boot disk used must be **2.23 or later**. The 2.20/2.20B disks are useful only for testing 40-column-fallback behavior.

---

## 3. Hardware feasibility

### 3.1 What the existing bridge protocol exposes

The FPGA-to-bridge protocol defined in [`boards/a2n20v2/hdl/bus/apple_bus.sv`](../boards/a2n20v2/hdl/bus/apple_bus.sv) includes the following commands and signals that the current bitstream **declares but does not exercise**:

| Resource | Current usage | Required for SoftCard |
|---|---|---|
| `IO_WRITE_ADDR` (state 3) | Defined; never issued | ✅ Need to issue this every Z-80 memory cycle |
| `IO_READ_ADDR` (state 2) | Used only for sniffing 6502 cycles | ✅ Same protocol; can reuse |
| `IO_WRITE_DATA` (state 5) | Used by all card emulations | ✅ Already works |
| `a2_bridge_bus_a_oe_n_o` | Held high (output disabled) | ✅ Need to assert low during bus-mastered cycles |
| `a2_bridge_bus_d_oe_n_o` | Asserted for slot-card data writes | ✅ Already works |
| `control_out_r[2]` (IRQ-out) | Used by Mockingboard, SSC | (not needed by SoftCard) |
| `control_out_r[4]` (DMA-out) | Held at 1 (deasserted) | ✅ Need to drive low to halt 6502 |
| `control_out_r[3]` (RDY-out) | Held at 1 (deasserted) | ⚠️ Possibly useful for fine-grained 6502 stalling |

The asymmetric design — separate output enables for the address and data buses, distinct command states for address vs. data writes — is structurally meaningful: the bridge IC's protocol is designed for a controller that may sometimes drive only data (slot-peripheral mode) and sometimes drive both address and data (bus-master mode).

### 3.2 What needs verification

Two empirical questions must be answered before serious development:

#### V1: Does `IO_WRITE_ADDR` actually drive the Apple address bus?

Test bitstream: at reset, write a known sentinel byte to a known Apple RAM address using `IO_WRITE_ADDR` + `IO_WRITE_DATA`. Then have the 6502 read that address. If the read returns the sentinel, the bridge correctly drove the address bus and the SoftCard plan is on track.

Equipment: working Apple II + Tang Nano 20K + a small assembly stub on a boot disk that reads, prints the sentinel byte. (Or just observe with a logic probe / scope on slot pins if available.)

#### V2: Does `control_out_r[4] = 0` actually pull `DMA_n` low at the slot, halting the 6502?

Test bitstream: from a known-good 6502 program with a tight loop that writes to a memory location every iteration, drive `control_out_r[4]` low at a known time. The 6502 should freeze; the memory location should stop updating. Drive it back high; the 6502 should resume.

If both V1 and V2 confirm, the SoftCard project is HDL-and-firmware-only.

### 3.3 If V1 or V2 fails

| Failure mode | Consequence |
|---|---|
| V1 fails, V2 passes | Cannot bus-master memory writes. SoftCard emulation infeasible on this bridge. Drop to Appli-Card co-processor architecture (§9). |
| V2 fails, V1 passes | Cannot halt 6502. Could attempt RDY-line stalling (`control_out_r[3]`) instead — only works on 65C02 / Apple //e and later. Or fall back to Appli-Card. |
| Both fail | Bus-mastering not available without bridge firmware update. Appli-Card architecture remains feasible. |

The Appli-Card fallback is described in §9 below. It's a bigger HDL project (SD-card disk virtualization must be built) but doesn't require any bridge capabilities the current build doesn't already use.

### 3.4 Timing feasibility (assuming V1/V2 confirm)

The bridge transaction latency from `apple_bus.sv` (`WRITE_COUNT = 10` cycles @ 54 MHz):

- One bridge transaction ≈ **185 ns**
- Apple phi0 half-period ≈ **490 ns**
- One full Apple bus cycle ≈ **979 ns**

The Z-80 SoftCard runs at 4 MHz nominal, ~2 MHz effective due to shared video cycles. A typical Z-80 instruction is 4-23 T-states; at 2 MHz that's 2-12 µs per instruction, of which 1-7 are memory accesses. We need to deliver memory cycles at roughly **2 MHz peak Apple bus access**.

The Apple bus delivers exactly **1.022 MHz** of usable cycles (one access per phi0). Bridge throughput at 5.4 MHz isn't the limit; **the Apple bus itself caps Z-80 effective speed at ~1 MHz** under continuous bus-master mode. That's *slower* than the real SoftCard's 2 MHz effective, because the real SoftCard interleaves with video refresh on alternate phi cycles whereas our emulation sees only the FPGA-bridge-Apple-bus pipeline.

**Mitigation:** Cache Z-80 fetches in the FPGA's existing Apple memory shadow (which already mirrors the Apple's main RAM for the video pipeline). For instruction fetches and read-only data, the Z-80 reads from the FPGA's internal shadow at full SDRAM speed (>100 MB/s aggregate); only writes need to bus-master to the Apple's actual DRAM to keep the shadow coherent. Effective Z-80 speed could exceed real-SoftCard performance by 2-4×.

---

## 4. Resource budget

### 4.1 Current utilization (synthesis report)

From `boards/a2n20v2/impl/pnr/a2n20v2.rpt.txt`:

```
Logic (LUT + ALU + ROM16)   8,032 / 20,736   39%
Registers                   4,421 / 15,552   29%
CLS                         6,349 / 10,368   62%
BSRAM                          45 /     46   98%
DSP                            21 / ~33      64%
PLL                             2 /      2  100%
```

The binding constraint is **BSRAM** at 98% (1 block free). Logic and registers have abundant headroom.

### 4.2 BSRAM allocation by module (from `a2n20v2_syn_resource.html`)

| Module | BSRAM | Notes |
|---|---|---|
| Apple memory shadow (text + 3× hires aux/main) | 28 | Required for video pipeline |
| SuperSprite / F18A (vram + sprites) | 10 | Removable; no CP/M value |
| Videx VideoTerm (firmware + char ROM + VRAM) | 3 | Required for CP/M console |
| Apple video pipeline | 2 | Required |
| ThunderClock firmware ROM | 1 | Optional |
| Super Serial Card firmware ROM | 1 | Optional |
| Mockingboard | 0 | Logic-only; no BSRAM |
| **Total** | **45** | |

### 4.3 SoftCard cost estimate

| Component | LUT+ALU | Registers | BSRAM | SDRAM | Notes |
|---|---|---|---|---|---|
| T80 Z-80 core | 1,500-2,200 | 700 | 0-1 | 0 | Public domain, well-tested |
| Bus-master controller | 300 | 150 | 0 | 0 | New module |
| Memory router (shadow vs. bus-master fetch) | 200 | 100 | 0 | 0 | New module |
| Slot decoder + control register | 80 | 30 | 0 | 0 | Small |
| Z-80 main memory (64 KB) | 0 | 0 | 0 | 64 KB | In SDRAM |
| Optional Z-80 register-file shadow | 0 | 0 | 0-1 | 0 | Small BSRAM if used |
| **Total (RAM in SDRAM)** | **~2,100-2,800** | **~1,000** | **~1** | **64 KB** | Recommended |
| Total (RAM in BSRAM) | ~2,100-2,800 | ~1,000 | ~33 | 0 | Not feasible without disabling Apple shadow |

### 4.4 Net utilization with SoftCard added

Two scenarios:

**Scenario A: Add SoftCard, change nothing else.**
- Logic: 8,032 + 2,400 = ~10,400 / 20,736 = **50%** (still abundant)
- BSRAM: 45 + 1 = 46 / 46 = **100%** (no margin)
- SDRAM: +64 KB (negligible)

This works but has zero BSRAM headroom. Any future change that needs even one more block will require a card removal.

**Scenario B: Disable SuperSprite, add SoftCard. (Recommended.)**
- Logic: 8,032 - 1,453 + 2,400 = ~9,000 / 20,736 = **43%** (comfortable)
- BSRAM: 45 - 10 + 1 = **36 / 46 = 78%** (10 blocks free)
- SDRAM: +64 KB

This restores BSRAM headroom to a comfortable level and gives margin for future work. The cost is loss of F18A graphics, which CP/M software doesn't use.

### 4.5 Feature-conflict analysis

Every existing card emulation was inspected for use of the bridge features the SoftCard requires. Result:

| Feature | Used by Videx? | SuperSprite? | Mockingboard? | SSC? | ThunderClock? |
|---|---|---|---|---|---|
| `IO_WRITE_ADDR` (drive A2 address bus) | ❌ | ❌ | ❌ | ❌ | ❌ |
| `a2_bridge_bus_a_oe_n_o = 0` | ❌ | ❌ | ❌ | ❌ | ❌ |
| `control_out_r[4] = 0` (assert DMA) | ❌ | ❌ | ❌ | ❌ | ❌ |
| `control_out_r[3] = 0` (assert RDY-low) | ❌ | ❌ | ❌ | ❌ | ❌ |
| FPGA-driven reads of A2 main RAM | ❌ | ❌ | ❌ | ❌ | ❌ |

All currently-shipping emulations are passive slot peripherals. **No feature contention; the SoftCard is purely additive.**

---

## 5. Proposed architecture

### 5.1 Block diagram (textual)

```
                ┌─────────────────────────────────────────────────┐
                │                  A2FPGA core                    │
                │                                                 │
                │   ┌──────────────────┐                          │
                │   │ Existing cards   │                          │
                │   │ (Videx, SSC,     │  ← passive slot mode    │
                │   │  ThunderClock,   │                          │
                │   │  Mockingboard)   │                          │
                │   └──────────────────┘                          │
                │                                                 │
                │   ┌──────────────────────────────────┐          │
                │   │   NEW: Z-80 SoftCard             │          │
                │   │                                  │          │
                │   │   ┌─────────┐    ┌────────────┐  │          │
                │   │   │  T80    │←──→│ memory     │  │          │
                │   │   │  Z-80   │    │ router     │←─┼──→ SDRAM (Z-80 RAM)
                │   │   │  core   │    │            │  │          │
                │   │   └─────────┘    └─────┬──────┘  │          │
                │   │                        │         │          │
                │   │                        ▼         │          │
                │   │                  ┌──────────┐    │          │
                │   │                  │ bus-     │    │          │
                │   │                  │ master   │←───┼─ Apple memory shadow
                │   │                  │ ctrl     │    │     (read-only fast path)
                │   │                  └────┬─────┘    │          │
                │   │                       │          │          │
                │   │   ┌──────────┐        │          │          │
                │   │   │ slot dec │        │          │          │
                │   │   │ + ctrl   │        │          │          │
                │   │   │ register │        │          │          │
                │   │   └────┬─────┘        │          │          │
                │   └────────┼──────────────┼──────────┘          │
                │            │              │                     │
                │            ▼              ▼                     │
                │   ┌────────────────────────────────┐            │
                │   │       apple_bus.sv             │            │
                │   │  (extended for IO_WRITE_ADDR   │            │
                │   │   + control_out_r[4] DMA)      │            │
                │   └────────────┬───────────────────┘            │
                └────────────────┼─────────────────────────────────┘
                                 │
                          ┌──────▼──────┐
                          │ a2bridge IC │
                          └──────┬──────┘
                                 │
                       Apple II edge connector
                       (address bus, data bus, DMA, phi, ...)
```

### 5.2 Component breakdown

#### `softcard.sv` (new top-level card module)

Responsibilities:
- Decode I/O writes to its slot's device-select page
- Maintain a Z-80-enable / Z-80-reset control register
- Coordinate DMA assertion via `apple_bus.sv`
- Instantiate the T80 core, memory router, and bus-master controller

#### `softcard_z80.sv` (T80 wrapper)

Responsibilities:
- Wrap the T80 core (or TV80 / NextZ80) with the FPGA's clock domain
- Expose memory and I/O cycle interfaces to the memory router
- Handle Z-80 reset, halt, and IRQ inputs

#### `softcard_memmap.sv` (memory router)

Responsibilities:
- Translate Z-80 addresses to Apple addresses via the SoftCard's bit-swap (Z-80 A15 ↔ A12)
- For Z-80 reads of cacheable regions: serve from Apple memory shadow at SDRAM speed
- For Z-80 reads of non-cacheable regions (Apple I/O space `$C000-$CFFF` from Z-80's view, after the swap): bus-master through `softcard_busmaster.sv`
- For Z-80 writes: bus-master AND update the shadow (write-through)

#### `softcard_busmaster.sv` (bus-master controller)

Responsibilities:
- Accept memory transactions from the memory router
- Assert DMA on the Apple bus (`control_out_r[4] = 0`)
- Drive `IO_WRITE_ADDR` to set the address
- Drive `IO_WRITE_DATA` (writes) or `IO_READ_DATA` (reads) and capture results
- Track Apple phi alignment; only initiate transactions during the appropriate half-cycle
- Deassert DMA when the memory router has no pending transactions and the Z-80 is paused

#### Extensions to `apple_bus.sv`

- Add a write port for `control_out_r[4]` driven by `softcard_busmaster.sv`
- Allow the bus-master to drive `a2_bridge_bus_a_oe_n_o` low and issue `IO_WRITE_ADDR`
- Arbitrate between bus-master cycles and the existing slot-peripheral cycles (slot peripherals have priority during phi0 reads of their addresses; bus-master takes the bus when no slot card is selected and DMA is asserted)

### 5.3 Memory map (Z-80's view)

The SoftCard's address swap (Z-80 A15 ↔ Apple A12, Z-80 A12 ↔ Apple A15) gives:

| Z-80 address | Apple address (after swap) | Contents |
|---|---|---|
| `$0000-$0FFF` | `$1000-$1FFF` | Apple RAM (CP/M warm-boot vector area at Z-80 `$0000-$00FF`) |
| `$1000-$BFFF` | (varies) | Apple RAM (CP/M TPA, BDOS) |
| `$C000-$CFFF` | `$C000-$CFFF` | Apple I/O page — accessed for SoftCard control register only |
| `$D000-$DFFF` | `$5000-$5FFF` | Apple RAM |
| `$E000-$EFFF` | `$6000-$6FFF` | Apple RAM |
| `$F000-$FFFF` | `$7000-$7FFF` | Apple RAM (CP/M CCP + BDOS + BIOS top-of-memory) |

(The exact swap is per Microsoft's SoftCard schematic; this is the structurally correct layout but the precise bit-swap pattern should be confirmed against the SoftCard's PAL or schematic before implementation.)

### 5.4 6502-side interface

The SoftCard occupies one slot (typically slot 4 or 7). The 6502 sees a single device-select port at `$C0n0` (where `n = slot + 8`):

| Bit | Function |
|---|---|
| 0 | Z-80 enable (1 = run Z-80, 0 = release DMA, 6502 runs) |
| 1 | Z-80 reset (1 = hold Z-80 in reset) |
| Other bits | Reserved |

Reads of `$C0n0` return the current state. The 6502-side CP/M loader writes 0x01 to start CP/M; the SoftCard CP/M BIOS handler writes 0x00 to release control to the 6502 for I/O, then 0x01 to resume.

The slot's expansion ROM area `$Cn00-$CnFF` holds a small 6502 boot stub that loads CCP+BDOS+BIOS from a CP/M floppy and starts the Z-80.

---

## 6. Implementation plan

### 6.1 Phase 0 — Bridge verification (1-2 evenings)

**Goal:** Confirm V1 (`IO_WRITE_ADDR` drives Apple address bus) and V2 (`control_out_r[4]` halts the 6502).

Deliverables:
1. A diagnostic bitstream `softcard_bridge_test/` that, on FPGA boot:
   - Asserts DMA, drives an address, drives a data byte, releases DMA
   - Then has a small Apple-side reader read that location and write the value to text page 1 ($400)
2. A "stall-the-6502" test: the 6502 increments a counter at $0200 in a tight loop; the FPGA periodically asserts DMA for measured intervals; the counter rate should drop proportionally
3. Pass/fail report

**Exit criteria:** Both tests pass on real hardware. If they pass, proceed. If either fails, defer to §9 (Appli-Card path).

### 6.2 Phase 1 — Bus-master scaffolding (1 weekend)

**Goal:** Build `softcard_busmaster.sv` and extend `apple_bus.sv` so that arbitrary Apple memory locations can be read and written from the FPGA under software control, with proper phi-alignment.

Deliverables:
1. Extended `apple_bus.sv` with bus-master cycle support:
   - New input ports: `bm_addr`, `bm_data_w`, `bm_rw`, `bm_req`
   - New output ports: `bm_data_r`, `bm_ack`
   - Extended state machine to accept bus-master requests during phi0 when no slot peripheral cycle is pending
2. `softcard_busmaster.sv` exposing a clean memory-transaction interface
3. A simple test harness (PicoRV32 or hand-driven state machine) that reads/writes Apple RAM via the bus-master path and validates the result

**Exit criteria:** Read-write loop runs at sustained ~1 MHz Apple-bus throughput, with the 6502 halted for the duration. Memory contents match expected values.

### 6.3 Phase 2 — Z-80 core integration (1 weekend)

**Goal:** Drop in the T80 core, give it 64 KB of SDRAM-backed memory, and run small Z-80 test programs out of FPGA-internal RAM (no bus-mastering yet).

Deliverables:
1. T80 instantiation in a new `softcard_z80.sv`
2. SDRAM-backed 64 KB Z-80 memory (use existing `sdram_port_if`)
3. A boot ROM with a small Z-80 program that, e.g., increments memory and outputs to a debug port
4. Validation: Z-80 runs the test program; debug port shows expected values

**Exit criteria:** Z-80 executes from SDRAM-backed memory at the target clock rate (≥ 4 MHz internal, ~2 MHz effective when bus-mastering is enabled in Phase 4).

### 6.4 Phase 3 — Memory routing and address swap (1 weekend)

**Goal:** Implement the SoftCard's address-line swap and route Z-80 memory accesses through the memory router. Reads from the Apple shadow for cacheable regions; bus-master only for writes (in this phase, no real cache coherence yet — just write-through).

Deliverables:
1. `softcard_memmap.sv` with the Z-80↔Apple address bit-swap
2. Read path: Z-80 reads → Apple shadow lookup
3. Write path: Z-80 writes → bus-master to Apple RAM + shadow update (write-through)
4. Test: Run a Z-80 program that reads from one Apple address and writes to another; verify the 6502 sees the result after Z-80 yields

**Exit criteria:** Z-80 can read and write Apple RAM with correct address translation. 6502 sees Z-80's writes after DMA is released.

### 6.5 Phase 4 — Slot interface and DMA control (1-2 evenings)

**Goal:** Wire up the slot's device-select port so the 6502 can start, stop, and reset the Z-80. Implement clean DMA hand-off.

Deliverables:
1. `softcard.sv` top-level with slot decoder
2. Control register at `$C0n0` for Z-80 enable/reset
3. DMA assert on Z-80 enable; DMA release on Z-80 disable
4. Test: 6502 BASIC program writes 0x01 to start Z-80; Z-80 runs a known program; 6502 writes 0x00 to stop; result visible to 6502

**Exit criteria:** Cooperative round-trip works. 6502-side software can fully control Z-80 lifecycle.

### 6.6 Phase 5 — Boot a real CP/M disk (1 weekend)

**Goal:** Boot the SoftCard CP/M 2.23 disk image (or 2.26 / 2.28B) from a real Apple Disk II drive and reach the `B>` (or `A>`) prompt.

Deliverables:
1. Slot expansion ROM ($Cn00) populated with a 6502 stub that:
   - Reads sector 0 of the boot disk via Apple's normal Disk II routines
   - Loads CCP+BDOS+BIOS into Apple RAM
   - Asserts Z-80 enable
2. Validation that SoftCard CP/M's I/O dispatcher works:
   - Console output goes through the Videoterm in slot 3
   - Disk I/O calls back to the 6502, which uses Apple's RWTS

**Exit criteria:** `A>DIR` returns the disk's catalog. Console echo works. CP/M `.COM` files (e.g., `STAT.COM`, `PIP.COM`) execute and produce expected output.

### 6.7 Phase 6 — Polish and edge cases (1-2 weekends)

- Handle CP/M warm-boot correctly
- Handle Apple //e auxiliary memory if the host is a //e (Z-80 should see only main bank)
- Validate against multiple CP/M applications (WordStar, dBase II, MBASIC)
- Handle clock divisor / timing-loop differences if any application is sensitive
- Document the slot port and any A2FPGA-specific extensions

### 6.8 Total effort estimate

| Phase | Scope | Estimate |
|---|---|---|
| 0 | Bridge verification | 1-2 evenings |
| 1 | Bus-master scaffolding | 1 weekend |
| 2 | Z-80 core integration | 1 weekend |
| 3 | Memory routing | 1 weekend |
| 4 | Slot interface | 1-2 evenings |
| 5 | First CP/M boot | 1 weekend |
| 6 | Polish | 1-2 weekends |
| **Total to first reliable boot** | | **~3-4 weekends** |
| **Total with polish** | | **~5-6 weekends** |

---

## 7. Software stack and boot flow

### 7.1 Boot sequence

1. **Apple II powers on.** Slot ROMs scan; the SoftCard's slot expansion ROM at `$Cn00` is recognized as the first bootable slot if the user has selected it (`PR#n`), or via direct command.
2. **6502 boot stub** in the slot ROM:
   - Reads boot sector from physical Apple Disk II
   - Boots into the SoftCard CP/M loader (a 6502 program embedded on the CP/M boot disk)
3. **CP/M loader** loads CCP, BDOS, and BIOS into the right Apple addresses (which appear at the right Z-80 addresses after the swap).
4. **CP/M loader writes `0x01` to `$C0n0`**, asserting Z-80 enable.
5. **`softcard.sv`**:
   - Asserts DMA
   - Resets Z-80
   - Releases Z-80 reset; Z-80 begins fetching from its `$0000` (the post-swap Apple address)
6. **CP/M runs.** Console output from CP/M goes through the standard SoftCard BIOS path:
   - Z-80 calls BIOS CONOUT
   - BIOS writes 0x00 to `$C0n0` to disable Z-80, releasing DMA
   - 6502 resumes, executes the SoftCard's "I/O dispatch" routine (also in Apple RAM)
   - The 6502 routine outputs the character via Apple monitor's COUT, which goes through the Videoterm in slot 3
   - 6502 writes 0x01 back to `$C0n0` to resume Z-80
7. **Disk I/O follows the same pattern**: Z-80 yields, 6502 services the disk via Apple's RWTS, returns control.

### 7.2 What needs to be on the CP/M boot disk

We don't write any CP/M software for this. The SoftCard CP/M 2.23+ disk in `docs/SoftCard CP-M Disk Images/CPMV233.DSK` already contains:
- The 6502 boot stub in the boot sector
- The 6502 I/O dispatch handler (loaded into Apple memory at boot)
- CP/M CCP and BDOS
- The SoftCard-specific BIOS (which talks to the SoftCard hardware via `$C0n0`)

If our hardware emulation is faithful to the real SoftCard's slot-port behavior (Z-80 enable/disable via bit 0 of `$C0n0`), this disk boots **with no software changes**.

### 7.3 What we don't need to build

- ❌ Z-80 BIOS (already on the boot disk)
- ❌ CP/M kernel (BDOS) (already on the boot disk)
- ❌ Disk virtualization / SD-card layer (real Apple Disk II handles disk I/O)
- ❌ Console code (Apple firmware + Videoterm handle it)
- ❌ Any CP/M application porting

---

## 8. Risks and unknowns

### 8.1 Bridge IC behavior (covered in Phase 0)

The two unverified bridge behaviors (V1, V2) are the largest single risk. Phase 0 is explicitly structured to find out before committing further effort.

### 8.2 Apple DRAM refresh

The Apple II's video circuitry handles DRAM refresh on alternate phi cycles. While DMA is asserted, the 6502 is halted but the video circuit continues operating. **The Apple's DRAM should refresh normally**, since refresh is video-driven, not 6502-driven. This is the same situation the real SoftCard ran in for years — there's no known refresh issue on the real card.

### 8.3 Bus-master cycle timing

If the bridge's `IO_WRITE_ADDR` + `IO_WRITE_DATA` round-trip exceeds one Apple phi half-cycle (~490 ns), bus-mastered transactions might span phi boundaries, which could conflict with the video circuitry's phi1 access. The current bridge measurement (~185 ns per transaction) gives plenty of margin, but Phase 1 should validate at speed with a scope or timing analyzer.

### 8.4 Apple //e auxiliary memory

The real SoftCard supports only the main 64 KB bank. If the host is a //e or //gs, the Z-80 must not bus-master into auxiliary RAM. The `m2sel_n` and `m2b0` signals in `a2bus_if` should be held in the appropriate state during bus-mastered cycles. This is a small implementation detail, not a feasibility risk.

### 8.5 SoftCard CP/M's exact port behavior

The plan assumes the SoftCard's `$C0n0` write semantics are exactly bit 0 = Z-80 enable. The real schematic should be consulted to confirm — there may be additional bits or an inverted polarity convention. Worst case: minor BIOS-level adjustment, or a small wrapper in the slot expansion ROM that translates A2FPGA's port bits to what the disk expects.

### 8.6 Scope creep

Apple-side software that uses unusual entry points (CP/M binaries that probe for the SoftCard, disk-format software that calls hardware-specific routines) may surface edge cases. The phase 6 budget exists for this. CP/M is otherwise hardware-portable by design.

---

## 9. Alternative: Appli-Card-style co-processor (fallback if §3.3 fails)

If bridge verification (V1 or V2) fails, the SoftCard plan is infeasible on the existing hardware. The fallback is an **Appli-Card-style co-processor** that doesn't require bus-mastering:

### 9.1 Architecture

- Z-80 core in FPGA with **its own private 64 KB RAM** in SDRAM (no Apple bus access at all for normal execution)
- 6502 sees a slot card that exposes:
  - A command/status register
  - A data port for byte-at-a-time transfer between 6502 and Z-80
  - An IRQ for "Z-80 needs attention"
- Custom CP/M BIOS on the Z-80 side that uses the data port for all I/O (console, disk)
- 6502-side dispatch program that handles incoming requests:
  - Disk reads/writes via SD-card-stored disk images (requires building SD-card infrastructure)
  - Console I/O via Apple firmware + Videoterm

### 9.2 Cost vs. SoftCard path

| Item | SoftCard path | Appli-Card path |
|---|---|---|
| Bridge V1/V2 needed | Yes | No |
| Z-80 core | Same | Same |
| Bus-master controller | Yes (~300 LUTs) | No |
| SD-card infrastructure | No (uses real disk) | **Yes (~1,500 LUTs + firmware effort)** |
| BIOS porting | No (use stock SoftCard BIOS) | **Yes (~2 KB Z-80 code, ~1-2 weekends)** |
| Boot from existing CP/M disks | Yes | No (need to re-master) |
| Total effort | ~3-4 weekends | ~6-8 weekends |

### 9.3 When to choose Appli-Card path

- V1 or V2 fails verification
- You want CP/M to work without depending on a real Apple Disk II being present
- You want to ship pre-loaded CP/M images on SD card for "just plug in and run"

The Appli-Card path is intrinsically cleaner (no bus contention, no DMA complexity) but loses the elegance of "real CP/M disks just work."

---

## 10. Recommendation

1. **Schedule Phase 0** (bridge verification) within the next development cycle. Two evenings of work answers the binary go/no-go question.
2. **If Phase 0 succeeds**, commit to the SoftCard path. Disable SuperSprite/F18A in `top.sv` to free BSRAM headroom (no CP/M user will miss it). Pursue Phases 1-6 over ~5-6 weekends.
3. **If Phase 0 fails**, switch to the Appli-Card path described in §9. Plan for ~6-8 weekends including SD-card disk infrastructure.
4. **Either way**, the existing SoftCard CP/M disk archive (`docs/SoftCard CP-M Disk Images/`) is the reference for both BIOS structure and software validation.

The single largest source of remaining uncertainty is the bridge IC's actual capability. Resolving that uncertainty is cheap, fast, and decisive for the rest of the plan. Everything downstream of Phase 0 is normal HDL development against a known set of resources and a well-understood reference architecture.

---

## Appendix A — Reference materials

- [Microsoft SoftCard CP/M Disk Images](SoftCard%20CP-M%20Disk%20Images/) — full release history (2.20 → 2.28B), with version 2.23 being the first firmware-card-aware release
- [Pausch Apple CP/M reference](http://stjarnhimlen.se/apple2/Apple.CPM.ref.txt) — narrative on the 2.20B → 2.23 firmware-card fix
- [Apple II Pascal 1.1 ATTACH-BIOS spec](https://mirrors.apple2.org.za/ftp.apple.asimov.net/documentation/programming/pascal/Apple%20II%20Pascal%20ATTACH.pdf) — the firmware-card protocol that 2.23 honors and the Videoterm implements
- [`hdl/videx/Videx Videoterm ROM 2.4.asm`](../hdl/videx/Videx%20Videoterm%20ROM%202.4.asm) — example of a Pascal-1.1-compliant firmware card already running on the A2FPGA
- [`boards/a2n20v2/hdl/bus/apple_bus.sv`](../boards/a2n20v2/hdl/bus/apple_bus.sv) — current bridge protocol implementation
- [`boards/a2n20v2/impl/pnr/a2n20v2.rpt.txt`](../boards/a2n20v2/impl/pnr/a2n20v2.rpt.txt) — current resource utilization (source of all numbers in §4)

## Appendix B — Open-source Z-80 cores under consideration

| Core | Language | License | Typical resource use | Notes |
|---|---|---|---|---|
| **T80** (Daniel Wallner) | VHDL | GPL/Modified BSD | ~1,500 LUTs | Most-used in retro FPGA projects; mature |
| **TV80** (Guy Hutchison) | Verilog | BSD-style | ~1,800 LUTs | Verilog-native; cycle-accurate option |
| **NextZ80** (Nick Glazzard) | Verilog | MIT | ~2,500 LUTs | Higher max clock; more aggressive pipelining |
| **A-Z80** (Goran Devic) | Verilog | GPL | ~3,500 LUTs | Microcoded, cycle-accurate, larger but more accurate |

Recommended: **T80** for the first iteration. Mature, smallest, well-tested with Z-80 software stacks including CP/M.
