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
Regenerate Videx character set ROMs from Unicode glyphs.

Modes:
  visualize <hex_file>                  Show all 128 chars as ASCII art grid
  compare <hex1> <hex2>                 Side-by-side comparison of two charrom files
  render <font> <output.hex> [options]  Render APL charrom from TrueType font
  candidates <font> [options]           Show all rendering strategies per character
  mapping                               Print the Unicode mapping table

The character ROM format is 128 characters x 16 scanlines = 2048 bytes.
Only scanlines 0-8 are displayed (9-scanline character cells); 9-15 are padding.
Each byte is bit-reversed: bit 0 = leftmost pixel (FPGA LSB-first pipeline).
Characters 0x80-0xFF are inverse of 0x00-0x7F, generated at runtime by XOR.

Usage:
  python tools/gen_charrom_from_unicode.py visualize hdl/videx/charsets/videx_charrom_apl.hex
  python tools/gen_charrom_from_unicode.py compare original.hex regenerated.hex
  python tools/gen_charrom_from_unicode.py render path/to/font.ttf output.hex [--original=original.hex]
  python tools/gen_charrom_from_unicode.py candidates path/to/font.ttf [--original=original.hex]
  python tools/gen_charrom_from_unicode.py mapping
"""

import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)

CHARS_PER_ROM = 128
SCANLINES_PER_CHAR = 16
DISPLAYED_SCANLINES = 9
CHAR_WIDTH = 8
ROM_SIZE = CHARS_PER_ROM * SCANLINES_PER_CHAR  # 2048

# Sentinel value: copy this character from the original ROM instead of rendering
COPY_ORIGINAL = "COPY"


# ============================================================================
# APL Unicode Mapping Table — Tek4010/Videx APL encoding
# ============================================================================
#
# The Videx APL character ROM encoding was verified against the rricharz/Tek4010
# emulator (tube.c), which uses the same Tektronix 4010/4014 APL character
# encoding. Positions 0x20-0x3F and 0x40-0x5B match the Tek4010 mapping exactly.
# Positions 0x5C, 0x5E, 0x5F, 0x7C, 0x7E diverge — these use the Videx-specific
# glyphs as seen in the original ROM visualization.
#
# Character ranges:
#   0x00-0x07: Block elements (horizontal thirds, binary combinations)
#              — same as standard Videx charrom, not APL-specific.
#   0x08-0x0F: APL compound/overstrike characters (grade-up, grade-down, etc.)
#              — complex multi-glyph overlays, best kept from original ROM.
#   0x10-0x1F: Box-drawing line segments (vertical + horizontal combinations)
#              — same as standard Videx charrom, not APL-specific.
#   0x20-0x3F: APL primitives (operators, functions, punctuation)
#   0x40-0x5F: APL function symbols (overbar, alpha, floor, iota, etc.)
#   0x60-0x7A: Diamond separator + uppercase letters A-Z
#   0x7B-0x7F: Extended APL symbols (braces, backslash-bar, etc.)
#
# Entries with COPY_ORIGINAL will be copied from the original ROM file
# rather than rendered from a font. This is used for block elements,
# line-drawing characters, and complex overstrike glyphs that have no
# single Unicode equivalent or won't render cleanly at 8x9 pixels.

APL_MAP = {
    # 0x00-0x07: Block elements — horizontal thirds in binary combinations
    # bit 0 = top third, bit 1 = middle third, bit 2 = bottom third
    0x00: COPY_ORIGINAL,   # blank (000)
    0x01: COPY_ORIGINAL,   # top third filled (001)
    0x02: COPY_ORIGINAL,   # middle third filled (010)
    0x03: COPY_ORIGINAL,   # top + middle filled (011)
    0x04: COPY_ORIGINAL,   # bottom third filled (100)
    0x05: COPY_ORIGINAL,   # top + bottom filled (101)
    0x06: COPY_ORIGINAL,   # middle + bottom filled (110)
    0x07: COPY_ORIGINAL,   # all filled (111)

    # 0x08-0x0F: APL compound characters (overstrikes)
    # These are multi-glyph combinations rendered as single characters.
    # Cannot be cleanly generated from single Unicode codepoints.
    0x08: COPY_ORIGINAL,   # compound APL symbol
    0x09: COPY_ORIGINAL,   # compound APL symbol
    0x0A: COPY_ORIGINAL,   # compound APL symbol
    0x0B: COPY_ORIGINAL,   # compound APL symbol
    0x0C: COPY_ORIGINAL,   # compound APL symbol
    0x0D: COPY_ORIGINAL,   # compound APL symbol
    0x0E: COPY_ORIGINAL,   # compound APL symbol
    0x0F: COPY_ORIGINAL,   # compound APL symbol

    # 0x10-0x1F: Box-drawing line segments
    # Combinations of center vertical bar and horizontal/corner segments
    0x10: COPY_ORIGINAL,   # blank
    0x11: COPY_ORIGINAL,   # vertical bar center
    0x12: COPY_ORIGINAL,   # horizontal right half
    0x13: COPY_ORIGINAL,   # vertical + horizontal right
    0x14: COPY_ORIGINAL,   # vertical bottom half
    0x15: COPY_ORIGINAL,   # vertical bar + bottom half
    0x16: COPY_ORIGINAL,   # horizontal right + bottom vertical
    0x17: COPY_ORIGINAL,   # T-junction right-down
    0x18: COPY_ORIGINAL,   # horizontal left half
    0x19: COPY_ORIGINAL,   # vertical + horizontal left
    0x1A: COPY_ORIGINAL,   # horizontal full
    0x1B: COPY_ORIGINAL,   # vertical + horizontal full (cross)
    0x1C: COPY_ORIGINAL,   # vertical top half + horizontal left
    0x1D: COPY_ORIGINAL,   # vertical top + bar + horizontal left
    0x1E: COPY_ORIGINAL,   # horizontal full + vertical bottom
    0x1F: COPY_ORIGINAL,   # full cross junction

    # 0x20-0x2F: APL primitive operators (Tek4010/Videx encoding)
    # Corrected from Tek4010 tube.c confirmed mapping
    0x20: 0x0020,      # SP   space
    0x21: 0x00A8,      # diaeresis (each operator)
    0x22: 0x0029,      # )    right parenthesis
    0x23: 0x003C,      # <    less than
    0x24: 0x2264,      # <=   less than or equal
    0x25: 0x003D,      # =    equals
    0x26: 0x003E,      # >    greater than
    0x27: 0x005D,      # ]    right bracket
    0x28: 0x2228,      # v    logical or (down caret)
    0x29: 0x2227,      # ^    logical and (up caret)
    0x2A: 0x2260,      # !=   not equal
    0x2B: 0x00F7,      # /    division
    0x2C: 0x002C,      # ,    comma (catenate/ravel)
    0x2D: 0x002B,      # +    plus
    0x2E: 0x002E,      # .    period (inner product)
    0x2F: 0x002F,      # /    slash (compress/reduce)

    # 0x30-0x39: Digits 0-9 — hand-designed pixel art, optimal as-is
    0x30: COPY_ORIGINAL,   # 0
    0x31: COPY_ORIGINAL,   # 1
    0x32: COPY_ORIGINAL,   # 2
    0x33: COPY_ORIGINAL,   # 3
    0x34: COPY_ORIGINAL,   # 4
    0x35: COPY_ORIGINAL,   # 5
    0x36: COPY_ORIGINAL,   # 6
    0x37: COPY_ORIGINAL,   # 7
    0x38: COPY_ORIGINAL,   # 8
    0x39: COPY_ORIGINAL,   # 9

    # 0x3A-0x3F: Punctuation (Tek4010/Videx encoding)
    0x3A: 0x0028,      # (    left parenthesis
    0x3B: 0x005B,      # [    left bracket
    0x3C: 0x003B,      # ;    semicolon
    0x3D: 0x00D7,      # x    multiplication sign
    0x3E: 0x003A,      # :    colon
    0x3F: 0x005C,      # \    backslash (expand/scan)

    # 0x40-0x4F: APL function symbols
    0x40: COPY_ORIGINAL,   # overbar — top-aligned bar, centering breaks it
    0x41: 0x237A,      # alpha (left argument)
    0x42: 0x22A5,      # up tack (decode / base)
    0x43: 0x2229,      # intersection (cap)
    0x44: 0x230A,      # floor (minimum)
    0x45: 0x220A,      # small element of (membership)
    0x46: COPY_ORIGINAL,   # underbar — unique APL glyph (two bars), no Unicode equiv
    0x47: 0x2207,      # del (nabla / function definition)
    0x48: 0x2206,      # delta (increment)
    0x49: 0x2373,      # iota (index generator)
    0x4A: 0x2218,      # jot (composition / outer product)
    0x4B: 0x0027,      # '    apostrophe (quote)
    0x4C: 0x2395,      # quad (I/O)
    0x4D: 0x007C,      # |    stile (absolute value / residue)
    0x4E: 0x22A4,      # down tack (encode / representation)
    0x4F: 0x25CB,      # circle (trigonometric functions)

    # 0x50-0x5F: APL function symbols
    0x50: 0x22C6,      # star operator (power)
    0x51: 0x003F,      # ?    question mark (roll / deal)
    0x52: 0x2374,      # rho (shape / reshape)
    0x53: 0x2308,      # ceiling (maximum)
    0x54: 0x223C,      # tilde (not / without)
    0x55: 0x2193,      # down arrow (drop)
    0x56: 0x222A,      # union (cup)
    0x57: 0x2375,      # omega (right argument)
    0x58: 0x2283,      # superset of (disclose / pick)
    0x59: 0x2191,      # up arrow (take / mix)
    0x5A: 0x2282,      # subset of (enclose / partition)
    0x5B: 0x2190,      # left arrow (assignment)
    0x5C: 0x005C,      # \    backslash (expand / scan)
    0x5D: 0x2192,      # right arrow (branch / abort)
    0x5E: 0x233D,      # circle stile (rotate / reverse)
    0x5F: COPY_ORIGINAL,   # reduce bar — horizontal bar glyph, not a slash char

    # 0x60: Diamond separator
    0x60: 0x22C4,      # diamond operator (statement separator)

    # 0x61-0x7A: Uppercase letters A-Z — hand-designed pixel art, optimal as-is
    0x61: COPY_ORIGINAL,   # A
    0x62: COPY_ORIGINAL,   # B
    0x63: COPY_ORIGINAL,   # C
    0x64: COPY_ORIGINAL,   # D
    0x65: COPY_ORIGINAL,   # E
    0x66: COPY_ORIGINAL,   # F
    0x67: COPY_ORIGINAL,   # G
    0x68: COPY_ORIGINAL,   # H
    0x69: COPY_ORIGINAL,   # I
    0x6A: COPY_ORIGINAL,   # J
    0x6B: COPY_ORIGINAL,   # K
    0x6C: COPY_ORIGINAL,   # L
    0x6D: COPY_ORIGINAL,   # M
    0x6E: COPY_ORIGINAL,   # N
    0x6F: COPY_ORIGINAL,   # O
    0x70: COPY_ORIGINAL,   # P
    0x71: COPY_ORIGINAL,   # Q
    0x72: COPY_ORIGINAL,   # R
    0x73: COPY_ORIGINAL,   # S
    0x74: COPY_ORIGINAL,   # T
    0x75: COPY_ORIGINAL,   # U
    0x76: COPY_ORIGINAL,   # V
    0x77: COPY_ORIGINAL,   # W
    0x78: COPY_ORIGINAL,   # X
    0x79: COPY_ORIGINAL,   # Y
    0x7A: COPY_ORIGINAL,   # Z

    # 0x7B-0x7F: Extended APL symbols
    0x7B: COPY_ORIGINAL,   # { left brace
    0x7C: COPY_ORIGINAL,   # backslash-bar (Videx-specific)
    0x7D: COPY_ORIGINAL,   # } right brace
    0x7E: COPY_ORIGINAL,   # delta-stile variant (Videx-specific)
    0x7F: COPY_ORIGINAL,   # horizontal bar (format line)
}


# ============================================================================
# ROM I/O and Bitmap Utilities
# ============================================================================

def read_hex_rom(path):
    """Read a .hex charrom file (2048 lines, one hex byte per line)."""
    with open(path, 'r') as f:
        lines = [line.strip() for line in f if line.strip()]
    if len(lines) != ROM_SIZE:
        print(f"ERROR: {path} has {len(lines)} lines, expected {ROM_SIZE}",
              file=sys.stderr)
        sys.exit(1)
    return [int(line, 16) for line in lines]


def get_char_bitmap(rom_data, char_code, scanlines=DISPLAYED_SCANLINES):
    """Extract bitmap for a character (list of bytes, one per scanline)."""
    offset = char_code * SCANLINES_PER_CHAR
    return rom_data[offset:offset + scanlines]


def byte_to_pixels(byte_val, width=CHAR_WIDTH):
    """Convert a byte to pixel string. Bit 0 = leftmost pixel."""
    return ''.join('#' if (byte_val >> bit) & 1 else '.' for bit in range(width))


def bitmap_from_rom(rom_data, char_code):
    """Extract a character bitmap from ROM data as a list of rows.

    Each row is a list of 0/1 values, CHAR_WIDTH wide.
    """
    offset = char_code * SCANLINES_PER_CHAR
    bitmap = []
    for sl in range(DISPLAYED_SCANLINES):
        byte_val = rom_data[offset + sl]
        row = [(byte_val >> bit) & 1 for bit in range(CHAR_WIDTH)]
        bitmap.append(row)
    return bitmap


def bitmap_to_bytes(bitmap):
    """Convert list-of-rows bitmap to list of bytes (bit 0 = leftmost pixel)."""
    result = []
    for row in bitmap:
        byte_val = 0
        for bit, px in enumerate(row):
            if px:
                byte_val |= (1 << bit)
        result.append(byte_val)
    return result


# ============================================================================
# Visualization and Comparison
# ============================================================================

def visualize_rom(rom_data, chars_per_row=16):
    """Display all 128 characters as an ASCII art grid."""
    num_rows = CHARS_PER_ROM // chars_per_row

    for row in range(num_rows):
        # Print character code header
        header = '     '
        for col in range(chars_per_row):
            char_code = row * chars_per_row + col
            header += f'  {char_code:02X}     '
        print(header)
        print('     ' + ('-' * 10 + ' ') * chars_per_row)

        # Print each scanline
        for scanline in range(DISPLAYED_SCANLINES):
            line = f'  {scanline}: '
            for col in range(chars_per_row):
                char_code = row * chars_per_row + col
                offset = char_code * SCANLINES_PER_CHAR + scanline
                byte_val = rom_data[offset]
                line += f' {byte_to_pixels(byte_val)}  '
            print(line)
        print()


def safe_symbol(char_code):
    """Get a printable ASCII-safe representation of the symbol at char_code."""
    mapping = APL_MAP.get(char_code)
    if mapping == COPY_ORIGINAL:
        return '(copy)'
    elif mapping is None:
        return '?'
    elif mapping < 0x80:
        return chr(mapping)
    else:
        return f'U+{mapping:04X}'


def compare_roms(rom1_data, rom2_data, label1="Original", label2="Regenerated"):
    """Side-by-side comparison of two charrom files."""
    diffs = 0
    total_pixel_diffs = 0
    for char_code in range(CHARS_PER_ROM):
        bm1 = get_char_bitmap(rom1_data, char_code)
        bm2 = get_char_bitmap(rom2_data, char_code)
        if bm1 != bm2:
            diffs += 1
            symbol = safe_symbol(char_code)
            print(f"=== 0x{char_code:02X} ({symbol}) ===")
            for i in range(DISPLAYED_SCANLINES):
                p1 = byte_to_pixels(bm1[i])
                p2 = byte_to_pixels(bm2[i])
                delta = ''
                pdiffs = 0
                for bit in range(CHAR_WIDTH):
                    b1 = (bm1[i] >> bit) & 1
                    b2 = (bm2[i] >> bit) & 1
                    if b1 != b2:
                        delta += '*'
                        pdiffs += 1
                    else:
                        delta += '.'
                total_pixel_diffs += pdiffs
                marker = ' <--' if pdiffs > 0 else ''
                print(f"  {p1}    {p2}    {delta}{marker}")
            print()

    total = CHARS_PER_ROM
    same = total - diffs
    print(f"Summary: {total} chars, {same} identical, {diffs} different, {total_pixel_diffs} pixel diffs")


# ============================================================================
# Multi-Strategy Rendering Pipeline
# ============================================================================
#
# Six rendering strategies are used to generate candidate bitmaps for each
# APL symbol. The best candidate is selected by a quality scoring function.
#
# Strategies:
#   mono      - FreeType monochrome hinting at 9ppem (mode='1')
#               Best for: axis-aligned stems, arrows, brackets
#   gray128   - Grayscale at 9ppem, threshold 128 (50%)
#               Best for: general purpose, balanced
#   gray96    - Grayscale at 9ppem, threshold 96 (37.5%)
#               Best for: thin curved features that need preserving
#   ss_mono   - 4x supersampled monochrome (36ppem), block-count >= 8
#               Best for: geometric shapes with clean edges
#   ss_gray128- 4x supersampled grayscale (36ppem), block-average >= 128
#               Best for: complex symbols with curves
#   ss_gray96 - 4x supersampled grayscale (36ppem), block-average >= 96
#               Best for: very thin features, detailed symbols

CANVAS_1X = 64     # Canvas size for native ppem rendering
CANVAS_4X = 256    # Canvas size for 4x supersample rendering
RENDER_PPEM_1X = 11   # Native size: slightly oversized to fill 8-wide cell
RENDER_PPEM_4X = 44   # 4x supersample: 4 * 11ppem

STRATEGY_NAMES = ['mono', 'gray128', 'gray96', 'ss_mono', 'ss_gray128', 'ss_gray96']


def _render_raw(font, char, pil_mode, canvas_size):
    """Render a glyph into a Pillow image.

    Returns (image, ink_bbox) or (None, None) if the glyph is missing.
    """
    from PIL import Image, ImageDraw

    img = Image.new(pil_mode, (canvas_size, canvas_size), 0)
    draw = ImageDraw.Draw(img)

    try:
        bbox = font.getbbox(char)
    except Exception:
        return None, None
    if bbox is None:
        return None, None

    glyph_w = bbox[2] - bbox[0]
    glyph_h = bbox[3] - bbox[1]
    if glyph_w == 0 and glyph_h == 0:
        return None, None

    # Center glyph in the canvas
    x = (canvas_size - glyph_w) // 2 - bbox[0]
    y = (canvas_size - glyph_h) // 2 - bbox[1]

    fill = 1 if pil_mode == '1' else 255
    draw.text((x, y), char, fill=fill, font=font)

    ink_bbox = img.getbbox()
    return img, ink_bbox


def _extract_centered(img, ink_bbox, cell_w, cell_h, threshold=None):
    """Extract ink from image and center in cell_w x cell_h grid.

    For mode='1' images, threshold should be None (pixels are already 0/255).
    For mode='L' images, threshold is the grayscale cutoff.

    Returns list of rows (cell_h x cell_w) of 0/1 values,
    or None if the ink doesn't fit in the cell.
    """
    if img is None or ink_bbox is None:
        return None

    cropped = img.crop(ink_bbox)
    iw, ih = cropped.size

    if iw > cell_w or ih > cell_h:
        return None  # Doesn't fit

    ox = (cell_w - iw) // 2
    oy = (cell_h - ih) // 2

    result = [[0] * cell_w for _ in range(cell_h)]
    for y in range(ih):
        for x in range(iw):
            px = cropped.getpixel((x, y))
            if threshold is not None:
                result[oy + y][ox + x] = 1 if px >= threshold else 0
            else:
                # mode='1': getpixel returns 0 or 255
                result[oy + y][ox + x] = 1 if px else 0

    return result


def _downsample_4x(img, ink_bbox, cell_w=8, cell_h=9, mode='average', threshold=128):
    """Downsample 4x rendered image to cell grid.

    Centers the ink in the output cell, then downsamples each 4x4 block.
    mode='count': count lit pixels in block, lit if count >= threshold
    mode='average': average intensity in block, lit if avg >= threshold

    Returns list of rows (cell_h x cell_w) of 0/1 values, or None.
    """
    if img is None or ink_bbox is None:
        return None

    target_4x_w = cell_w * 4   # 32
    target_4x_h = cell_h * 4   # 36

    # Center of ink in 4x space
    ink_cx = (ink_bbox[0] + ink_bbox[2]) / 2.0
    ink_cy = (ink_bbox[1] + ink_bbox[3]) / 2.0

    # Place ink center at output center: (cell_w/2, cell_h/2) -> 4x = (16, 18)
    x0 = int(round(ink_cx - target_4x_w / 2.0))
    y0 = int(round(ink_cy - target_4x_h / 2.0))

    w, h = img.size
    result = [[0] * cell_w for _ in range(cell_h)]

    for oy in range(cell_h):
        for ox in range(cell_w):
            block_sum = 0
            for dy in range(4):
                for dx in range(4):
                    sx = x0 + ox * 4 + dx
                    sy = y0 + oy * 4 + dy
                    if 0 <= sx < w and 0 <= sy < h:
                        px = img.getpixel((sx, sy))
                        if mode == 'count':
                            block_sum += (1 if px else 0)
                        else:
                            block_sum += px
            if mode == 'count':
                result[oy][ox] = 1 if block_sum >= threshold else 0
            else:
                avg = block_sum / 16.0
                result[oy][ox] = 1 if avg >= threshold else 0

    return result


def generate_candidates(font_1x, font_4x, char):
    """Generate candidate bitmaps using all 6 rendering strategies.

    Returns dict of strategy_name -> bitmap (list of rows, 9x8, 0/1 values).
    Strategies that fail are omitted.
    """
    candidates = {}

    # --- Native size (9ppem) strategies ---

    # Strategy A: Monochrome hinted (FT_LOAD_TARGET_MONO via mode='1')
    img_mono, bbox_mono = _render_raw(font_1x, char, '1', CANVAS_1X)
    bm = _extract_centered(img_mono, bbox_mono, CHAR_WIDTH, DISPLAYED_SCANLINES)
    if bm:
        candidates['mono'] = bm

    # Render grayscale once, reuse for B and C
    img_gray, bbox_gray = _render_raw(font_1x, char, 'L', CANVAS_1X)

    # Strategy B: Grayscale at 9ppem, threshold 128 (50%)
    bm = _extract_centered(img_gray, bbox_gray, CHAR_WIDTH, DISPLAYED_SCANLINES,
                           threshold=128)
    if bm:
        candidates['gray128'] = bm

    # Strategy C: Grayscale at 9ppem, threshold 96 (37.5%)
    bm = _extract_centered(img_gray, bbox_gray, CHAR_WIDTH, DISPLAYED_SCANLINES,
                           threshold=96)
    if bm:
        candidates['gray96'] = bm

    # --- 4x Supersampled (36ppem) strategies ---

    # Render monochrome at 4x
    img_mono_4x, bbox_mono_4x = _render_raw(font_4x, char, '1', CANVAS_4X)

    # Strategy D: 4x supersampled monochrome, block-count >= 8 (50% of 16)
    bm = _downsample_4x(img_mono_4x, bbox_mono_4x, mode='count', threshold=8)
    if bm:
        candidates['ss_mono'] = bm

    # Render grayscale at 4x
    img_gray_4x, bbox_gray_4x = _render_raw(font_4x, char, 'L', CANVAS_4X)

    # Strategy E: 4x supersampled grayscale, block-average >= 128
    bm = _downsample_4x(img_gray_4x, bbox_gray_4x, mode='average', threshold=128)
    if bm:
        candidates['ss_gray128'] = bm

    # Strategy F: 4x supersampled grayscale, block-average >= 96
    bm = _downsample_4x(img_gray_4x, bbox_gray_4x, mode='average', threshold=96)
    if bm:
        candidates['ss_gray96'] = bm

    return candidates


def score_bitmap(bitmap):
    """Score a candidate bitmap on intrinsic quality. Higher = better."""
    if not bitmap:
        return -10000.0

    n_pixels = sum(sum(row) for row in bitmap)
    if n_pixels == 0:
        return -10000.0

    score = 0.0

    # Pixel count: penalize very sparse or very dense
    if n_pixels < 4:
        score -= (4 - n_pixels) * 15
    elif n_pixels > 45:
        score -= (n_pixels - 45) * 5

    # Center of mass (ideal: cx=3.5, cy=4.0 for 8x9)
    cx = sum(x * bitmap[y][x] for y in range(DISPLAYED_SCANLINES)
             for x in range(CHAR_WIDTH)) / n_pixels
    cy = sum(y * bitmap[y][x] for y in range(DISPLAYED_SCANLINES)
             for x in range(CHAR_WIDTH)) / n_pixels
    score -= abs(cx - 3.5) * 3
    score -= abs(cy - 4.0) * 3

    # Penalize top/bottom edge pixels (suggests clipping or oversized glyph)
    edge_penalty = sum(bitmap[0]) + sum(bitmap[DISPLAYED_SCANLINES - 1])
    score -= edge_penalty * 3

    # Bonus for horizontal symmetry (many APL symbols are symmetric)
    h_matches = sum(1 for y in range(DISPLAYED_SCANLINES)
                    for x in range(CHAR_WIDTH // 2)
                    if bitmap[y][x] == bitmap[y][CHAR_WIDTH - 1 - x])
    score += h_matches * 0.3

    return score


def select_best_candidate(candidates, original_bitmap=None):
    """Select the best candidate bitmap from the strategies.

    Uses intrinsic quality scoring. If original_bitmap is provided,
    uses similarity as a tiebreaker among top-scoring candidates.
    """
    if not candidates:
        return None, 'none'

    scored = [(name, bm, score_bitmap(bm)) for name, bm in candidates.items()]
    scored.sort(key=lambda x: x[2], reverse=True)

    best_name, best_bm, best_score = scored[0]

    # If original available, use as tiebreaker among close candidates
    if original_bitmap and len(scored) > 1:
        # Consider candidates within 10% or 5 points of best
        margin = max(abs(best_score) * 0.1, 5.0)
        threshold = best_score - margin
        top = [(n, b, s) for n, b, s in scored if s >= threshold]

        if len(top) > 1:
            def orig_diff(item):
                _, bm, _ = item
                return sum(abs(bm[y][x] - original_bitmap[y][x])
                           for y in range(DISPLAYED_SCANLINES)
                           for x in range(CHAR_WIDTH))
            top.sort(key=orig_diff)
            best_name, best_bm, best_score = top[0]

    return best_bm, best_name


def show_all_candidates(font_path, original_path=None):
    """Display all rendering strategy candidates for each character."""
    from PIL import ImageFont

    font_1x = ImageFont.truetype(font_path, RENDER_PPEM_1X)
    font_4x = ImageFont.truetype(font_path, RENDER_PPEM_4X)

    original_data = None
    if original_path:
        original_data = read_hex_rom(original_path)

    for char_code in range(CHARS_PER_ROM):
        mapping = APL_MAP.get(char_code)
        if mapping == COPY_ORIGINAL or mapping is None or mapping == 0x0020:
            continue

        char = chr(mapping)
        candidates = generate_candidates(font_1x, font_4x, char)
        if not candidates:
            print(f"0x{char_code:02X} ({char}): NO CANDIDATES (missing glyph)")
            continue

        orig_bm = None
        if original_data:
            orig_bm = bitmap_from_rom(original_data, char_code)

        _, selected = select_best_candidate(candidates, orig_bm)

        # Build column list
        columns = []
        if orig_bm:
            columns.append(('ORIGINAL', orig_bm))
        for name in STRATEGY_NAMES:
            if name in candidates:
                columns.append((name, candidates[name]))

        symbol = char if mapping < 0x80 else f"U+{mapping:04X}"
        print(f"\n=== 0x{char_code:02X} ({symbol}) === [selected: {selected}]")

        # Header
        header = '     '
        for name, _ in columns:
            header += f'{name:>12s}  '
        print(header)

        # Scanlines
        for sl in range(DISPLAYED_SCANLINES):
            line = f'  {sl}: '
            for name, bm in columns:
                pixels = ''.join('#' if bm[sl][x] else '.' for x in range(CHAR_WIDTH))
                marker = '*' if name == selected else ' '
                line += f' {pixels}{marker} '
            print(line)

        # Pixel counts
        counts = '     '
        for name, bm in columns:
            n = sum(sum(row) for row in bm)
            counts += f'{"px=" + str(n):>12s}  '
        print(counts)


def render_charrom(font_path, output_path, original_path=None, strategy='auto'):
    """Render APL charrom using multi-strategy ensemble.

    For each character, generates up to 6 candidate bitmaps using different
    rendering strategies (monochrome hinted, grayscale thresholded, 4x
    supersampled), then selects the best candidate using a quality scorer.

    Args:
        font_path: Path to TrueType font file
        output_path: Output .hex file path
        original_path: Optional original ROM for COPY_ORIGINAL chars and tiebreaking
        strategy: 'auto' for quality-based selection, or a strategy name to force
    """
    try:
        from PIL import ImageFont
    except ImportError:
        print("ERROR: Pillow is required. Install with: pip install Pillow",
              file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(font_path):
        print(f"ERROR: Font file not found: {font_path}", file=sys.stderr)
        sys.exit(1)

    # Load fonts once for all characters
    font_1x = ImageFont.truetype(font_path, RENDER_PPEM_1X)
    font_4x = ImageFont.truetype(font_path, RENDER_PPEM_4X)

    original_data = None
    if original_path:
        original_data = read_hex_rom(original_path)

    rom_data = [0] * ROM_SIZE
    stats = {'rendered': 0, 'copied': 0, 'missing': [], 'strategies': {},
             'fallback': 0}

    for char_code in range(CHARS_PER_ROM):
        mapping = APL_MAP.get(char_code)

        if mapping == COPY_ORIGINAL:
            if original_data:
                offset = char_code * SCANLINES_PER_CHAR
                for i in range(SCANLINES_PER_CHAR):
                    rom_data[offset + i] = original_data[offset + i]
                stats['copied'] += 1
            continue

        if mapping is None:
            continue

        if mapping == 0x0020:
            stats['rendered'] += 1
            continue

        char = chr(mapping)
        candidates = generate_candidates(font_1x, font_4x, char)

        if not candidates:
            # Fall back to original ROM if available
            if original_data:
                offset = char_code * SCANLINES_PER_CHAR
                for i in range(SCANLINES_PER_CHAR):
                    rom_data[offset + i] = original_data[offset + i]
                stats['fallback'] += 1
            else:
                stats['missing'].append((char_code, mapping, char))
            continue

        orig_bm = None
        if original_data:
            orig_bm = bitmap_from_rom(original_data, char_code)

        # Select candidate
        if strategy != 'auto' and strategy in candidates:
            best_bm = candidates[strategy]
            best_name = strategy
        else:
            best_bm, best_name = select_best_candidate(candidates, orig_bm)

        if best_bm:
            byte_list = bitmap_to_bytes(best_bm)
            offset = char_code * SCANLINES_PER_CHAR
            for i, b in enumerate(byte_list):
                rom_data[offset + i] = b
            stats['rendered'] += 1
            stats['strategies'][best_name] = stats['strategies'].get(best_name, 0) + 1

    # Write output .hex file
    with open(output_path, 'w') as f:
        for byte_val in rom_data:
            f.write(f"{byte_val:02X}\n")

    print(f"Written: {output_path}")
    print(f"Rendered: {stats['rendered']}, Copied: {stats['copied']}")
    if stats['fallback']:
        print(f"Fallback to original (missing glyph): {stats['fallback']}")
    if stats['strategies']:
        print("Strategy usage:")
        for name in STRATEGY_NAMES:
            if name in stats['strategies']:
                print(f"  {name}: {stats['strategies'][name]}")
    if stats['missing']:
        print(f"Missing glyphs ({len(stats['missing'])}):")
        for code, cp, ch in stats['missing']:
            print(f"  0x{code:02X} -> U+{cp:04X} ({ch})")


# ============================================================================
# Mapping Display
# ============================================================================

def print_mapping():
    """Print the current mapping table for review."""
    try:
        import unicodedata
    except ImportError:
        unicodedata = None

    print("APL Unicode Mapping Table (Tek4010/Videx encoding):")
    print(f"{'Code':>6s}  {'Unicode':>8s}  {'Char':>4s}  Description")
    print("-" * 70)
    for code in range(CHARS_PER_ROM):
        mapping = APL_MAP.get(code)
        if mapping == COPY_ORIGINAL:
            print(f"  0x{code:02X}  {'(copy)':>8s}  {'':>4s}  copied from original ROM")
        elif mapping is None:
            print(f"  0x{code:02X}  {'(none)':>8s}  {'':>4s}  blank/unmapped")
        else:
            char = chr(mapping) if mapping >= 0x20 else ' '
            if unicodedata:
                name = unicodedata.name(chr(mapping), '(unknown)')
            else:
                name = ''
            print(f"  0x{code:02X}  U+{mapping:04X}   {char:>4s}  {name}")


# ============================================================================
# CLI
# ============================================================================

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(0)

    command = sys.argv[1]

    if command == 'visualize':
        if len(sys.argv) < 3:
            print("Usage: gen_charrom_from_unicode.py visualize <hex_file>")
            sys.exit(1)
        rom_data = read_hex_rom(sys.argv[2])
        visualize_rom(rom_data)

    elif command == 'compare':
        if len(sys.argv) < 4:
            print("Usage: gen_charrom_from_unicode.py compare <hex1> <hex2>")
            sys.exit(1)
        rom1 = read_hex_rom(sys.argv[2])
        rom2 = read_hex_rom(sys.argv[3])
        compare_roms(rom1, rom2)

    elif command == 'render':
        if len(sys.argv) < 4:
            print("Usage: gen_charrom_from_unicode.py render <font.ttf> <output.hex> [options]")
            print("Options:")
            print("  --original=<file>    Copy COPY_ORIGINAL chars from this ROM")
            print("  --strategy=<name>    Force a specific strategy (default: auto)")
            print(f"    Available: auto, {', '.join(STRATEGY_NAMES)}")
            sys.exit(1)
        font_path = sys.argv[2]
        output_path = sys.argv[3]

        kwargs = {}
        for arg in sys.argv[4:]:
            if arg.startswith('--original='):
                kwargs['original_path'] = arg.split('=', 1)[1]
            elif arg.startswith('--strategy='):
                kwargs['strategy'] = arg.split('=', 1)[1]

        render_charrom(font_path, output_path, **kwargs)

    elif command == 'candidates':
        if len(sys.argv) < 3:
            print("Usage: gen_charrom_from_unicode.py candidates <font.ttf> [--original=<file>]")
            sys.exit(1)
        font_path = sys.argv[2]
        original_path = None
        for arg in sys.argv[3:]:
            if arg.startswith('--original='):
                original_path = arg.split('=', 1)[1]
        show_all_candidates(font_path, original_path)

    elif command == 'mapping':
        print_mapping()

    else:
        print(f"Unknown command: {command}")
        print("Commands: visualize, compare, render, candidates, mapping")
        sys.exit(1)


if __name__ == "__main__":
    main()
