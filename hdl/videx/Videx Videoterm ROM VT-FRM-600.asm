;
; Videx Videoterm firmware ROM VT-FRM-600  (NTSC / 60 Hz)
;
; Disassembly of "Videx Videoterm ROM VT-FRM-600.bin" (1024 bytes)
; ROM is mapped at $C800-$CBFF (expansion ROM). The last
; 256 bytes ($CB00-$CBFF) are also visible at $Cn00-$CnFF
; via slot ROM when the card's slot is selected.
;
; ====================================================================
;   RELATIONSHIP TO ROM 2.4 AND VT-FRM-602
; ====================================================================
;   VT-FRM-600 differs from ROM 2.4 (50 Hz European) in 17 bytes,
;   all confined to the SETUP routine and CRTC initialization table.
;   The rest of the firmware -- BASOUT, BASINP, ESC dispatch, Pascal
;   I/O entries, scroll, cursor, GETLN handling, etc. -- is byte-
;   identical to 2.4. See "hdl/videx/Videx Videoterm ROM 2.4.asm" for
;   full annotation of the unchanged routines.
;
;   The 17 differences split into two logically distinct changes:
;
;     1. CRTC init loop reorganized to count DOWN with DEX/BPL
;        instead of UP with INX/CPX/BNE -- IDENTICAL to VT-FRM-602.
;        Saves one byte in the loop tail; padded with NOP at $C82D.
;        The BEQ-skip offset at $C807 shifts from $21 to $20, and
;        the LDX immediate at $C81A changes from $00 to $0F so
;        DEX/BPL iterates 16 times (X=$0F down through $00).
;          Affected: $C808, $C81A, $C825-$C82D   (11 bytes)
;
;     2. CRTC init table retuned for NTSC 60 Hz / 525-line monitors:
;          R0 (Horizontal Total)    $7A -> $7B   +1 char of H-blank
;          R2 (HSYNC Position)      $5E -> $5C   sync 2 chars earlier
;          R3 (HSYNC Width)         $2F -> $29   width 9 (was 15)
;          R4 (Vertical Total -1)   $22 -> $1B   28 rows (was 35)
;          R5 (V-Total Adjust)      $00 -> $08   +8 scanlines
;          R7 (VSYNC Position)      $1D -> $1A   sync 3 rows earlier
;          (R1, R6, R8-R15 unchanged from 2.4)
;          Affected: $C8A1, $C8A3, $C8A4, $C8A5, $C8A6, $C8A8 (6 bytes)
;
;        Frame timing at the same ~1.937 MHz char clock:
;          2.4   PAL :  htotal=123 chars * vtotal=315 scan = 50.00 Hz
;          600   NTSC:  htotal=124 chars * vtotal=260 scan = 60.07 Hz
;          602   PAL :  htotal=124 chars * vtotal=315 scan = 49.58 Hz
;
;   Comparison vs the 50 Hz follow-on VT-FRM-602:
;     - SETUP loop reorganization: IDENTICAL.
;     - CRTC table: 600 changes 6 registers (R0,R2,R3,R4,R5,R7);
;                   602 changes only 2 (R0,R7). FRM-602 (c) 1983
;                   appears to be derived from this 1982 FRM-600
;                   codebase by reverting R2/R3/R4/R5 back to the
;                   ROM 2.4 PAL values, while keeping the SETUP
;                   refactor and the R0/R7 monitor tweaks.
;
;   Symbols, conventions, and slot-3 screen-hole assumptions match
;   the 2.4 disassembly. Identical instruction streams reproduced
;   verbatim for completeness; differences flagged with ";<-- 600".
;
;   Slot assumed: 3  (screen-hole offsets +$03)
;   CRTC port   : $C0B0/$C0B1
;   VRAM window : $CC00-$CDFF (bank-switched via $C0Bx)
;   80-col on   : STA SETAN0 ($C059)
;   ROM release : STA EXPROMOFF ($CFFF)
;

; --- Apple II monitor zero page ----------------------------------
MON_CH     = $24
MON_CV     = $25
MON_BASL   = $28
MON_BASH   = $29
XSAVE      = $35
MON_CSWL   = $36
MON_CSWH   = $37
MON_KSWL   = $38
MON_KSWH   = $39
MON_RNDL   = $4E
MON_RNDH   = $4F

; --- Apple II RAM symbols ----------------------------------------
IN         = $0200

; --- Apple II hardware soft switches -----------------------------
KBD        = $C000
KBDSTRB    = $C010
SPKR       = $C030
SETAN0     = $C058
CLRAN0     = $C059
BUTN2      = $C063

; --- Videx Videoterm device-select page (slot 3, $C0Bx) ----------
DEV0       = $C0B0
DEV1       = $C0B1

