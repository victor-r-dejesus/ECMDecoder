#!/usr/bin/env python3
"""Faithful Python port of the ORIGINAL Swift decoder (git d94fb08,
Sources/ECMCore/ECMDecoder.swift), including its bugs, run against the
fixtures and compared with the reference implementation.

Usage: python3 Tools/swift_port_check.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ecm_reference as ref

FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                   "Tests", "ECMCoreTests", "Fixtures")


class SwiftError(Exception):
    pass


def _ecc_compute_block(src, major_count, minor_count, major_mult, minor_inc):
    size = major_count * minor_count
    dest = [0] * (major_count * 2)
    for major in range(major_count):
        index = (major >> 1) * major_mult + (major & 1)
        a = b = 0
        for _ in range(minor_count):
            t = src[index]
            index += minor_inc
            if index >= size:
                index -= size
            a ^= t
            b ^= t
            a = ref.ECC_F_LUT[a]
        a = ref.ECC_B_LUT[ref.ECC_F_LUT[a] ^ b]
        dest[major] = a
        dest[major + major_count] = a ^ b
    return dest


def _ecc_generate(sector, zero_address):
    saved = [0] * 4
    if zero_address:
        for i in range(4):
            saved[i] = sector[12 + i]
            sector[12 + i] = 0
    src = list(sector[12:])       # BUG: snapshot taken before P parity is written
    d1 = _ecc_compute_block(src, 86, 24, 2, 86)
    d2 = _ecc_compute_block(src, 52, 43, 86, 88)   # Q sees stale (zero) P region
    for i, v in enumerate(d1):
        sector[0x81C + i] = v
    for i, v in enumerate(d2):
        sector[0x8C8 + i] = v
    if zero_address:
        for i in range(4):
            sector[12 + i] = saved[i]


def swift_eccedc_generate(sector, type_):
    if type_ == 1:
        e = ref.edc_compute(bytes(sector[0:0x810]))
        sector[0x810:0x814] = e.to_bytes(4, "little")
        for i in range(8):
            sector[0x814 + i] = 0
        _ecc_generate(sector, False)
    elif type_ == 2:
        e = ref.edc_compute(bytes(sector[0x10:0x10 + 0x808]))
        sector[0x818:0x81C] = e.to_bytes(4, "little")
        _ecc_generate(sector, True)
    elif type_ == 3:
        e = ref.edc_compute(bytes(sector[0x10:0x10 + 0x91C]))
        sector[0x92C:0x930] = e.to_bytes(4, "little")


def swift_decode(data):
    """Returns output bytes; mirrors every `break`/`guard` of the Swift code."""
    out = bytearray()
    offset = 0
    n = len(data)
    if not n > 4:
        raise SwiftError("File too short")
    if not (data[0] == 0x45 and data[1] == 0x43 and data[2] == 0x4D and data[3] == 0):
        raise SwiftError("Header not found")
    offset = 4
    while offset < n:
        c = data[offset]; offset += 1
        type_ = c & 3
        num = (c >> 2) & 0x1F
        bits = 5
        while c & 0x80:
            if not offset < n:
                break                      # silent
            c = data[offset]; offset += 1
            num |= (c & 0x7F) << bits      # no bits>31 check
            bits += 7
        if num == 0xFFFFFFFF:
            break                          # EDC trailer never read/verified
        num += 1
        if type_ == 0:
            if not offset + num <= n:
                break                      # silent truncation, exits outer loop
            out += data[offset:offset + num]
            offset += num
        else:
            for _ in range(num):
                sb = bytearray(2352)
                for i in range(1, 11):
                    sb[i] = 0xFF
                if type_ == 1:
                    sb[0x0F] = 1
                    if not offset + 3 + 0x800 <= n:
                        continue           # `break` leaves only the switch; loop spins on
                    sb[0x0C:0x0F] = data[offset:offset + 3]; offset += 3
                    sb[0x10:0x810] = data[offset:offset + 0x800]; offset += 0x800
                    swift_eccedc_generate(sb, 1)
                    out += sb
                elif type_ == 2:
                    sb[0x0F] = 2
                    if not offset + 0x804 <= n:
                        continue
                    sb[0x14:0x14 + 0x804] = data[offset:offset + 0x804]; offset += 0x804
                    # BUG: sb[0x10:0x14] (subheader copy) never filled
                    swift_eccedc_generate(sb, 2)
                    out += sb[0x10:0x10 + 2336]
                elif type_ == 3:
                    sb[0x0F] = 2
                    if not offset + 0x918 <= n:
                        continue
                    sb[0x14:0x14 + 0x918] = data[offset:offset + 0x918]; offset += 0x918
                    swift_eccedc_generate(sb, 3)
                    out += sb[0x10:0x10 + 2336]
    return bytes(out)


def rd(name):
    with open(os.path.join(FIX, name), "rb") as f:
        return f.read()


def first_diff(a, b):
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            return i
    return min(len(a), len(b)) if len(a) != len(b) else -1


def report():
    print("== Round-trip fixtures: original Swift logic vs expected .bin ==")
    results = {}
    for name in ("mode1", "mode2", "mixed"):
        exp = rd(name + ".bin")
        got = swift_decode(rd(name + ".ecm"))
        ok = got == exp
        results[name] = ok
        d = first_diff(got, exp)
        nbad = sum(1 for x, y in zip(got, exp) if x != y)
        print("%-6s len got=%d exp=%d  %s  first_diff=%d  differing_bytes=%d" % (
            name, len(got), len(exp), "MATCH" if ok else "MISMATCH", d, nbad))
    print()
    print("== Mode 1 sector breakdown (first sector) ==")
    exp = rd("mode1.bin")[:2352]
    got = swift_decode(rd("mode1.ecm"))[:2352]
    print("data+EDC+P region (0..0x8C7) equal:", got[:0x8C8] == exp[:0x8C8])
    print("Q parity (0x8C8..0x92F) equal     :", got[0x8C8:] == exp[0x8C8:])
    print()
    print("== Mode 2 form 1 chunk (first 2336) ==")
    exp = rd("mode2.bin")[:2336]
    got = swift_decode(rd("mode2.ecm"))[:2336]
    print("subheader copy bytes expected %s got %s" % (exp[0:4].hex(), got[0:4].hex()))
    print("rest equal except subheader copy:", got[4:] == exp[4:], "(P/Q differ: %s)" % (got[0x80C:] != exp[0x80C:]))
    print()
    print("== Error-case handling (reference raises; Swift port?) ==")
    for name in ("truncated.ecm", "noend.ecm", "badchecksum.ecm", "badcount.ecm"):
        try:
            ref.decode(rd(name)); r = "NO ERROR"
        except ref.ECMError as e:
            r = type(e).__name__
        try:
            out = swift_decode(rd(name)); s = "returned %d bytes, no error" % len(out)
        except SwiftError as e:
            s = "threw: %s" % e
        print("%-16s reference: %-17s swift-port: %s" % (name, r, s))
    for name in ("badheader.ecm", "tooshort.ecm"):
        try:
            swift_decode(rd(name)); s = "NO ERROR"
        except SwiftError as e:
            s = "threw: %s" % e
        print("%-16s swift-port: %s" % (name, s))
    return results


if __name__ == "__main__":
    report()
