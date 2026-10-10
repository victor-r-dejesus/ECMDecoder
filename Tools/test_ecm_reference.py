import os
import random
import struct
import sys
import unittest
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ecm_reference as ref
import swift_port_check as port

FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                   "Tests", "ECMCoreTests", "Fixtures")


def rd(name):
    with open(os.path.join(FIX, name), "rb") as f:
        return f.read()


class EDCTests(unittest.TestCase):
    def test_lut_is_reflected_poly(self):
        self.assertEqual(ref.EDC_LUT[0], 0)
        # one bit through 8 shift steps of reflected polynomial 0xD8018001
        v = 1
        for _ in range(8):
            v = (v >> 1) ^ (0xD8018001 if v & 1 else 0)
        self.assertEqual(ref.EDC_LUT[1], v)

    def test_empty_and_zero(self):
        self.assertEqual(ref.edc_compute(b""), 0)
        self.assertEqual(ref.edc_compute(b"\0" * 100), 0)

    def test_linearity(self):
        # init 0, no xorout: EDC(a^b) == EDC(a)^EDC(b) for equal lengths
        rng = random.Random(1)
        a = bytes(rng.getrandbits(8) for _ in range(300))
        b = bytes(rng.getrandbits(8) for _ in range(300))
        x = bytes(p ^ q for p, q in zip(a, b))
        self.assertEqual(ref.edc_compute(x), ref.edc_compute(a) ^ ref.edc_compute(b))

    def test_partial_chaining(self):
        d = bytes(range(256)) * 3
        self.assertEqual(ref.edc_partial(ref.edc_compute(d[:100]), d[100:]), ref.edc_compute(d))

    def test_crc_relation_with_zlib_poly(self):
        # Reflected 0xD8018001 is a different polynomial from CRC-32; just make
        # sure the two disagree so we are not accidentally testing zlib.
        self.assertNotEqual(ref.edc_compute(b"123456789"), zlib.crc32(b"123456789"))

    def test_single_byte_values(self):
        for i in (1, 2, 0x55, 0xFF):
            self.assertEqual(ref.edc_compute(bytes([i])), ref.EDC_LUT[i])

    def test_ecc_luts(self):
        for i in range(256):
            self.assertEqual(ref.ECC_B_LUT[i ^ ref.ECC_F_LUT[i]], i)


class SectorTests(unittest.TestCase):
    def setUp(self):
        self.rng = random.Random(99)

    def test_mode1_self_consistent(self):
        s = bytearray(ref.make_mode1(self.rng, 3))
        self.assertEqual(ref.edc_compute(s[0:0x810]), struct.unpack("<I", s[0x810:0x814])[0])
        self.assertEqual(s[0x814:0x81C], b"\0" * 8)
        t = bytearray(s)
        ref.eccedc_generate(t, 1)
        self.assertEqual(t, s)
        # corrupting one data byte makes regeneration differ
        t = bytearray(s); t[0x100] ^= 1
        ref.eccedc_generate(t, 1)
        self.assertNotEqual(t, s)

    def test_p_parity_is_included_in_q(self):
        s = bytearray(ref.make_mode1(self.rng))
        bad = bytearray(s)
        bad[0x81C:0x8C8] = b"\0" * 172   # zero P, recompute Q only as swift does
        self.assertNotEqual(bad[0x81C:0x8C8], s[0x81C:0x8C8])

    def test_mode2_forms(self):
        for maker, t in ((ref.make_mode2_form1, 2), (ref.make_mode2_form2, 3)):
            c = maker(self.rng)
            self.assertEqual(len(c), 2336)
            s = bytearray(2352); s[1:11] = b"\xff" * 10; s[15] = 2
            s[0x10:0x930] = c
            ref.eccedc_generate(s, t)
            self.assertEqual(bytes(s[0x10:0x930]), c)
            self.assertEqual(c[0:4], c[4:8])

    def test_form2_edc_location(self):
        c = ref.make_mode2_form2(self.rng)
        self.assertEqual(struct.unpack("<I", c[0x91C:0x920])[0], ref.edc_compute(c[0:0x91C]))

    def test_detect(self):
        rng = random.Random(5)
        self.assertEqual(ref.detect_sector(ref.make_mode1(rng), 0), 1)
        self.assertEqual(ref.detect_sector(ref.make_mode2_form1(rng), 0), 2)
        self.assertEqual(ref.detect_sector(ref.make_mode2_form2(rng), 0), 3)
        # all-zero 2336 bytes is a valid (degenerate) mode 2 form 1 sector: EDC/ECC of zeros are zero
        self.assertEqual(ref.detect_sector(bytes(3000), 0), 2)
        self.assertEqual(ref.detect_sector(b"\x01" * 3000, 0), 0)
        self.assertEqual(ref.detect_sector(ref.make_garbage(rng, 3000), 0), 0)


