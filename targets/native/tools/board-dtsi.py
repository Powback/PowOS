#!/usr/bin/env python3
"""Writes dts/sm8550-oneplus-xueying-board.dtsi from the phone's live stock device tree (phone.sh dump):
qcom,msm-id and qcom,board-id (the bootloader picks a DTB by them) and the splash region the bootloader keeps lit.

    board-dtsi.py device-tree.tar > dts/sm8550-oneplus-xueying-board.dtsi
The tar is /sys/firmware/devicetree/base (properties as files, big-endian 32-bit cells)."""
import struct, sys, tarfile

t = tarfile.open(sys.argv[1])
props = {m.name.split("base/", 1)[1]: t.extractfile(m).read() for m in t.getmembers() if m.isfile() and "base/" in m.name}


def cells(name):
    raw = props.get(name)
    if raw is None:
        return None
    return list(struct.unpack(f">{len(raw) // 4}I", raw[: len(raw) // 4 * 4]))


def hexcells(c):
    return " ".join(f"0x{v:x}" for v in c)


msm, board = cells("qcom,msm-id"), cells("qcom,board-id")
if not msm or not board:
    sys.exit("no qcom,msm-id / qcom,board-id in the dump - is this the stock Android device tree?")
splash = next((k for k in props if k.startswith("reserved-memory/splash") and k.endswith("/reg")), None)
model = props.get("model", b"?").rstrip(b"\0").decode(errors="replace")

out = ["// SPDX-License-Identifier: BSD-3-Clause",
       f"/* OnePlus Open per-unit values, read by phone.sh dump from the stock device tree (model \"{model}\"). */",
       "/ {",
       f"\tqcom,msm-id = <{hexcells(msm)}>;",
       f"\tqcom,board-id = <{hexcells(board)}>;",
       "};"]
if splash:
    a_hi, a_lo, s_hi, s_lo = cells(splash)[:4]
    addr, size = a_hi << 32 | a_lo, s_hi << 32 | s_lo
    out += ["",
            "/* The bootloader keeps the display lit only while this region is named exactly 'splash_region'. */",
            "&{/reserved-memory} {",
            f"\tsplash_region: splash_region@{addr:x} {{",
            f"\t\treg = <0x{a_hi:x} 0x{a_lo:x} 0x{s_hi:x} 0x{s_lo:x}>;",
            "\t\tno-map;",
            "\t};",
            "};"]
else:
    out.append("/* no reserved-memory/splash* node in the stock tree: no early framebuffer */")
print("\n".join(out))