; --- Expansion ROM / VRAM window ---------------------------------
DISP0      = $CC00
DISP1      = $CD00
CLRROM     = $CFFF

; --- Slot-3 screen holes (firmware state) ------------------------
CRFLAG     = $0478
BASEL      = $047B
ASAV1      = $04F8
BASEH      = $04FB
CHORZ      = $057B
TEMPX      = $05F8
CVERT      = $05FB
OLDCHAR    = $0678
BYTE       = $067B
START      = $06FB
POFF       = $077B
FLAGS      = $07FB

; --- Apple II Monitor ROM entry points ---------------------------
MON_VTAB   = $FC22
MON_SETKBD = $FE89
MON_SETVID = $FE93
IORTS      = $FFCB

        .org  $C800

; ====================================================================
;   SETUP -- one-time CRTC init + screen clear        (DIFFERS FROM 2.4)
; ====================================================================
;   600 vs 2.4: the CRTC init loop is reversed -- 600 starts X at
;   $0F and DEX/BPL down to $FF, then INX restores X=0 before
;   STA CLRAN0. 2.4 starts X at 0 and INX/CPX/BNE up to $10. Same
;   16 registers loaded; the BEQ at $C807 and LDX at $C819 shift
;   one byte to track the new layout. This is identical to FRM-602.
SETUP:
    $C800:  AD 7B 07          LDA POFF
    $C803:  29 F8             AND #$F8
    $C805:  C9 30             CMP #$30
    $C807:  F0 20             BEQ SETEXIT       ;<-- 600: was F0 21
RESTART:
    $C809:  A9 30             LDA #$30
    $C80B:  8D 7B 07          STA POFF
    $C80E:  8D FB 07          STA FLAGS
    $C811:  A9 00             LDA #$00
    $C813:  8D FB 06          STA START
    $C816:  20 61 C9          JSR CLSCRN
    $C819:  A2 0F             LDX #$0F          ;<-- 600: was A2 00
