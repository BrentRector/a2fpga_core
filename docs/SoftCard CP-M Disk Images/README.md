# Microsoft SoftCard CP/M Disk Image Collection

A complete set of Microsoft Z-80 SoftCard CP/M disk images for the Apple II,
spanning 1980-1984. Collected to document the **firmware-card compatibility
fix** that made the Videx Videoterm (and other Pascal-1.1-protocol cards)
work correctly under CP/M.

## Why these disks live here

The user-visible "CP/M compatibility update" Apple II owners discuss in
period sources was *not* a Videoterm ROM patch — it was an update to
Microsoft's SoftCard CP/M BIOS. Per the Apple CP/M reference document:

> Version 2.20B could not identify Firmware Cards and would often use the
> wrong I/O drives. Version 2.23 will operate the Firmware Cards, if the
> card manufacturer followed the Apple protocols.

The Videoterm has been a "firmware card" — i.e., compliant with Apple
Pascal 1.1's self-describing firmware ID protocol — since at least ROM 2.4
(see `$CB05/$CB07/$CB0B/$CB0C` signature bytes in
[`Videx Videoterm ROM 2.4.asm`](../../hdl/videx/Videx%20Videoterm%20ROM%202.4.asm)).
What changed was Microsoft updating the SoftCard's CP/M BIOS to recognize
and use that protocol; the Videoterm itself never needed a CP/M-targeted
update.

This directory holds the SoftCard CP/M release history bracketing that fix.
The 2.20/2.20B disks are the "before" (no firmware-card detection); 2.23 is
the version that added it; 2.25/2.26/2.28B are the later refinements.

## Disk inventory

| Filename | Boot label | Year | Memory | Notes |
|---|---|---|---|---|
| `Softcard 16-sector disk (Microsoft 1980).dsk` | Apple ][ CP/M 44K Ver. 2.20 | 1980 | 44K | Earliest 16-sector release |
| `Microsoft SoftCard - CPM System Disk 2.2.cpm` | Apple ][ CP/M 44K Ver. 2.20B | 1980 | 44K | "2.2" filename is shorthand; boot string says 2.20B |
| `Microsoft SoftCard - CPM Disk 1.po` | Apple ][ CP/M 56K Ver. 2.20B | 1980 | 56K | 56K master, disk 1 of 2 |
| `Microsoft SoftCard - CPM Disk 2.po` | Apple ][ CP/M 56K Ver. 2.20B | 1980 | 56K | 56K master, disk 2 of 2 |
| **`CPMV233.DSK`** | **Softcard CP/M 60K Ver. 2.23** | **1982** | **60K** | **First version with firmware-card support.** Filename "V233" is misleading shorthand for "V2.23"; boot string confirms 2.23. |
| `Microsoft Premium Softcard IIe CPM - (Version 2.25)(...).DSK` | Softcard //e CP/M 64K Version 2.25 | 1983 | 64K | Premium SoftCard //e |
| `CPM226.dsk` (+ `CPM226.txt`) | Softcard //e CP/M 64K Version 2.26 | 1983 | 64K | Standard SoftCard //e |
| `Microsoft Softcard II CPM 2.28B.DSK` | Softcard II CP/M 64K Version 2.28B | 1984 | 64K | Final SoftCard II release |

All disk images are 143,360 bytes (140 KB / 35-track 16-sector .dsk format)
in either DOS-order (.dsk), ProDOS-order (.po), or generic CP/M order (.cpm).

## Sources

- [`mirrors.apple2.org.za`](https://mirrors.apple2.org.za/ftp.apple.asimov.net/images/cpm/os/)
  (Asimov mirror) — provided the 2.20 16-sector, 2.23, 2.25, 2.26, 2.28B images
- [`mirrors.apple2.org.za` Apple II Documentation Project](https://mirrors.apple2.org.za/Apple%20II%20Documentation%20Project/Interface%20Cards/Z80%20Cards/Microsoft%20SoftCard/Disk%20Images/)
  — provided the 2.20B 56K two-disk set and the 2.20B 44K System Disk

## Verification

MD5 checksums of each image:

```
4395a2fc660f6edf835f43db2e45aa84  Softcard 16-sector disk (Microsoft 1980).dsk
8ac3cf6ef41a2f8b3807480ba5205eb6  Microsoft SoftCard - CPM System Disk 2.2.cpm
c2c24f49d7c736e6317f6fe45d8f7468  Microsoft SoftCard - CPM Disk 1.po
a70e4b13e5c2a3314ff32b2f6e004382  Microsoft SoftCard - CPM Disk 2.po
b6ebb2aeb600970ecdf8351860920a8f  CPMV233.DSK
8b5f05e67af5ab457b38df288b7e7b91  Microsoft Premium Softcard IIe CPM - (Version 2.25)(2-189 - 101993)(Cat 2347)(Part 23H47).DSK
3d1070944cd61571e582482ffba54390  CPM226.dsk
df825ff47a3b50792038c79d0a714bb5  Microsoft Softcard II CPM 2.28B.DSK
```

## Cross-reference

- Videoterm firmware ROMs: [`hdl/videx/`](../../hdl/videx/)
  (2.4 / VT-FRM-600 / VT-FRM-602)
- Compatibility narrative:
  [`Videx ROM Version Differences Analysis.md`](../Videx%20ROM%20Version%20Differences%20Analysis.md)
