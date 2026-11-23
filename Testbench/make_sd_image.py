#!/usr/bin/env python3
"""
make_sd_image.py -- builds a fake SD card for tb_audio.sv.

It writes a tiny FAT32 "card" with a WAV file on it, plus the list of samples
the testbench should hear coming out of the audio chip. Only the sectors that
are not all zero are written out, so the card can pretend to be 40 MB while the
files stay small.

The card is deliberately awkward, to exercise the reader:
  * the partition does not start at sector 0 (there is an MBR in front);
  * the root folder has a volume label, a deleted file, a long-file-name
    entry and another file before SONG.WAV;
  * SONG.WAV starts above cluster 65535 (needs the FAT32 high-word fix);
  * its clusters are NOT next to each other, and the chain crosses from one
    FAT sector to the next;
  * the WAV has a LIST chunk between "fmt " and "data" that must be skipped.

Outputs (in --out):
  sd_map.hex       one line per stored sector: its sector number
  sd_data.hex      256 x 16-bit words per stored sector, little endian
  expected.hex     one line per sample: {left, right} as 8 hex digits
  params.vh        `define lines with the counts, for the testbench
"""

import argparse
import os
import struct

SECTOR = 512


def build(out, rate, channels, frames, file_name):
    sectors = {}

    def put(lba, offset, data):
        buf = sectors.setdefault(lba, bytearray(SECTOR))
        buf[offset:offset + len(data)] = data

    def put_bytes(lba, data):
        """Write data starting at sector lba, spilling into following sectors."""
        for i in range(0, len(data), SECTOR):
            put(lba + i // SECTOR, 0, data[i:i + SECTOR])

    # ---- geometry -----------------------------------------------------------
    PART_LBA = 64
    RESERVED = 32
    N_FATS = 2
    FAT_SECTORS = 640                  # enough FAT for ~81000 clusters
    SPC = 2                            # sectors per cluster (1 KB clusters)
    ROOT_CLUSTER = 2
    fat_lba = PART_LBA + RESERVED
    data_lba = fat_lba + N_FATS * FAT_SECTORS

    def cluster_lba(c):
        return data_lba + (c - 2) * SPC

    # ---- MBR ----------------------------------------------------------------
    entry = struct.pack("<B3sB3sII", 0x00, b"\x00\x02\x00", 0x0C, b"\xff\xff\xff",
                        PART_LBA, 80000 * SPC + data_lba)
    put(0, 0x1BE, entry)
    put(0, 0x1FE, b"\x55\xaa")

    # ---- FAT32 boot sector ---------------------------------------------------
    bs = bytearray(SECTOR)
    bs[0:3] = b"\xeb\x58\x90"
    bs[3:11] = b"MSWIN4.1"
    struct.pack_into("<HBHBHHBHHHII", bs, 0x0B,
                     512, SPC, RESERVED, N_FATS, 0, 0, 0xF8, 0, 63, 255, PART_LBA,
                     80000 * SPC + data_lba)
    struct.pack_into("<IHHIHH", bs, 0x24, FAT_SECTORS, 0, 0, ROOT_CLUSTER, 1, 6)
    bs[0x40] = 0x80
    bs[0x42] = 0x29
    bs[0x47:0x52] = b"GH TEST    "
    bs[0x52:0x5A] = b"FAT32   "
    bs[0x1FE:0x200] = b"\x55\xaa"
    put(PART_LBA, 0, bs)

    # ---- the WAV file ------------------------------------------------------
    samples = []
    for i in range(frames):
        left = (i * 7 + 1) & 0xFFFF
        right = (0x8000 + i * 13) & 0xFFFF
        samples.append((left, left) if channels == 1 else (left, right))

    pcm = bytearray()
    for left, right in samples:
        pcm += struct.pack("<H", left)
        if channels == 2:
            pcm += struct.pack("<H", right)

    fmt = struct.pack("<HHIIHH", 1, channels, rate, rate * channels * 2, channels * 2, 16)
    lst = b"INFOINAM" + struct.pack("<I", 5) + b"Song\x00" + b"\x00"   # odd -> pad
    body = (b"WAVE"
            + b"fmt " + struct.pack("<I", len(fmt)) + fmt
            + b"LIST" + struct.pack("<I", len(lst) - 1) + lst
            + b"data" + struct.pack("<I", len(pcm)) + pcm)
    wav = b"RIFF" + struct.pack("<I", len(body)) + body

    # ---- clusters for the WAV: fragmented, starting above 65535 -------------
    n_clusters = (len(wav) + SPC * SECTOR - 1) // (SPC * SECTOR)
    chain = []
    c = 70010                                         # FAT sector 546, chain runs into 547
    while len(chain) < n_clusters:
        chain.append(c)
        c += 3 if len(chain) % 4 == 0 else 1          # a gap every 4 clusters
    for i, cl in enumerate(chain):
        chunk = wav[i * SPC * SECTOR:(i + 1) * SPC * SECTOR]
        put_bytes(cluster_lba(cl), chunk)

    # A small other file in cluster 3.
    other = b"not the song\n"
    put_bytes(cluster_lba(3), other)

    # ---- FAT -----------------------------------------------------------------
    fat = {0: 0x0FFFFFF8, 1: 0x0FFFFFFF, ROOT_CLUSTER: 0x0FFFFFFF, 3: 0x0FFFFFFF}
    for a, b in zip(chain, chain[1:]):
        fat[a] = b
    fat[chain[-1]] = 0x0FFFFFFF
    for n in range(N_FATS):
        for cl, val in fat.items():
            lba = fat_lba + n * FAT_SECTORS + (cl * 4) // SECTOR
            put(lba, (cl * 4) % SECTOR, struct.pack("<I", val))

    # ---- root directory ------------------------------------------------------
    def short_entry(name83, attr, cluster, size):
        return struct.pack("<11sBBBHHHHHHHI", name83, attr, 0, 0, 0, 0, 0,
                           cluster >> 16, 0, 0, cluster & 0xFFFF, size)

    def lfn_entries(long_name, short83):
        csum = 0
        for ch in short83:
            csum = (((csum & 1) << 7) + (csum >> 1) + ch) & 0xFF
        chars = [ord(ch) for ch in long_name] + [0]
        while len(chars) % 13:
            chars.append(0xFFFF)
        parts = [chars[i:i + 13] for i in range(0, len(chars), 13)]
        out = b""
        for seq in range(len(parts), 0, -1):
            p = parts[seq - 1]
            order = seq | (0x40 if seq == len(parts) else 0)
            out += (struct.pack("<B5H", order, *p[0:5]) + bytes([0x0F, 0, csum])
                    + struct.pack("<6H", *p[5:11]) + b"\x00\x00"
                    + struct.pack("<2H", *p[11:13]))
        return out

    target_83 = file_name.upper().split(".")
    target_83 = (target_83[0].ljust(8) + target_83[1].ljust(3)).encode()

    root = b""
    root += short_entry(b"GH TEST    ", 0x08, 0, 0)                 # volume label
    root += b"\xe5" + short_entry(b"OLDSONG WAV", 0x20, 5, 100)[1:]  # deleted
    root += lfn_entries("A Long File Name.txt", b"ALONGF~1TXT")
    root += short_entry(b"ALONGF~1TXT", 0x20, 3, len(other))
    root += short_entry(target_83, 0x20, chain[0], len(wav))
    put_bytes(cluster_lba(ROOT_CLUSTER), root)

    # ---- write it out -------------------------------------------------------
    os.makedirs(out, exist_ok=True)
    used = sorted(lba for lba, buf in sectors.items() if any(buf))
    with open(os.path.join(out, "sd_map.hex"), "w") as f:
        for lba in used:
            f.write(f"{lba:08x}\n")
    with open(os.path.join(out, "sd_data.hex"), "w") as f:
        for lba in used:
            buf = sectors[lba]
            for w in range(256):
                f.write(f"{buf[2 * w] | (buf[2 * w + 1] << 8):04x}\n")
    with open(os.path.join(out, "expected.hex"), "w") as f:
        for left, right in samples:
            f.write(f"{left:04x}{right:04x}\n")
    with open(os.path.join(out, "params.vh"), "w") as f:
        f.write(f"`define N_SECTORS {len(used)}\n")
        f.write(f"`define N_SAMPLES {len(samples)}\n")
        f.write(f"`define FRAME_BCLKS {272 if rate == 44100 else 250}\n")
        f.write(f"`define R8_EXPECTED 9'h{0x023 if rate == 44100 else 0x001:03x}\n")

    print(f"{out}: {len(used)} sectors, WAV {len(wav)} bytes in clusters "
          f"{chain[0]}..{chain[-1]} ({len(chain)}), {len(samples)} samples, "
          f"{rate} Hz, {channels} ch, file {target_83.decode()!r}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--rate", type=int, default=48000)
    ap.add_argument("--channels", type=int, default=2)
    ap.add_argument("--frames", type=int, default=2500)
    ap.add_argument("--name", default="song.wav", help="file name to put on the card")
    a = ap.parse_args()
    build(a.out, a.rate, a.channels, a.frames, a.name)
