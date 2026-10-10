#!/usr/bin/env python3
"""Reference implementation of Neill Corlett's ECM format (ecm.c / unecm.c v1.0).

Standard library only.  CLI:
    ecm_reference.py encode IN.bin OUT.ecm
    ecm_reference.py decode IN.ecm OUT.bin
    ecm_reference.py gen-fixtures [DIR]

Layout notes
------------
* Type 0: raw bytes.
* Type 1: mode 1 sector, 2352 bytes in the bin.  Stored: 3 address bytes
  (sector[0xC..0xE]) + 0x800 user data.
* Type 2: mode 2 form 1, 2336 bytes in the bin (the data that begins at
  sector+0x10).  Stored: 0x804 bytes (4-byte subheader + 0x800 data).
* Type 3: mode 2 form 2, 2336 bytes in the bin.  Stored: 0x918 bytes
  (4-byte subheader + 0x914 data).
* Stream: "ECM\\0", blocks (varint type/count), end marker
  FC FF FF FF 3F, then little-endian EDC of all decoded bytes.
"""
import os
import random
import struct
import sys

MAGIC = b"ECM\x00"
END_MARKER = b"\xfc\xff\xff\xff\x3f"


class ECMError(Exception):
    pass


class FileTooShort(ECMError):
    pass


class InvalidHeader(ECMError):
    pass


class TruncatedData(ECMError):
    pass


class InvalidCount(ECMError):
    pass


class ChecksumMismatch(ECMError):
    pass


# --------------------------------------------------------------------------
# LUTs
# --------------------------------------------------------------------------
ECC_F_LUT = [0] * 256
ECC_B_LUT = [0] * 256
EDC_LUT = [0] * 256


def _init_luts():
    for i in range(256):
        j = ((i << 1) ^ (0x11D if i & 0x80 else 0)) & 0xFF
        ECC_F_LUT[i] = j
        ECC_B_LUT[i ^ j] = i
        edc = i
        for _ in range(8):
            edc = (edc >> 1) ^ (0xD8018001 if edc & 1 else 0)
        EDC_LUT[i] = edc


_init_luts()


def edc_partial(edc, data):
    for b in data:
        edc = (edc >> 8) ^ EDC_LUT[(edc ^ b) & 0xFF]
    return edc & 0xFFFFFFFF


def edc_compute(data):
    return edc_partial(0, data)


def _ecc_computeblock(buf, base, major_count, minor_count, major_mult, minor_inc, dest_off):
    """src = buf[base:]; writes into buf at dest_off (in place, like ecm.c)."""
    size = major_count * minor_count
    for major in range(major_count):
        index = (major >> 1) * major_mult + (major & 1)
        ecc_a = 0
        ecc_b = 0
        for _ in range(minor_count):
            temp = buf[base + index]
            index += minor_inc
            if index >= size:
                index -= size
            ecc_a ^= temp
            ecc_b ^= temp
            ecc_a = ECC_F_LUT[ecc_a]
        ecc_a = ECC_B_LUT[ECC_F_LUT[ecc_a] ^ ecc_b]
        buf[dest_off + major] = ecc_a
        buf[dest_off + major + major_count] = ecc_a ^ ecc_b


def ecc_generate(sector, zero_address):
    saved = None
    if zero_address:
        saved = bytes(sector[12:16])
        sector[12:16] = b"\0\0\0\0"
    # P parity first (written in place), then Q computed over data+P.
    _ecc_computeblock(sector, 0xC, 86, 24, 2, 86, 0x81C)
    _ecc_computeblock(sector, 0xC, 52, 43, 86, 88, 0x81C + 86 * 2)
    if zero_address:
        sector[12:16] = saved


def eccedc_generate(sector, type_):
    """sector: bytearray(2352), modified in place."""
    if type_ == 1:
        sector[0x810:0x814] = struct.pack("<I", edc_compute(sector[0:0x810]))
        sector[0x814:0x81C] = b"\0" * 8
        ecc_generate(sector, False)
    elif type_ == 2:
        sector[0x818:0x81C] = struct.pack("<I", edc_compute(sector[0x10:0x10 + 0x808]))
        ecc_generate(sector, True)
    elif type_ == 3:
        sector[0x92C:0x930] = struct.pack("<I", edc_compute(sector[0x10:0x10 + 0x91C]))
    else:
        raise ValueError("bad sector type")


def _blank_sector():
    s = bytearray(2352)
    s[1:11] = b"\xff" * 10
    return s


