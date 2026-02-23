#!/usr/bin/env python3
"""
Generate Videx character ROM hex file for use with SystemVerilog $readmemh.

Fetches (or reads locally cached) Videx character ROM data from the A2DVI
firmware project and combines normal + inverse character sets into a single
4096-byte hex file.

Source: https://github.com/ThorstenBr/A2DVI-Firmware
  - firmware/fonts/videx/videx_normal.c  (chars 0x00-0x7F, 2048 bytes)
  - firmware/fonts/videx/videx_inverse.c (chars 0x80-0xFF, 2048 bytes, pre-inverted)

Output: videx_charrom.hex (4096 lines, one byte per line, two hex digits)
  Loaded in SystemVerilog with: $readmemh("videx_charrom.hex", videxrom_r, 0)
"""

import os
import re
import sys
import urllib.request
import urllib.error

GITHUB_BASE = (
    "https://raw.githubusercontent.com/ThorstenBr/A2DVI-Firmware/master/"
    "firmware/fonts/videx/"
)

SOURCES = [
    ("videx_normal.c", "normal"),
    ("videx_inverse.c", "inverse"),
]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CACHE_DIR = os.path.join(SCRIPT_DIR, ".cache")
OUTPUT_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "hdl", "video")
OUTPUT_FILE = os.path.join(OUTPUT_DIR, "videx_charrom.hex")

EXPECTED_BYTES_PER_FILE = 2048  # 128 characters * 16 bytes each
BINARY_PATTERN = re.compile(r"0b([01]{8})")


def fetch_or_read(filename: str) -> str:
    """Fetch a C source file from GitHub, caching locally."""
    os.makedirs(CACHE_DIR, exist_ok=True)
    cache_path = os.path.join(CACHE_DIR, filename)

    # Try to read from cache first
    if os.path.exists(cache_path):
        print(f"  Reading cached: {cache_path}")
        with open(cache_path, "r") as f:
            return f.read()

    # Fetch from GitHub
    url = GITHUB_BASE + filename
    print(f"  Fetching: {url}")
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read().decode("utf-8")
        # Cache for future runs
        with open(cache_path, "w") as f:
            f.write(data)
        print(f"  Cached to: {cache_path}")
        return data
    except urllib.error.URLError as e:
        print(f"  ERROR: Failed to fetch {url}: {e}", file=sys.stderr)
        sys.exit(1)


def parse_binary_values(source: str, label: str) -> list[int]:
    """Extract all 0bNNNNNNNN binary byte values from C source text."""
    values = []
    for match in BINARY_PATTERN.finditer(source):
        values.append(int(match.group(1), 2))

    if len(values) != EXPECTED_BYTES_PER_FILE:
        print(
            f"  WARNING: {label} has {len(values)} values, "
            f"expected {EXPECTED_BYTES_PER_FILE}",
            file=sys.stderr,
        )
        if len(values) == 0:
            print(f"  ERROR: No binary values found in {label}", file=sys.stderr)
            sys.exit(1)

    return values


def main():
    print("Generating Videx character ROM hex file...")
    print()

    all_bytes = []

    for filename, label in SOURCES:
        print(f"Processing {label} ROM ({filename}):")
        source = fetch_or_read(filename)
        values = parse_binary_values(source, label)
        print(f"  Parsed {len(values)} bytes")
        all_bytes.extend(values)

    total = len(all_bytes)
    expected_total = EXPECTED_BYTES_PER_FILE * 2
    print()
    print(f"Total bytes: {total} (expected {expected_total})")

    if total != expected_total:
        print(f"ERROR: Byte count mismatch!", file=sys.stderr)
        sys.exit(1)

    # Write hex file
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    with open(OUTPUT_FILE, "w") as f:
        for byte_val in all_bytes:
            f.write(f"{byte_val:02X}\n")

    print(f"Written: {OUTPUT_FILE}")
    print(f"Lines:   {total}")
    print("Done.")


if __name__ == "__main__":
    main()