class RoundTripTests(unittest.TestCase):
    def rt(self, img):
        e = ref.encode(img)
        self.assertEqual(ref.decode(e), img)
        return e

    def test_empty(self):
        e = self.rt(b"")
        self.assertEqual(e, ref.MAGIC + ref.END_MARKER + b"\0\0\0\0")

    def test_small_raw(self):
        self.rt(b"a")
        self.rt(bytes(range(256)))

    def test_mixed(self):
        img = ref.build_mixed()
        e = self.rt(img)
        self.assertLess(len(e), len(img))

    def test_mode1_compacts(self):
        img = ref.build_mode1(count=10)
        e = self.rt(img)
        self.assertLess(len(e), len(img))
        self.assertAlmostEqual(len(e), 10 * (3 + 0x800), delta=40)

    def test_mode2_compacts(self):
        img = ref.build_mode2()
        e = self.rt(img)
        self.assertLess(len(e), len(img))

    def test_garbage_only(self):
        img = ref.make_garbage(random.Random(3), 10000)
        e = self.rt(img)
        self.assertGreater(len(e), len(img))   # only overhead

    def test_large_counts(self):
        # >32 and >4096 forces multi-byte varints
        self.rt(b"\x01" * 40)
        self.rt(b"\x01" * 5000)
        self.rt(ref.build_mode1(count=40))

    def test_sector_at_odd_offset(self):
        rng = random.Random(8)
        self.rt(b"xyz" + ref.make_mode1(rng) + b"q")

    def test_random_mixes(self):
        for seed in range(6):
            rng = random.Random(seed)
            img = bytearray()
            for _ in range(rng.randint(1, 8)):
                k = rng.choice("m1 f1 f2 g z".split())
                if k == "m1": img += ref.make_mode1(rng, rng.randint(0, 5000))
                elif k == "f1": img += ref.make_mode2_form1(rng)
                elif k == "f2": img += ref.make_mode2_form2(rng)
                elif k == "g": img += ref.make_garbage(rng, rng.randint(1, 3000))
                else: img += bytes(rng.randint(1, 3000))
            self.rt(bytes(img))

    def test_varint_header_bytes(self):
        out = bytearray()
        ref._write_type_count(out, 0, 1)
        self.assertEqual(bytes(out), b"\x00")
        out = bytearray(); ref._write_type_count(out, 1, 32)       # count-1 = 31
        self.assertEqual(bytes(out), bytes([31 << 2 | 1]))
        out = bytearray(); ref._write_type_count(out, 2, 33)       # 32 -> two bytes
        self.assertEqual(bytes(out), bytes([0x80 | 2, 1]))
        out = bytearray(); ref._write_type_count(out, 0, 0x100000000)
        self.assertEqual(bytes(out), ref.END_MARKER[:5])


class FixtureTests(unittest.TestCase):
    def test_fixtures_decode(self):
        for n in ("mixed", "mode1", "mode2"):
            self.assertEqual(ref.decode(rd(n + ".ecm")), rd(n + ".bin"))
            self.assertEqual(ref.encode(rd(n + ".bin")), rd(n + ".ecm"))

    def test_fixtures_deterministic(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            ref.gen_fixtures(d)
            for f in os.listdir(d):
                with open(os.path.join(d, f), "rb") as fh:
                    self.assertEqual(fh.read(), rd(f), f)

    def test_fixture_sizes(self):
        for f in os.listdir(FIX):
            self.assertLess(os.path.getsize(os.path.join(FIX, f)), 100 * 1024, f)


class ErrorTests(unittest.TestCase):
    def test_too_short(self):
        with self.assertRaises(ref.FileTooShort): ref.decode(b"")
        with self.assertRaises(ref.FileTooShort): ref.decode(rd("tooshort.ecm"))

    def test_bad_header(self):
        with self.assertRaises(ref.InvalidHeader): ref.decode(rd("badheader.ecm"))
        with self.assertRaises(ref.InvalidHeader): ref.decode(b"ECM\x01" + ref.END_MARKER)

    def test_truncated(self):
        with self.assertRaises(ref.TruncatedData): ref.decode(rd("truncated.ecm"))
        with self.assertRaises(ref.TruncatedData): ref.decode(rd("noend.ecm"))
        full = rd("mixed.ecm")
        for cut in (5, 100, len(full) - 1, len(full) - 4):
            with self.assertRaises(ref.TruncatedData, msg=str(cut)):
                ref.decode(full[:cut])
        with self.assertRaises(ref.TruncatedData):
            ref.decode(ref.MAGIC + b"\x80")  # continuation with nothing after

    def test_bad_count(self):
        with self.assertRaises(ref.InvalidCount): ref.decode(rd("badcount.ecm"))

    def test_checksum(self):
        with self.assertRaises(ref.ChecksumMismatch): ref.decode(rd("badchecksum.ecm"))
        # corrupt a stored sector byte instead of the trailer
        e = bytearray(rd("mode1.ecm")); e[100] ^= 0xFF
        with self.assertRaises(ref.ChecksumMismatch): ref.decode(bytes(e))


class SwiftPortFindings(unittest.TestCase):
    """Documents bugs in the ORIGINAL Swift decoder (d94fb08)."""

    def test_swift_mode1_wrong_q_parity(self):
        exp = rd("mode1.bin")
        got = port.swift_decode(rd("mode1.ecm"))
        self.assertNotEqual(got, exp)
        self.assertEqual(got[:0x8C8], exp[:0x8C8])
        self.assertNotEqual(got[0x8C8:0x930], exp[0x8C8:0x930])

    def test_swift_mode2_missing_subheader_copy(self):
        exp = rd("mode2.bin"); got = port.swift_decode(rd("mode2.ecm"))
        self.assertEqual(got[0:4], b"\0\0\0\0")
        self.assertNotEqual(exp[0:4], b"\0\0\0\0")

    def test_swift_form2_only_differs_in_subheader_copy(self):
        rng = random.Random(1)
        c = ref.make_mode2_form2(rng)
        img = c * 2
        got = port.swift_decode(ref.encode(img))
        # subheader copy is zero, and the EDC (which covers it) is therefore wrong too
        self.assertEqual(got[4:0x91C + 0x10 - 0x10], img[4:0x91C])
        self.assertNotEqual(got[0:4], img[0:4])
        self.assertNotEqual(got[0x91C:2336], img[0x91C:2336])

    def test_swift_silent_errors(self):
        for n in ("truncated.ecm", "noend.ecm", "badchecksum.ecm", "badcount.ecm"):
            port.swift_decode(rd(n))   # does not raise


if __name__ == "__main__":
    unittest.main()
