#!/bin/bash
#
# Prepare source files for OSS toolchain build of A2N20v2
#
# Copies HDL sources into a build directory and applies patches needed
# for compatibility with the open-source Gowin FPGA toolchain:
#   Yosys (+ GHDL + slang plugins) + nextpnr-himbaechel + gowin_pack
#
# Usage: ./prepare_build.sh [BUILD_DIR]
#   BUILD_DIR defaults to /tmp/a2n20v2_build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOARD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$BOARD_DIR/../.." && pwd)"
BUILD_DIR="${1:-/tmp/a2n20v2_build}"

echo "=== A2N20v2 OSS Build Preparation ==="
echo "Repo root:  $REPO_ROOT"
echo "Board dir:  $BOARD_DIR"
echo "Build dir:  $BUILD_DIR"

# Clean and create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"/{hdl,board_hdl,stubs}

# ===== Copy source files =====
echo "Copying HDL sources..."
cp -r "$REPO_ROOT/hdl/"* "$BUILD_DIR/hdl/"
cp -r "$BOARD_DIR/hdl/"* "$BUILD_DIR/board_hdl/"

# Copy stubs
cp "$SCRIPT_DIR/stubs/"*.sv "$BUILD_DIR/stubs/"

# ===== Generate build timestamp =====
echo "Generating datetime.svh..."
DATETIME=$(date +"%Y%m%d%H%M%S")
cat > "$BUILD_DIR/board_hdl/datetime.svh" << SVHEOF
// Generated build timestamp
\`define BUILD_DATETIME "$DATETIME"
SVHEOF

# ===== Apply patches =====
echo "Applying OSS toolchain patches..."

# --- 1. Strip endinterface labels (not supported by slang frontend) ---
echo "  [1/6] Stripping endinterface labels..."
find "$BUILD_DIR" -name "*.sv" -exec \
    sed -i 's/endinterface:[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*/endinterface/g' {} +

# --- 2. Remove modport imports from a2bus_if.sv ---
echo "  [2/6] Fixing a2bus_if.sv modport imports..."
sed -i '/^[[:space:]]*import io_select_n,$/d' "$BUILD_DIR/hdl/bus/a2bus_if.sv"
sed -i '/^[[:space:]]*import dev_select_n,$/d' "$BUILD_DIR/hdl/bus/a2bus_if.sv"
sed -i '/^[[:space:]]*import io_strobe_n$/d'   "$BUILD_DIR/hdl/bus/a2bus_if.sv"
# Remove trailing comma from control_reset_n line (now last in modport)
sed -i 's/input control_reset_n,$/input control_reset_n/' "$BUILD_DIR/hdl/bus/a2bus_if.sv"

# --- 3. Fix forward references (slang single-pass requirement) ---
echo "  [3/6] Fixing forward references..."

# YM2149.sv: move ymreg declaration before first use
python3 - "$BUILD_DIR/hdl/support/YM2149.sv" << 'PYEOF'
import sys
with open(sys.argv[1], 'r') as f:
    lines = f.readlines()
# Find and remove 'reg [7:0] ymreg[16];' from its original location
ymreg_line = None
ymreg_idx = None
for i, line in enumerate(lines):
    if 'reg [7:0] ymreg[16]' in line and 'assign' not in line:
        ymreg_line = line
        ymreg_idx = i
        break
if ymreg_idx is not None:
    del lines[ymreg_idx]
    # Insert before first use of ymreg (assign ACTIVE = ~ymreg...)
    for i, line in enumerate(lines):
        if 'ymreg' in line and 'assign' in line:
            lines.insert(i, ymreg_line)
            break
# Move 'assign DO = dout;' after dout declaration
do_line = None
do_idx = None
for i, line in enumerate(lines):
    if 'assign DO = dout' in line:
        do_line = line
        do_idx = i
        break
if do_idx is not None:
    del lines[do_idx]
    for i, line in enumerate(lines):
        if 'reg [7:0] dout' in line:
            lines.insert(i + 1, do_line)
            break
with open(sys.argv[1], 'w') as f:
    f.writelines(lines)
PYEOF

# super_serial_card.sv: move assign irq_n_o after wire SER_IRQ declaration
python3 - "$BUILD_DIR/hdl/ssc/super_serial_card.sv" << 'PYEOF'
import sys
with open(sys.argv[1], 'r') as f:
    lines = f.readlines()
irq_line = None
irq_idx = None
for i, line in enumerate(lines):
    if 'assign irq_n_o' in line and 'SER_IRQ' in line:
        irq_line = line
        irq_idx = i
        break
if irq_idx is not None:
    del lines[irq_idx]
    for i, line in enumerate(lines):
        if 'wire SER_IRQ' in line:
            lines.insert(i + 1, irq_line)
            break
with open(sys.argv[1], 'w') as f:
    f.writelines(lines)
PYEOF

# iir_filter.v: move declarations before first use
python3 - "$BUILD_DIR/hdl/support/iir_filter.v" << 'PYEOF'
import sys
with open(sys.argv[1], 'r') as f:
    lines = f.readlines()

def move_line_before(lines, search_str, target_str):
    """Remove line containing search_str and insert it before line containing target_str."""
    src_idx = None
    src_line = None
    for i, line in enumerate(lines):
        if search_str in line:
            src_idx = i
            src_line = line
            break
    if src_idx is None:
        return lines
    lines.pop(src_idx)
    for i, line in enumerate(lines):
        if target_str in line:
            lines.insert(i, src_line)
            break
    return lines

# In iir_filter module: move 'reg [15:0] inp, inp_m;' before '$signed(inp)'
lines = move_line_before(lines, 'reg [15:0] inp, inp_m;', '$signed(inp)')
# In iir_filter module: move 'wire [39:0] tap0;' before 'tap0'
lines = move_line_before(lines, 'wire [39:0] tap0;', 'tap0')
# In iir_filter_tap module: move 'reg  [39:0] x1, y;' before 'wire [39:0] y1'
lines = move_line_before(lines, 'reg  [39:0] x1, y;', 'wire [39:0] y1')

with open(sys.argv[1], 'w') as f:
    f.writelines(lines)
PYEOF

# --- 4. Fix blocking assignments in sequential blocks ---
echo "  [4/6] Fixing blocking assignments in sequential blocks..."

# hdmi.sv: control_data = -> control_data <= (only in always block, not declaration)
sed -i 's/^\([[:space:]]\{16,\}\)control_data = 6'\''d0;/\1control_data <= 6'\''d0;/' "$BUILD_DIR/hdl/hdmi/hdmi.sv"

# packet_picker.sv: frame_counter blocking -> non-blocking
python3 - "$BUILD_DIR/hdl/hdmi/packet_picker.sv" << 'PYEOF'
import sys
with open(sys.argv[1], 'r') as f:
    content = f.read()
content = content.replace(
    "frame_counter = frame_counter + 8'd4;\n",
    "frame_counter <= frame_counter + 8'd4;\n"
)
content = content.replace(
    "if (frame_counter >= 8'd192)\n",
    "if (frame_counter + 8'd4 >= 8'd192)\n"
)
content = content.replace(
    "frame_counter = frame_counter - 8'd192;",
    "frame_counter <= frame_counter + 8'd4 - 8'd192;"
)
with open(sys.argv[1], 'w') as f:
    f.write(content)
PYEOF

# apple_bus.sv: io_state/next_io_state blocking -> non-blocking in reset
# Only target lines inside always block (indented), not reg declarations
sed -i 's/^\([[:space:]]\{12,\}\)io_state = IO_INIT;/\1io_state <= IO_INIT;/' "$BUILD_DIR/board_hdl/bus/apple_bus.sv"
sed -i 's/^\([[:space:]]\{12,\}\)next_io_state = IO_IDLE;/\1next_io_state <= IO_IDLE;/' "$BUILD_DIR/board_hdl/bus/apple_bus.sv"

# --- 5. Replace ELVDS_TBUF with TLVDS_OBUF in top.sv ---
echo "  [5/6] Replacing ELVDS_TBUF with TLVDS_OBUF in top.sv..."
sed -i 's|// Gowin LVDS output buffer|// TLVDS_OBUF for OSS toolchain (per Apicula DVI example)|' "$BUILD_DIR/board_hdl/top.sv"
sed -i 's/ELVDS_TBUF tmds_bufds/TLVDS_OBUF tmds_bufds/' "$BUILD_DIR/board_hdl/top.sv"
# Remove .OEN line and fix trailing comma on .OB line
sed -i '/\.OEN(sleep_w && HDMI_SLEEP_ENABLE)/d' "$BUILD_DIR/board_hdl/top.sv"
sed -i 's/\.OB({tmds_clk_n, tmds_d_n}),$/\.OB({tmds_clk_n, tmds_d_n})/' "$BUILD_DIR/board_hdl/top.sv"

# --- 6. Fix VHDL array bound in f18a_sprites.vhd ---
echo "  [6/6] Fixing f18a_sprites.vhd array bound..."
sed -i 's/type sprite_line_buffer is array (0 to 2\*\*ADDR_WIDTH-1) of/type sprite_line_buffer is array (0 to 511) of/' "$BUILD_DIR/hdl/f18a/f18a_sprites.vhd"

# ===== Write OSS-compatible constraints =====
echo "Writing OSS constraints..."
cp "$BOARD_DIR/hdl/a2n20v2.cst" "$BUILD_DIR/board_hdl/a2n20v2.cst"
# Rewrite HDMI section for nextpnr-himbaechel compatibility
python3 - "$BUILD_DIR/board_hdl/a2n20v2.cst" << 'PYEOF'
import sys
with open(sys.argv[1], 'r') as f:
    content = f.read()

# Replace the Gowin IDE differential pair format with separate P/N entries
old_hdmi = '''// Nano 20K HDMI

IO_LOC "tmds_clk_p" 33,34;
IO_PORT "tmds_clk_p" IO_TYPE=LVCMOS33D PULL_MODE=NONE DRIVE=8;

IO_LOC "tmds_d_p[0]" 35,36;
IO_PORT "tmds_d_p[0]" IO_TYPE=LVCMOS33D PULL_MODE=NONE DRIVE=8;

IO_LOC "tmds_d_p[1]" 37,38;
IO_PORT "tmds_d_p[1]" IO_TYPE=LVCMOS33D PULL_MODE=NONE DRIVE=8;

IO_LOC "tmds_d_p[2]" 39,40;
IO_PORT "tmds_d_p[2]" IO_TYPE=LVCMOS33D PULL_MODE=NONE DRIVE=8;'''

new_hdmi = '''// Nano 20K HDMI (OSS toolchain: separate P/N entries, no IO_TYPE for diff)

IO_LOC "tmds_clk_p" 33;
IO_PORT "tmds_clk_p" PULL_MODE=NONE;
IO_LOC "tmds_clk_n" 34;
IO_PORT "tmds_clk_n" PULL_MODE=NONE;

IO_LOC "tmds_d_p[0]" 35;
IO_PORT "tmds_d_p[0]" PULL_MODE=NONE;
IO_LOC "tmds_d_n[0]" 36;
IO_PORT "tmds_d_n[0]" PULL_MODE=NONE;

IO_LOC "tmds_d_p[1]" 37;
IO_PORT "tmds_d_p[1]" PULL_MODE=NONE;
IO_LOC "tmds_d_n[1]" 38;
IO_PORT "tmds_d_n[1]" PULL_MODE=NONE;

IO_LOC "tmds_d_p[2]" 39;
IO_PORT "tmds_d_p[2]" PULL_MODE=NONE;
IO_LOC "tmds_d_n[2]" 40;
IO_PORT "tmds_d_n[2]" PULL_MODE=NONE;'''

content = content.replace(old_hdmi, new_hdmi)
with open(sys.argv[1], 'w') as f:
    f.write(content)
PYEOF

echo "=== Build preparation complete ==="
echo "Build directory: $BUILD_DIR"
echo ""
echo "Next steps:"
echo "  1. yosys -m ghdl -m slang build.ys"
echo "  2. nextpnr-himbaechel --device GW2AR-LV18QN88C8/I7 \\"
echo "       --chipdb .../chipdb-GW2A-18C.bin \\"
echo "       --vopt family=GW2A-18C \\"
echo "       --vopt cst=$BUILD_DIR/board_hdl/a2n20v2.cst \\"
echo "       --json a2n20v2.json --write a2n20v2_pnr.json"
echo "  3. gowin_pack -d GW2AR-18C -o a2n20v2.fs a2n20v2_pnr.json"