def sector_from_stored(type_, stored):
    """Rebuild a full 2352-byte working sector from stored bytes (unecm.c)."""
    s = _blank_sector()
    if type_ == 1:
        s[0x0F] = 1
        s[0x0C:0x0F] = stored[0:3]
        s[0x10:0x810] = stored[3:3 + 0x800]
    elif type_ == 2:
        s[0x0F] = 2
        s[0x14:0x14 + 0x804] = stored
        s[0x10:0x14] = s[0x14:0x18]
    elif type_ == 3:
        s[0x0F] = 2
        s[0x14:0x14 + 0x918] = stored
        s[0x10:0x14] = s[0x14:0x18]
    else:
        raise ValueError
    eccedc_generate(s, type_)
    return s


def stored_size(type_):
    return {1: 3 + 0x800, 2: 0x804, 3: 0x918}[type_]


def bin_size(type_):
    return {1: 2352, 2: 2336, 3: 2336}[type_]


# --------------------------------------------------------------------------
# Sector detection
# --------------------------------------------------------------------------
def detect_sector(buf, pos):
    """Return type 0..3 for the sector starting at buf[pos:]."""
    avail = len(buf) - pos
    if avail >= 2352:
        c = buf[pos:pos + 2352]
        if (c[0] == 0 and c[1:11] == b"\xff" * 10 and c[11] == 0 and c[15] == 1
                and c[0x814:0x81C] == b"\0" * 8):
            t = bytearray(c)
            eccedc_generate(t, 1)
            if t == c:
                return 1
    if avail >= 2336:
        c = buf[pos:pos + 2336]
        if c[0:4] == c[4:8]:
            for t_ in (2, 3):
                s = _blank_sector()
                s[0x0F] = 2
                s[0x10:0x930] = c
                eccedc_generate(s, t_)
                if bytes(s[0x10:0x930]) == bytes(c):
                    return t_
    return 0


def stored_from_sector(type_, c):
    if type_ == 1:
        return bytes(c[0x0C:0x0F]) + bytes(c[0x10:0x810])
    if type_ == 2:
        return bytes(c[4:4 + 0x804])
    return bytes(c[4:4 + 0x918])


# --------------------------------------------------------------------------
# Encoder
# --------------------------------------------------------------------------
def _write_type_count(out, type_, count):
    count -= 1
    out.append(((1 << 7) if count >= 32 else 0) | ((count & 31) << 2) | type_)
    count >>= 5
    while count:
        out.append((0x80 if count >= 128 else 0) | (count & 0x7F))
        count >>= 7


def encode(data):
    data = bytes(data)
    out = bytearray(MAGIC)
    pos = 0
    n = len(data)
    cur_type = 0
    cur_count = 0       # sectors, or raw bytes for type 0
    raw_start = 0
    run_stored = bytearray()

    def flush():
        nonlocal cur_count, run_stored
        if cur_count:
            _write_type_count(out, cur_type, cur_count)
            if cur_type == 0:
                out.extend(data[raw_start:raw_start + cur_count])
            else:
                out.extend(run_stored)
        cur_count = 0
        run_stored = bytearray()

    while pos < n:
        t = detect_sector(data, pos)
        if t == 0:
            if cur_type != 0:
                flush()
                cur_type = 0
            if cur_count == 0:
                raw_start = pos
            cur_count += 1
            pos += 1
        else:
            if cur_type != t:
                flush()
                cur_type = t
            size = bin_size(t)
            run_stored += stored_from_sector(t, data[pos:pos + size])
            cur_count += 1
            pos += size
    flush()
    out += END_MARKER
    out += struct.pack("<I", edc_compute(data))
    return bytes(out)


# --------------------------------------------------------------------------
# Decoder
# --------------------------------------------------------------------------
def decode(ecm):
    ecm = bytes(ecm)
    if len(ecm) < 4:
        raise FileTooShort("file too short")
    if ecm[:4] != MAGIC:
        raise InvalidHeader("bad magic")
    pos = 4
    n = len(ecm)
    out = bytearray()
    while True:
        if pos >= n:
            raise TruncatedData("missing end marker")
        c = ecm[pos]
        pos += 1
        type_ = c & 3
        num = (c >> 2) & 0x1F
        bits = 5
        while c & 0x80:
            if pos >= n:
                raise TruncatedData("truncated count")
            c = ecm[pos]
            pos += 1
            if bits > 31:
                raise InvalidCount("count too large")
            num |= ((c & 0x7F) << bits) & 0xFFFFFFFF
            bits += 7
        if num == 0xFFFFFFFF:
            break
        num += 1
        if num >= 0x80000000:          # unecm.c: "goto corrupt"
            raise InvalidCount("count too large")
        if type_ == 0:
            if pos + num > n:
                raise TruncatedData("raw block truncated")
            out += ecm[pos:pos + num]
            pos += num
        else:
            sz = stored_size(type_)
            if pos + sz * num > n:
                raise TruncatedData("sector block truncated")
            for _ in range(num):
                s = sector_from_stored(type_, ecm[pos:pos + sz])
                pos += sz
                if type_ == 1:
                    out += s
                else:
                    out += s[0x10:0x930]
    if pos + 4 > n:
        raise TruncatedData("missing EDC trailer")
    want = struct.unpack("<I", ecm[pos:pos + 4])[0]
    got = edc_compute(out)
    if want != got:
        raise ChecksumMismatch("EDC mismatch: file %08X computed %08X" % (want, got))
    return bytes(out)