LOOP:
    $C81B:  8A                TXA
    $C81C:  8D B0 C0          STA DEV0
    $C81F:  BD A1 C8          LDA TABLE,X
    $C822:  8D B1 C0          STA DEV1
    $C825:  CA                DEX               ;<-- 600 (was: E8 INX)
    $C826:  10 F3             BPL LOOP          ;<-- 600 (was: E0 10 CPX #$10)
    $C828:  E8                INX               ;<-- 600 (was: D0 F1 BNE LOOP)
SETEXIT:                                        ;<-- 600: SETEXIT moved from $C82A
    $C829:  8D 59 C0          STA CLRAN0
    $C82C:  60                RTS
    $C82D:  EA                NOP               ;<-- 600: padding (was: byte $60)
; ====================================================================
;   EXIT -- standard register-restore exit
; ====================================================================
EXIT:
    $C82E:  AD FB 07          LDA FLAGS
    $C831:  29 08             AND #$08
    $C833:  F0 09             BEQ NORMOUT
    $C835:  20 93 FE          JSR MON_SETVID
    $C838:  20 22 FC          JSR MON_VTAB
    $C83B:  20 89 FE          JSR MON_SETKBD
NORMOUT:
    $C83E:  68                PLA
    $C83F:  A8                TAY
    $C840:  68                PLA
    $C841:  AA                TAX
    $C842:  68                PLA
    $C843:  60                RTS
; ====================================================================
;   RDKEY / KEYIN -- position cursor then poll keyboard
; ====================================================================
RDKEY:
    $C844:  20 D1 C8          JSR CSRMOV
KEYIN:
    $C847:  E6 4E             INC MON_RNDL
    $C849:  D0 02             BNE KEYIN2
    $C84B:  E6 4F             INC MON_RNDH
KEYIN2:
    $C84D:  AD 00 C0          LDA KBD
    $C850:  10 F5             BPL KEYIN
    $C852:  20 5C C8          JSR KEYSTAT
    $C855:  90 F0             BCC KEYIN
NOKEY:
    $C857:  2C 10 C0          BIT KBDSTRB
    $C85A:  18                CLC
    $C85B:  60                RTS
; ====================================================================
;   KEYSTAT -- classify the just-read key
; ====================================================================
KEYSTAT:
    $C85C:  C9 8B             CMP #$8B
    $C85E:  D0 02             BNE NOTK
    $C860:  A9 DB             LDA #$DB
NOTK:
    $C862:  C9 81             CMP #$81
    $C864:  D0 0A             BNE NTSHFT
    $C866:  AD FB 07          LDA FLAGS
    $C869:  49 40             EOR #$40
    $C86B:  8D FB 07          STA FLAGS
    $C86E:  B0 E7             BCS NOKEY
NTSHFT:
    $C870:  48                PHA
    $C871:  AD FB 07          LDA FLAGS
    $C874:  0A                ASL A
    $C875:  0A                ASL A
    $C876:  68                PLA
    $C877:  90 1F             BCC INDONE
    $C879:  C9 B0             CMP #$B0
    $C87B:  90 1B             BCC INDONE
    $C87D:  2C 63 C0          BIT BUTN2
    $C880:  30 14             BMI NOSHIFT
    $C882:  C9 B0             CMP #$B0
    $C884:  F0 0E             BEQ ZERO
    $C886:  C9 C0             CMP #$C0
    $C888:  D0 02             BNE NOTAT
    $C88A:  A9 D0             LDA #$D0
NOTAT:
    $C88C:  C9 DB             CMP #$DB
    $C88E:  90 08             BCC INDONE
    $C890:  29 CF             AND #$CF
    $C892:  D0 04             BNE INDONE
ZERO:
    $C894:  A9 DD             LDA #$DD
NOSHIFT:
    $C896:  09 20             ORA #$20
INDONE:
    $C898:  48                PHA
    $C899:  29 7F             AND #$7F
    $C89B:  8D 7B 06          STA BYTE
    $C89E:  68                PLA
    $C89F:  38                SEC
    $C8A0:  60                RTS
; ====================================================================
;   TABLE -- 6845 CRTC initialization values (R0..R15)  (NTSC TIMING)
; ====================================================================
;   Loaded by the SETUP loop, in REVERSE order (R15 first, R0 last)
;   in the 600 variant. Final state of CRTC is identical to writing
;   in forward order. Byte-by-byte comparison vs 2.4:
;
;     R0 =$7B horiz total -1  (124 char clocks)   2.4: $7A
;     R1 =$50 horiz displayed (80 chars)          unchanged
;     R2 =$5C horiz sync pos  (char 92)           2.4: $5E
;     R3 =$29 horiz sync width (9 char clocks)    2.4: $2F (15)
;     R4 =$1B vert total -1   (28 char rows)      2.4: $22 (35)
;     R5 =$08 vert total adj  (+8 scanlines)      2.4: $00
;     R6 =$18 vert displayed  (24 rows)           unchanged
;     R7 =$1A vert sync pos   (row 26)            2.4: $1D
;     R8 =$00 interlace mode  (non-interlaced)    unchanged
;     R9 =$08 max scan line   (9 lines/cell)      unchanged
;     R10=$E0 cursor start    (cursor off)        unchanged
;     R11=$08 cursor end                          unchanged
;     R12-R15 = $00           (set by code at runtime)
;
;   NTSC timing math (~1.937 MHz char clock):
;     H-period:  124 chars / 1.937 MHz = 64.0 us  -> 15.625 kHz hsync
;     V-period:  28 rows * 9 + 8 = 260 scanlines
;                260 * 64.0 us = 16.64 ms        -> 60.1 Hz frame
;     Active:    24 rows * 9 = 216 scanlines visible
;     V-sync:    starts at row 26, ends 2 rows later (R3 hi nibble)
;
;   This produces a non-interlaced 60 Hz / 260-scan signal that
;   composite NTSC monitors and many TVs accept as a near-NTSC
;   feed. It does NOT generate true 525-line interlaced NTSC.
TABLE:
    $C8A1:  .byte $7B $50 $5C $29 $1B $08 $18 $1A   ;<-- 6 bytes differ
    $C8A9:  .byte $00 $08 $E0 $08 $00 $00 $00 $00
; ====================================================================
;   BASOUT1 -- secondary BASIC output (after cursor reposition)
; ====================================================================
BASOUT1:
    $C8B1:  8D 7B 06          STA BYTE
    $C8B4:  A5 25             LDA MON_CV
    $C8B6:  CD FB 05          CMP CVERT
    $C8B9:  F0 06             BEQ CVOK
    $C8BB:  8D FB 05          STA CVERT
    $C8BE:  20 04 CA          JSR VTAB
CVOK:
    $C8C1:  A5 24             LDA MON_CH
    $C8C3:  CD 7B 05          CMP CHORZ
    $C8C6:  90 03             BCC PSCLOUT
    $C8C8:  8D 7B 05          STA CHORZ
PSCLOUT:
    $C8CB:  AD 7B 06          LDA BYTE
    $C8CE:  20 89 CA          JSR OUTPT1
; ====================================================================
;   CSRMOV -- write CHORZ/BASEL+BASEH to CRTC cursor regs R14/R15
; ====================================================================
CSRMOV:
    $C8D1:  A9 0F             LDA #$0F
    $C8D3:  8D B0 C0          STA DEV0
    $C8D6:  AD 7B 05          LDA CHORZ
    $C8D9:  C9 50             CMP #$50
    $C8DB:  B0 13             BCS RTS6
    $C8DD:  6D 7B 04          ADC BASEL
    $C8E0:  8D B1 C0          STA DEV1
    $C8E3:  A9 0E             LDA #$0E
    $C8E5:  8D B0 C0          STA DEV0
    $C8E8:  A9 00             LDA #$00
    $C8EA:  6D FB 04          ADC BASEH
    $C8ED:  8D B1 C0          STA DEV1
RTS6:
    $C8F0:  60                RTS
; ====================================================================
;   ESC1 -- ESC-letter dispatcher (uses ESCTBL at $CBF2)
; ====================================================================
ESC1:
    $C8F1:  49 C0             EOR #$C0
    $C8F3:  C9 08             CMP #$08
    $C8F5:  B0 1D             BCS RTS3
    $C8F7:  A8                TAY
    $C8F8:  A9 C9             LDA #$C9
    $C8FA:  48                PHA
    $C8FB:  B9 F2 CB          LDA ESCTBL,Y
    $C8FE:  48                PHA
    $C8FF:  60                RTS
    $C900:  EA                NOP
; ====================================================================
;   CLREOL -- clear from cursor to end of line
; ====================================================================
CLREOL:
    $C901:  AC 7B 05          LDY CHORZ
CLEOLZ:
    $C904:  A9 A0             LDA #$A0
CLEOL2:
    $C906:  20 71 CA          JSR CHRPUT
    $C909:  C8                INY
    $C90A:  C0 50             CPY #$50
    $C90C:  90 F8             BCC CLEOL2
    $C90E:  60                RTS
; ====================================================================
;   LEADIN -- ESC ^ : set 4-character lead-in counter
; ====================================================================
LEADIN:
    $C90F:  A9 34             LDA #$34
PSAVE:
    $C911:  8D 7B 07          STA POFF
RTS3:
    $C914:  60                RTS
; ====================================================================
;   GOXY1 -- ESC = : set 2-character lead-in counter for goto-XY
; ====================================================================
GOXY1:
    $C915:  A9 32             LDA #$32
    $C917:  D0 F8             BNE PSAVE
; ====================================================================
;   BELL -- beep the speaker
; ====================================================================
BELL:
    $C919:  A0 C0             LDY #$C0
BELL1:
    $C91B:  A2 80             LDX #$80
BELL2:
    $C91D:  CA                DEX
    $C91E:  D0 FD             BNE BELL2
    $C920:  AD 30 C0          LDA SPKR
    $C923:  88                DEY
    $C924:  D0 F5             BNE BELL1
    $C926:  60                RTS
; ====================================================================
;   STOADV -- store char on screen + advance cursor
; ====================================================================
STOADV:
    $C927:  AC 7B 05          LDY CHORZ
    $C92A:  C0 50             CPY #$50
    $C92C:  90 05             BCC NOT81
    $C92E:  48                PHA
    $C92F:  20 B0 C9          JSR CRLF
    $C932:  68                PLA
NOT81:
    $C933:  AC 7B 05          LDY CHORZ
    $C936:  20 71 CA          JSR CHRPUT
ADVANCE:
    $C939:  EE 7B 05          INC CHORZ
    $C93C:  2C 78 04          BIT CRFLAG
    $C93F:  10 07             BPL RTS8
    $C941:  AD 7B 05          LDA CHORZ
    $C944:  C9 50             CMP #$50
    $C946:  B0 68             BCS CRLF
RTS8:
    $C948:  60                RTS
; ====================================================================
;   CLREOP -- clear from cursor to end of page
; ====================================================================
CLREOP:
    $C949:  AC 7B 05          LDY CHORZ
    $C94C:  AD FB 05          LDA CVERT
CLEOP1:
    $C94F:  48                PHA
    $C950:  20 07 CA          JSR VTABZ
    $C953:  20 04 C9          JSR CLEOLZ
    $C956:  A0 00             LDY #$00
    $C958:  68                PLA
    $C959:  69 00             ADC #$00
    $C95B:  C9 18             CMP #$18
    $C95D:  90 F0             BCC CLEOP1
    $C95F:  B0 23             BCS JVTAB
; ====================================================================
;   CLSCRN -- HOME + clear to end of page
; ====================================================================
CLSCRN:
    $C961:  20 67 C9          JSR HOME
    $C964:  98                TYA
    $C965:  F0 E8             BEQ CLEOP1
; ====================================================================
;   HOME -- move cursor to (0,0) and VTAB
; ====================================================================
HOME:
    $C967:  A9 00             LDA #$00
    $C969:  8D 7B 05          STA CHORZ
    $C96C:  8D FB 05          STA CVERT
    $C96F:  A8                TAY
    $C970:  F0 12             BEQ JVTAB
; ====================================================================
;   BS -- backspace (decrement CHORZ; if negative, wrap to col 79
;         and move cursor up)
; ====================================================================
BS:
    $C972:  CE 7B 05          DEC CHORZ
    $C975:  10 9D             BPL RTS3
    $C977:  A9 4F             LDA #$4F
    $C979:  8D 7B 05          STA CHORZ
; ====================================================================
;   UP -- move cursor up one row (no scroll if at top)
; ====================================================================
UP:
    $C97C:  AD FB 05          LDA CVERT
    $C97F:  F0 93             BEQ RTS3
    $C981:  CE FB 05          DEC CVERT
JVTAB:
    $C984:  4C 04 CA          JMP VTAB
; ====================================================================
;   NOTGOXY -- handle ESC <digit> command
; ====================================================================
NOTGOXY:
    $C987:  A9 30             LDA #$30
    $C989:  8D 7B 07          STA POFF
    $C98C:  68                PLA
    $C98D:  09 80             ORA #$80
    $C98F:  C9 B1             CMP #$B1
    $C991:  D0 67             BNE NOT0
    $C993:  A9 08             LDA #$08
    $C995:  8D 58 C0          STA SETAN0
    $C998:  D0 5B             BNE FLGSET
NOT1:
    $C99A:  C9 B2             CMP #$B2
    $C99C:  D0 51             BNE NOT2
; ====================================================================
;   LOLITE -- ESC 2: clear FLAGS bit 0 (inverse video off)
; ====================================================================
LOLITE:
    $C99E:  A9 FE             LDA #$FE
FLGCLR:
    $C9A0:  2D FB 07          AND FLAGS
FLGSAV:
    $C9A3:  8D FB 07          STA FLAGS
    $C9A6:  60                RTS
; ====================================================================
;   PSOUT -- Pascal output entry
; ====================================================================
PSOUT:
    $C9A7:  8D 7B 06          STA BYTE
    $C9AA:  4E 78 04          LSR CRFLAG
    $C9AD:  4C CB C8          JMP PSCLOUT
; ====================================================================
;   CRLF -- CR followed by LF
; ====================================================================
CRLF:
    $C9B0:  20 27 CA          JSR CR
; ====================================================================
;   LF -- line feed; if past bottom row, scroll up
; ====================================================================
LF:
    $C9B3:  EE FB 05          INC CVERT
    $C9B6:  AD FB 05          LDA CVERT
    $C9B9:  C9 18             CMP #$18
    $C9BB:  90 4A             BCC VTABZ
    $C9BD:  CE FB 05          DEC CVERT
    $C9C0:  AD FB 06          LDA START
    $C9C3:  69 04             ADC #$04
    $C9C5:  29 7F             AND #$7F
    $C9C7:  8D FB 06          STA START
    $C9CA:  20 12 CA          JSR BASCLC1
    $C9CD:  A9 0D             LDA #$0D
    $C9CF:  8D B0 C0          STA DEV0
    $C9D2:  AD 7B 04          LDA BASEL
    $C9D5:  8D B1 C0          STA DEV1
    $C9D8:  A9 0C             LDA #$0C
    $C9DA:  8D B0 C0          STA DEV0
    $C9DD:  AD FB 04          LDA BASEH
    $C9E0:  8D B1 C0          STA DEV1
    $C9E3:  A9 17             LDA #$17
    $C9E5:  20 07 CA          JSR VTABZ
    $C9E8:  A0 00             LDY #$00
    $C9EA:  20 04 C9          JSR CLEOLZ
    $C9ED:  B0 95             BCS JVTAB
NOT2:
    $C9EF:  C9 B3             CMP #$B3
    $C9F1:  D0 0E             BNE JSTOADV
; ====================================================================
;   HILITE -- ESC 3: set FLAGS bit 0 (inverse video on)
; ====================================================================
HILITE:
    $C9F3:  A9 01             LDA #$01
FLGSET:
    $C9F5:  0D FB 07          ORA FLAGS
    $C9F8:  D0 A9             BNE FLGSAV
NOT0:
    $C9FA:  C9 B0             CMP #$B0
    $C9FC:  D0 9C             BNE NOT1
    $C9FE:  4C 09 C8          JMP RESTART
JSTOADV:
    $CA01:  4C 27 C9          JMP STOADV
; ====================================================================
;   VTAB / VTABZ -- compute screen base for current row
; ====================================================================
VTAB:
    $CA04:  AD FB 05          LDA CVERT
VTABZ:
    $CA07:  8D F8 04          STA ASAV1
    $CA0A:  0A                ASL A
    $CA0B:  0A                ASL A
    $CA0C:  6D F8 04          ADC ASAV1
    $CA0F:  6D FB 06          ADC START
BASCLC1:
    $CA12:  48                PHA
    $CA13:  4A                LSR A
    $CA14:  4A                LSR A
    $CA15:  4A                LSR A
    $CA16:  4A                LSR A
    $CA17:  8D FB 04          STA BASEH
    $CA1A:  68                PLA
    $CA1B:  0A                ASL A
    $CA1C:  0A                ASL A
    $CA1D:  0A                ASL A
    $CA1E:  0A                ASL A
    $CA1F:  8D 7B 04          STA BASEL
RTS2:
    $CA22:  60                RTS
; ====================================================================
;   VIDOUT -- output dispatcher
; ====================================================================
VIDOUT:
    $CA23:  C9 0D             CMP #$0D
    $CA25:  D0 06             BNE VDOUT1
CR:
    $CA27:  A9 00             LDA #$00
    $CA29:  8D 7B 05          STA CHORZ
    $CA2C:  60                RTS
VDOUT1:
    $CA2D:  09 80             ORA #$80
    $CA2F:  C9 A0             CMP #$A0
    $CA31:  B0 CE             BCS JSTOADV
    $CA33:  C9 87             CMP #$87
    $CA35:  90 08             BCC RTS4
    $CA37:  A8                TAY
    $CA38:  A9 C9             LDA #$C9
    $CA3A:  48                PHA
    $CA3B:  B9 B9 C9          LDA $C9B9,Y
    $CA3E:  48                PHA
RTS4:
    $CA3F:  60                RTS
; ====================================================================
;   CTLTBL -- ctrl-char dispatch (low-byte-1, base $C900)
; ====================================================================
CTLTBL:
    $CA40:  .byte $18 $71 $13 $B2 $48 $60 $AF $9D
    $CA48:  .byte $F2 $13 $13 $13 $13 $13 $13 $13
    $CA50:  .byte $13 $13 $66 $0E $13 $38 $00 $14
    $CA58:  .byte $7B
; ====================================================================
;   PSNCALC -- compute VRAM address + select bank
; ====================================================================
PSNCALC:
    $CA59:  18                CLC
    $CA5A:  98                TYA
    $CA5B:  6D 7B 04          ADC BASEL
    $CA5E:  48                PHA
    $CA5F:  A9 00             LDA #$00
    $CA61:  6D FB 04          ADC BASEH
    $CA64:  48                PHA
    $CA65:  0A                ASL A
    $CA66:  29 0C             AND #$0C
    $CA68:  AA                TAX
    $CA69:  BD B0 C0          LDA DEV0,X
    $CA6C:  68                PLA
    $CA6D:  4A                LSR A
    $CA6E:  68                PLA
    $CA6F:  AA                TAX
    $CA70:  60                RTS
; ====================================================================
;   CHRPUT -- write character into VRAM with inverse-video fold
; ====================================================================
CHRPUT:
    $CA71:  0A                ASL A
    $CA72:  48                PHA
    $CA73:  AD FB 07          LDA FLAGS
    $CA76:  4A                LSR A
    $CA77:  68                PLA
    $CA78:  6A                ROR A
    $CA79:  48                PHA
    $CA7A:  20 59 CA          JSR PSNCALC
    $CA7D:  68                PLA
    $CA7E:  B0 05             BCS WRITE1
    $CA80:  9D 00 CC          STA DISP0,X
    $CA83:  90 03             BCC WSKIP
WRITE1:
    $CA85:  9D 00 CD          STA DISP1,X
WSKIP:
    $CA88:  60                RTS
; ====================================================================
;   OUTPT1 -- general output entry (CSW landing pad via $CB07)
; ====================================================================
OUTPT1:
    $CA89:  48                PHA
    $CA8A:  A9 F7             LDA #$F7
    $CA8C:  20 A0 C9          JSR FLGCLR
    $CA8F:  8D 59 C0          STA CLRAN0
    $CA92:  AD 7B 07          LDA POFF
    $CA95:  29 07             AND #$07
    $CA97:  D0 04             BNE LEAD
    $CA99:  68                PLA
    $CA9A:  4C 23 CA          JMP VIDOUT
LEAD:
    $CA9D:  29 04             AND #$04
    $CA9F:  F0 03             BEQ GOXY3
    $CAA1:  4C 87 C9          JMP NOTGOXY
GOXY3:
    $CAA4:  68                PLA
    $CAA5:  38                SEC
    $CAA6:  E9 20             SBC #$20
    $CAA8:  29 7F             AND #$7F
    $CAAA:  48                PHA
    $CAAB:  CE 7B 07          DEC POFF
    $CAAE:  AD 7B 07          LDA POFF
    $CAB1:  29 03             AND #$03
    $CAB3:  D0 15             BNE GOXY2
    $CAB5:  68                PLA
    $CAB6:  C9 18             CMP #$18
    $CAB8:  B0 03             BCS BADY
    $CABA:  8D FB 05          STA CVERT
BADY:
    $CABD:  AD F8 05          LDA TEMPX
    $CAC0:  C9 50             CMP #$50
    $CAC2:  B0 03             BCS BADX
    $CAC4:  8D 7B 05          STA CHORZ
BADX:
    $CAC7:  4C 04 CA          JMP VTAB
GOXY2:
    $CACA:  68                PLA
    $CACB:  8D F8 05          STA TEMPX
    $CACE:  60                RTS
; ====================================================================
;   STPLST -- stop-list (Ctrl-S pause, Ctrl-C resume)
; ====================================================================
STPLST:
    $CACF:  AD 00 C0          LDA KBD
    $CAD2:  C9 93             CMP #$93
    $CAD4:  D0 0F             BNE STPDONE
    $CAD6:  2C 10 C0          BIT KBDSTRB
STPLOOP:
    $CAD9:  AD 00 C0          LDA KBD
    $CADC:  10 FB             BPL STPLOOP
    $CADE:  C9 83             CMP #$83
    $CAE0:  F0 03             BEQ STPDONE
    $CAE2:  2C 10 C0          BIT KBDSTRB
STPDONE:
    $CAE5:  60                RTS
; ====================================================================
;   ESCNOW / ESCNEW / ESC2 -- ESC-sequence state machine
; ====================================================================
ESCNOW:
    $CAE6:  A8                TAY
    $CAE7:  B9 31 CB          LDA $CB31,Y
    $CAEA:  20 F1 C8          JSR ESC1
ESCNEW:
    $CAED:  20 44 C8          JSR RDKEY
    $CAF0:  C9 CE             CMP #$CE
    $CAF2:  B0 08             BCS ESC2
    $CAF4:  C9 C9             CMP #$C9
    $CAF6:  90 04             BCC ESC2
    $CAF8:  C9 CC             CMP #$CC
    $CAFA:  D0 EA             BNE ESCNOW
ESC2:
    $CAFC:  4C F1 C8          JMP ESC1
    $CAFF:  EA                NOP
; ====================================================================
;   ENTRY -- BASIC initial-entry sled
; ====================================================================
ENTRY:
    $CB00:  2C CB FF          BIT IORTS
    $CB03:  70 31             BVS ENTR
INFAKE:
    $CB05:  38                SEC
L_CB06:
    $CB06:  .byte $90
OUTENTR:
    $CB07:  18                CLC
    $CB08:  B8                CLV
    $CB09:  50 2B             BVC ENTR
L_CB0B:
;   Pascal 1.1 firmware ID + entry-offset table
    $CB0B:  .byte $01 $82 $11 $14 $1C $22
INIT:
    $CB11:  4C 00 C8          JMP SETUP
READ:
    $CB14:  20 44 C8          JSR RDKEY
    $CB17:  29 7F             AND #$7F
    $CB19:  A2 00             LDX #$00
    $CB1B:  60                RTS
WRITE:
    $CB1C:  20 A7 C9          JSR PSOUT
    $CB1F:  A2 00             LDX #$00
    $CB21:  60                RTS
STATUS:
    $CB22:  C9 00             CMP #$00
    $CB24:  F0 09             BEQ STEXIT
    $CB26:  AD 00 C0          LDA KBD
    $CB29:  0A                ASL A
    $CB2A:  90 03             BCC STEXIT
    $CB2C:  20 5C C8          JSR KEYSTAT
STEXIT:
    $CB2F:  A2 00             LDX #$00
    $CB31:  60                RTS
; ====================================================================
;   INENTR -- BASIC keyboard input entry
; ====================================================================
INENTR:
    $CB32:  91 28             STA (MON_BASL),Y
    $CB34:  38                SEC
    $CB35:  B8                CLV
ENTR:
    $CB36:  8D FF CF          STA CLRROM
WHERE:
    $CB39:  48                PHA
    $CB3A:  85 35             STA XSAVE
    $CB3C:  8A                TXA
    $CB3D:  48                PHA
    $CB3E:  98                TYA
    $CB3F:  48                PHA
    $CB40:  A5 35             LDA XSAVE
    $CB42:  86 35             STX XSAVE
    $CB44:  A2 C3             LDX #$C3
    $CB46:  8E 78 04          STX CRFLAG
    $CB49:  48                PHA
    $CB4A:  50 10             BVC IO
;   Installer (one-time)
    $CB4C:  A9 32             LDA #$32
    $CB4E:  85 38             STA MON_KSWL
    $CB50:  86 39             STX MON_KSWH
    $CB52:  A9 07             LDA #$07
    $CB54:  85 36             STA MON_CSWL
    $CB56:  86 37             STX MON_CSWH
    $CB58:  20 00 C8          JSR SETUP
    $CB5B:  18                CLC
IO:
    $CB5C:  90 6F             BCC BASOUT
; ====================================================================
;   BASINP -- BASIC keyboard-input handler
; ====================================================================
BASINP:
    $CB5E:  68                PLA
    $CB5F:  A4 35             LDY XSAVE
    $CB61:  F0 1F             BEQ GETLN
    $CB63:  88                DEY
    $CB64:  AD 78 06          LDA OLDCHAR
    $CB67:  C9 88             CMP #$88
    $CB69:  F0 17             BEQ GETLN
    $CB6B:  D9 00 02          CMP IN,Y
    $CB6E:  F0 12             BEQ GETLN
    $CB70:  49 20             EOR #$20
    $CB72:  D9 00 02          CMP IN,Y
    $CB75:  D0 3B             BNE NTGETLN
    $CB77:  AD 78 06          LDA OLDCHAR
    $CB7A:  99 00 02          STA IN,Y
    $CB7D:  B0 03             BCS GETLN
ESC:
    $CB7F:  20 ED CA          JSR ESCNEW
GETLN:
    $CB82:  A9 80             LDA #$80
    $CB84:  20 F5 C9          JSR FLGSET
    $CB87:  20 44 C8          JSR RDKEY
    $CB8A:  C9 9B             CMP #$9B
    $CB8C:  F0 F1             BEQ ESC
    $CB8E:  C9 8D             CMP #$8D
    $CB90:  D0 05             BNE NOTCR
    $CB92:  48                PHA
    $CB93:  20 01 C9          JSR CLREOL
    $CB96:  68                PLA
NOTCR:
    $CB97:  C9 95             CMP #$95
    $CB99:  D0 12             BNE NOTPICK
    $CB9B:  AC 7B 05          LDY CHORZ
    $CB9E:  20 59 CA          JSR PSNCALC
    $CBA1:  B0 05             BCS READ1
    $CBA3:  BD 00 CC          LDA DISP0,X
    $CBA6:  90 03             BCC RSKIP
READ1:
    $CBA8:  BD 00 CD          LDA DISP1,X
RSKIP:
    $CBAB:  09 80             ORA #$80
NOTPICK:
    $CBAD:  8D 78 06          STA OLDCHAR
    $CBB0:  D0 08             BNE DONE
NTGETLN:
    $CBB2:  20 44 C8          JSR RDKEY
    $CBB5:  A0 00             LDY #$00
    $CBB7:  8C 78 06          STY OLDCHAR
DONE:
    $CBBA:  BA                TSX
    $CBBB:  E8                INX
    $CBBC:  E8                INX
    $CBBD:  E8                INX
    $CBBE:  9D 00 01          STA $0100,X
OUTDONE1:
    $CBC1:  A9 00             LDA #$00
OUTDONE:
    $CBC3:  85 24             STA MON_CH
    $CBC5:  AD FB 05          LDA CVERT
    $CBC8:  85 25             STA MON_CV
    $CBCA:  4C 2E C8          JMP EXIT
; ====================================================================
;   BASOUT -- primary BASIC output handler
; ====================================================================
BASOUT:
    $CBCD:  68                PLA
    $CBCE:  AC FB 07          LDY FLAGS
    $CBD1:  10 08             BPL BOUT
    $CBD3:  AC 78 06          LDY OLDCHAR
    $CBD6:  C0 E0             CPY #$E0
    $CBD8:  90 01             BCC BOUT
    $CBDA:  98                TYA
BOUT:
    $CBDB:  20 B1 C8          JSR BASOUT1
    $CBDE:  20 CF CA          JSR STPLST
    $CBE1:  A9 7F             LDA #$7F
    $CBE3:  20 A0 C9          JSR FLGCLR
    $CBE6:  AD 7B 05          LDA CHORZ
    $CBE9:  E9 47             SBC #$47
    $CBEB:  90 D4             BCC OUTDONE1
    $CBED:  69 1F             ADC #$1F
FIXCH:
    $CBEF:  18                CLC
    $CBF0:  90 D1             BCC OUTDONE
; ====================================================================
;   ESCTBL -- ESC-letter dispatch (low-byte-1, base $C900)
; ====================================================================
ESCTBL:
    $CBF2:  .byte $60 $38 $71 $B2 $7B $00 $48 $66
; ====================================================================
;   XLTBL -- alternate ESC-char translation table
; ====================================================================
XLTBL:
    $CBFA:  .byte $C4 $C2 $C1 $FF $C3 $EA

; --- end of ROM ----------------------------------------------------
