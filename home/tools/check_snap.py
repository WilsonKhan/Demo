#!/usr/bin/env python3
"""check_snap.py -- the Python half of snap_tb (the JTAG frame grab, frame_snap.sv): read each snapshot's memory the
three ways a student can, decode it as a student would, and compare it with what the bench says was kept.
PASS/FAIL lines; exit status 0 only if all passed.

    check_snap.py DIR K [--label TEXT] [--stats]
        DIR/snap_K.words              the memory, as the bench read it (one 4-digit hex word a line, address 0 first)
        DIR/expected_K.hex            the picture the bench knows was kept (4 hex digits a line, or 2 for grey)
        DIR/expected_results_K.txt    that frame's result words (8 hex digits a line)

The three ways, each into its own folder, and each must give the same frame.hex and results:
    1. what tcl/grab_jtag.tcl does: read_content_from_memory's strings (written here as DIR/snap_K.stp, the
       highest address first in each string, as quartus_stp returns them) put back in address order as bytes,
       then tools/grab.py --file                                                          -> DIR/grab_K
    2. the In-System Memory Content Editor's export as a .mif (ranges and runs, as Quartus writes them),
       then tools/jtag_export.py                                                          -> DIR/mif_K
    3. its export as Intel HEX (word addresses, type-04 records above 64K words), then tools/jtag_export.py
                                                                                          -> DIR/hex_K
--stats  also run the golden model of rtl/frame_stats.sv on the pixels: words 1-4 must match. Only for SNAP_MODE 0's
         320 x 240 RGB565 picture, the one frame_stats counts over (a smaller or grey picture does not hold it).
"""
import json
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import grab  # noqa: E402

fails = 0


def report(ok, text):
    global fails
    print(("PASS: " if ok else "FAIL: ") + text)
    if not ok:
        fails += 1