# --------------------------------------------------------------------------
# Synthetic sector generators (for tests / fixtures)
# --------------------------------------------------------------------------
def _msf(i):
    lba = i + 150
    bcd = lambda v: ((v // 10) << 4) | (v % 10)
    return bytes([bcd(lba // 4500), bcd((lba // 75) % 60), bcd(lba % 75)])


def make_mode1(rng, index=0):
    s = _blank_sector()
    s[0x0C:0x0F] = _msf(index)
    s[0x0F] = 1
    s[0x10:0x810] = bytes(rng.getrandbits(8) for _ in range(0x800))
    eccedc_generate(s, 1)
    return bytes(s)


def make_mode2_form1(rng):
    """2336 bytes starting at sector+0x10."""
    s = _blank_sector()
    s[0x0F] = 2
    sub = bytes([0, 0, 0x08, 0])
    s[0x10:0x14] = sub
    s[0x14:0x18] = sub
    s[0x18:0x818] = bytes(rng.getrandbits(8) for _ in range(0x800))
    eccedc_generate(s, 2)
    return bytes(s[0x10:0x930])


def make_mode2_form2(rng):
    s = _blank_sector()
    s[0x0F] = 2
    sub = bytes([0, 0, 0x20, 0])
    s[0x10:0x14] = sub
    s[0x14:0x18] = sub
    s[0x18:0x92C] = bytes(rng.getrandbits(8) for _ in range(0x914))
    eccedc_generate(s, 3)
    return bytes(s[0x10:0x930])


def make_garbage(rng, n):
    return bytes(rng.getrandbits(8) for _ in range(n))


def build_mixed(seed=1234):
    rng = random.Random(seed)
    img = bytearray()
    img += make_garbage(rng, 5000)              # long raw run (multi-byte count)
    for i in range(5):
        img += make_mode1(rng, i)
    img += make_garbage(rng, 777)
    for _ in range(3):
        img += make_mode2_form1(rng)
    for _ in range(3):
        img += make_mode2_form2(rng)
    img += b"\0" * 100
    img += make_mode1(rng, 99)
    img += make_garbage(rng, 13)
    return bytes(img)


def build_mode1(seed=42, count=34):
    rng = random.Random(seed)
    return b"".join(make_mode1(rng, i) for i in range(count))


def build_mode2(seed=7):
    rng = random.Random(seed)
    img = bytearray()
    for _ in range(6):
        img += make_mode2_form1(rng)
    for _ in range(6):
        img += make_mode2_form2(rng)
    for _ in range(4):
        img += make_mode2_form1(rng)
    return bytes(img)


def gen_fixtures(outdir):
    os.makedirs(outdir, exist_ok=True)

    def w(name, data):
        with open(os.path.join(outdir, name), "wb") as f:
            f.write(data)

    for name, img in (("mixed", build_mixed()), ("mode1", build_mode1()), ("mode2", build_mode2())):
        e = encode(img)
        assert decode(e) == img
        w(name + ".bin", img)
        w(name + ".ecm", e)
    mixed = encode(build_mixed())
    w("truncated.ecm", mixed[: len(mixed) // 2])
    bad = bytearray(mixed)
    bad[-1] ^= 0xFF
    w("badchecksum.ecm", bytes(bad))
    bad = bytearray(mixed)
    bad[0:4] = b"XYZ\x00"
    w("badheader.ecm", bytes(bad))
    w("tooshort.ecm", b"ECM")
    # count with too many continuation bytes: type 0, bits will exceed 31
    w("badcount.ecm", MAGIC + b"\x80\x80\x80\x80\x80\x80\x80\x00")
    # missing end marker + trailer entirely (cut right after last block)
    w("noend.ecm", mixed[: len(mixed) - 9])


def main(argv):
    if len(argv) >= 2 and argv[1] == "gen-fixtures":
        d = argv[2] if len(argv) > 2 else os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "..", "Tests", "ECMCoreTests", "Fixtures")
        gen_fixtures(d)
        return 0
    if len(argv) == 4 and argv[1] in ("encode", "decode"):
        with open(argv[2], "rb") as f:
            data = f.read()
        try:
            res = encode(data) if argv[1] == "encode" else decode(data)
        except ECMError as e:
            sys.stderr.write("error: %s: %s\n" % (type(e).__name__, e))
            return 1
        with open(argv[3], "wb") as f:
            f.write(res)
        return 0
    sys.stderr.write(__doc__ + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
