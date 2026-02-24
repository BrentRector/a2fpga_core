#!/usr/bin/env python3
#
# Copyright (c) 2026 Brent Rector
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.
#
"""
Convert a Videx VideoTerm character ROM binary dump to hex format for
SystemVerilog $readmemh.

The character ROM data was captured from a physical Videx VideoTerm adapter.
The ROM contains 256 characters x 16 scanlines = 4096 bytes:
  - Chars 0x00-0x7F: normal characters (2048 bytes)
  - Chars 0x80-0xFF: inverse characters (2048 bytes, pre-inverted pixels)

Note: The A2FPGA implementation uses character ROM halving — only the first
2048 bytes (chars 0x00-0x7F) are loaded into BSRAM. Chars 0x80-0xFF are
generated at runtime by XOR inversion of the normal characters, saving one
BSRAM block. The full 4096-byte hex file is kept for reference.

Output: hdl/video/videx_charrom.hex (4096 lines, one byte per line, two hex digits)
  Loaded in SystemVerilog with: $readmemh("videx_charrom.hex", videxrom_r, 0)

Usage:
  python tools/gen_videx_rom.py <binary_rom_file>

If no argument is given, verifies the existing hex file.
"""

import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "hdl", "video")
OUTPUT_FILE = os.path.join(OUTPUT_DIR, "videx_charrom.hex")

EXPECTED_SIZE = 4096  # 256 characters * 16 scanlines


def convert_binary_to_hex(rom_path: str):
    """Convert a binary ROM dump to hex file."""
    with open(rom_path, "rb") as f:
        data = f.read()

    if len(data) != EXPECTED_SIZE:
        print(
            f"ERROR: ROM file is {len(data)} bytes, expected {EXPECTED_SIZE}",
            file=sys.stderr,
        )
        sys.exit(1)

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    with open(OUTPUT_FILE, "w") as f:
        for byte_val in data:
            f.write(f"{byte_val:02X}\n")

    print(f"Written: {OUTPUT_FILE}")
    print(f"Lines:   {len(data)}")
    print("Done.")


def verify_hex():
    """Verify the existing hex file."""
    if not os.path.exists(OUTPUT_FILE):
        print(f"ERROR: {OUTPUT_FILE} not found", file=sys.stderr)
        sys.exit(1)

    with open(OUTPUT_FILE, "r") as f:
        lines = [line.strip() for line in f if line.strip()]

    if len(lines) != EXPECTED_SIZE:
        print(
            f"ERROR: Hex file has {len(lines)} lines, expected {EXPECTED_SIZE}",
            file=sys.stderr,
        )
        sys.exit(1)

    # Verify all lines are valid 2-digit hex
    for i, line in enumerate(lines):
        try:
            val = int(line, 16)
            if val < 0 or val > 255:
                raise ValueError
        except ValueError:
            print(f"ERROR: Invalid hex value at line {i + 1}: '{line}'", file=sys.stderr)
            sys.exit(1)

    # Verify inverse characters match normal characters (halving property)
    mismatches = 0
    for char in range(128):
        for scanline in range(16):
            normal_idx = char * 16 + scanline
            inverse_idx = (char + 128) * 16 + scanline
            normal_val = int(lines[normal_idx], 16)
            inverse_val = int(lines[inverse_idx], 16)
            expected_inverse = normal_val ^ 0x7F  # Invert all 7 pixel bits
            if inverse_val != expected_inverse:
                mismatches += 1

    print(f"Hex file: {OUTPUT_FILE}")
    print(f"Lines:    {len(lines)}")
    print(f"Chars:    {len(lines) // 16} (128 normal + 128 inverse)")
    if mismatches == 0:
        print("Halving:  VERIFIED (inverse chars = normal XOR 0x7F)")
    else:
        print(f"Halving:  {mismatches} mismatches (inverse chars differ from XOR 0x7F)")
    print("OK.")


def main():
    if len(sys.argv) > 1:
        convert_binary_to_hex(sys.argv[1])
    else:
        print("Verifying existing Videx character ROM hex file...")
        verify_hex()


if __name__ == "__main__":
    main()