def run(script, args):
    p = subprocess.run([sys.executable, os.path.join(HERE, script)] + args, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def stp_strings(words, chunk=19200):
    """read_content_from_memory -content_in_hex, chunk by chunk: each string has the HIGHEST address first."""
    lines = []
    for s in range(0, len(words), chunk):
        part = words[s:s + chunk]
        lines.append(f"{s} {len(part)} " + "".join(f"{w:04X}" for w in reversed(part)))
    return lines


def from_stp(lines):
    """What tcl/grab_jtag.tcl does with those strings: back into address order, as bytes."""
    out = bytearray()
    for line in lines:
        s, n, hexs = line.split()
        n = int(n)
        ws = [hexs[4 * k:4 * k + 4] for k in range(n)]
        out += bytes.fromhex("".join(reversed(ws)))
    return bytes(out)


def to_mif(words):
    """A .mif as Quartus writes one: runs of one value as [first..last], other words one a line (unsigned decimal
    addresses, hex data)."""
    out = ["-- the frame grab's memory, as the In-System Memory Content Editor exports it (made by check_snap.py)",
           "WIDTH=16;", f"DEPTH={len(words)};", "", "ADDRESS_RADIX=UNS;", "DATA_RADIX=HEX;", "", "CONTENT BEGIN"]
    a = 0
    while a < len(words):
        b = a
        while b + 1 < len(words) and words[b + 1] == words[a]:
            b += 1
        if b > a:
            out.append(f"\t[{a}..{b}]  :   {words[a]:04X};")
        elif a + 2 < len(words) and a % 7 == 3:                # now and then several values on one line
            out.append(f"\t{a}    :   {words[a]:04X} {words[a + 1]:04X} {words[a + 2]:04X};")
            b = a + 2
        else:
            out.append(f"\t{a}    :   {words[a]:04X};")
        a = b + 1
    out.append("END;")
    return "\n".join(out) + "\n"


def to_intel_hex(words):
    """Intel HEX as Quartus writes a memory: one word a record, the address in words, type 04 above 64K words."""
    out, upper = [], -1
    for a, w in enumerate(words):
        if a >> 16 != upper:
            upper = a >> 16
            rec = bytes([2, 0, 0, 4, upper >> 8, upper & 0xFF])
            out.append(":" + rec.hex().upper() + f"{(-sum(rec)) & 0xFF:02X}")
        rec = bytes([2, (a >> 8) & 0xFF, a & 0xFF, 0, w >> 8, w & 0xFF])
        out.append(":" + rec.hex().upper() + f"{(-sum(rec)) & 0xFF:02X}")
    out.append(":00000001FF")
    return "\n".join(out) + "\n"


def frame_stats_golden(px):
    """rtl/frame_stats.sv words 1-4 from RGB565 pixels."""
    rgb = grab.rgb565_to_rgb888(px).astype(np.int64)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    grey = (r + 2 * g + b) >> 2
    red = (r >= 128) & (g < 96) & (b < 96)
    v, u = np.indices(px.shape)
    return [int(red.sum()), int((u * red).sum()), int((v * red).sum()), int(grey.sum())]


def main():
    args = sys.argv[1:]
    label = None
    if "--label" in args:
        i = args.index("--label")
        label = args[i + 1]
        del args[i:i + 2]
    stats = "--stats" in args
    args = [a for a in args if not a.startswith("--")]
    d, k = args[0], args[1]
    label = label or f"snapshot {k}"
    words = [int(s, 16) for s in open(os.path.join(d, f"snap_{k}.words")).read().split()]
    want_px = [int(s, 16) for s in open(os.path.join(d, f"expected_{k}.hex")).read().split()]
    want_res = [int(s, 16) for s in open(os.path.join(d, f"expected_results_{k}.txt")).read().split()]

    # the three ways in
    lines = stp_strings(words)
    open(os.path.join(d, f"snap_{k}.stp"), "w").write("\n".join(lines) + "\n")
    raw = from_stp(lines)
    open(os.path.join(d, f"snap_{k}.bin"), "wb").write(raw)
    open(os.path.join(d, f"snap_{k}.mif"), "w").write(to_mif(words))
    open(os.path.join(d, f"snap_{k}.hex"), "w").write(to_intel_hex(words))
    ways = [("grab.py --file", "grab.py", ["--file", os.path.join(d, f"snap_{k}.bin"), "--out", os.path.join(d, f"grab_{k}")], f"grab_{k}"),
            ("jtag_export.py .mif", "jtag_export.py", [os.path.join(d, f"snap_{k}.mif"), "--out", os.path.join(d, f"mif_{k}")], f"mif_{k}"),
            ("jtag_export.py .hex", "jtag_export.py", [os.path.join(d, f"snap_{k}.hex"), "--out", os.path.join(d, f"hex_{k}")], f"hex_{k}")]
    got = []
    for name, script, a, sub in ways:
        rc, text = run(script, a)
        if rc != 0:
            report(False, f"{label}: {name} rejected it: {text.strip()}")
            got.append(None)
            continue
        info = json.load(open(os.path.join(d, sub, "results.json")))
        px = [int(s, 16) for s in open(os.path.join(d, sub, "frame.hex")).read().split()]
        got.append((info, px))
    if any(g is None for g in got):
        return 1
    info, px = got[0]
    bad_px = sum(1 for a, b in zip(px, want_px) if a != b) + abs(len(px) - len(want_px))
    bad_res = [i for i, (a, b) in enumerate(zip(info["results"], want_res)) if a != b] + (["count"] if len(info["results"]) != len(want_res) else [])
    report(bad_px == 0 and not bad_res and info["crc_ok"],
           f"{label}: {info['width']} x {info['height']} {info['pixel_format']}: {len(want_px) - bad_px} of {len(want_px)} pixels and "
           f"{len(want_res) - len(bad_res)} of {len(want_res)} result words match what the bench kept; the CRC ({info['crc']}) checks")
    same = all(g[1] == px and g[0]["results"] == info["results"] and g[0]["crc"] == info["crc"] for g in got[1:])
    same_scene = all(open(os.path.join(d, w[3], "scene.hex")).read() == open(os.path.join(d, f"grab_{k}", "scene.hex")).read() for w in ways[1:])
    report(same and same_scene, f"{label}: the editor's exports (.mif and Intel HEX, decoded by jtag_export.py) give the same pixels, "
                                f"words, CRC and scene.hex as tcl/grab_jtag.tcl's way (grab.py on the memory's bytes)")
    if stats and (info["pixel_format"], info["width"], info["height"]) != ("RGB565", 320, 240):
        print(f"{label}: no golden model: frame_stats counts over the 320 x 240 RGB565 picture (SNAP_MODE 0), and "
              f"this one is {info['width']} x {info['height']} {info['pixel_format']}")
    elif stats:
        golden = frame_stats_golden(np.array(px, dtype=np.uint16).reshape(info["height"], info["width"]))
        report(golden == info["results"][1:5], f"{label}: golden model (Python frame_stats on frame.hex) = {golden}; "
                                               f"the design sent {info['results'][1:5]}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
