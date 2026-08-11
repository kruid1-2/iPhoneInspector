from __future__ import annotations

import unittest

from performance_helper import sanitizers
from performance_helper.sanitizers import sanitize_note, sanitize_text, to_safe_json


class SanitizerTests(unittest.TestCase):
    def test_sensitive_identifiers_are_redacted(self) -> None:
        text = "udid 00008101-1234567890ABCDEF email person@example.com imei 123456789012345"
        result = sanitize_text(text)
        self.assertNotIn("00008101-1234567890ABCDEF", result)
        self.assertNotIn("person@example.com", result)
        self.assertNotIn("123456789012345", result)

    def test_network_data_is_redacted_when_requested(self) -> None:
        text = "peers 192.168.1.10 fd00::1234 2001:db8:85a3::8a2e:370:7334 ::ffff:192.0.2.128"
        result = sanitize_text(text, redact_network=True)
        self.assertNotIn("192.168.1.10", result)
        self.assertNotIn("fd00::1234", result)
        self.assertNotIn("2001:db8:85a3::8a2e:370:7334", result)
        self.assertNotIn("::ffff:192.0.2.128", result)

    def test_network_redaction_handles_attached_colon_delimiters(self) -> None:
        cases = {
            "peer:fd00::1": "peer:<redacted-address>",
            "peer fd00::1:": "peer <redacted-address>:",
            "id:fd00::1": "id:<redacted-address>",
            "log:fd00::1": "log:<redacted-address>",
        }
        for text, expected in cases.items():
            with self.subTest(text=text):
                self.assertEqual(sanitize_text(text, redact_network=True), expected)

    def test_network_redaction_preserves_non_address_colon_data(self) -> None:
        text = (
            "zone fe80::1%en0 cidr 2001:db8::1/64 mapped ::ffff:192.0.2.128 "
            "time 16:25:23.810 mac aa:bb:cc:dd:ee:ff "
            "punctuation .fd00::1 -fd00::2"
        )
        result = sanitize_text(text, redact_network=True)
        self.assertIn("zone <redacted-address>", result)
        self.assertIn("cidr <redacted-address>/64", result)
        self.assertIn("mapped <redacted-address>", result)
        self.assertIn("time 16:25:23.810", result)
        self.assertIn("mac <redacted-mac>", result)
        self.assertIn("punctuation .<redacted-address> -<redacted-address>", result)

    def test_ipv6_candidate_search_is_linearly_bounded(self) -> None:
        candidate = ":" * 1_200
        ranges = list(sanitizers._ipv6_candidate_ranges(candidate))
        self.assertLessEqual(len(ranges), 9 * (candidate.count(":") + 1))
        self.assertEqual(sanitize_text(candidate, redact_network=True), "<redacted-address>")

    def test_sensitive_dictionary_keys_are_redacted(self) -> None:
        safe = to_safe_json({"SerialNumber": "secret", "raw_field": "SerialNumber"})
        self.assertEqual(safe["SerialNumber"], "<redacted>")
        self.assertEqual(safe["raw_field"], "SerialNumber")

    def test_note_is_single_line_and_bounded(self) -> None:
        note = sanitize_note("卡顿\n" + "x" * 400)
        self.assertNotIn("\n", note)
        self.assertLessEqual(len(note), 256)
