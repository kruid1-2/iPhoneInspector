from __future__ import annotations

import dataclasses
import ipaddress
import math
import re
from datetime import date, datetime
from pathlib import Path
from typing import Any


_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
_EMAIL_RE = re.compile(r"(?<![\w.+-])[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}(?![\w.-])")
_URL_SECRET_RE = re.compile(r"(?i)([?&](?:token|key|secret|password|auth)=)[^&#\s]+")
_BEARER_RE = re.compile(r"(?i)\b(bearer|token|password|cookie)\s*[:=]\s*\S+")
_UDID_DASHED_RE = re.compile(r"(?i)\b[0-9a-f]{8}-[0-9a-f]{16}\b")
_LONG_HEX_RE = re.compile(r"(?i)\b[0-9a-f]{24,64}\b")
_IMEI_RE = re.compile(r"(?<!\d)\d{15}(?!\d)")
_PHONE_RE = re.compile(r"(?<!\d)(?:\+?86[- ]?)?1[3-9]\d{9}(?!\d)")
_IPV4_RE = re.compile(r"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)")
_IPV6_CANDIDATE_RE = re.compile(
    r"(?<![0-9A-Za-z_%.-])[0-9A-Za-z_%.-]*:[0-9A-Za-z_%:.-]*(?![0-9A-Za-z_%.-])"
)
_MAC_RE = re.compile(r"(?i)\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b")
_USER_PATH_RE = re.compile(r"/Users/[^/\s]+")
_MAX_SANITIZE_SCAN = 16_384
_MAX_IPV6_COLONS_PER_TOKEN = 32

_SENSITIVE_KEYS = {
    "udid",
    "serial",
    "serialnumber",
    "serial_number",
    "imei",
    "meid",
    "ecid",
    "phonenumber",
    "phone_number",
    "email",
    "account",
    "appleid",
    "cookie",
    "token",
    "password",
}
_NORMALIZED_SENSITIVE_KEYS = {item.replace("_", "").casefold() for item in _SENSITIVE_KEYS}


def _ipv6_candidate_ranges(candidate: str):
    colon_positions = [index for index, character in enumerate(candidate) if character == ":"]
    starts = [(0, 0)] + [
        (position + 1, rank + 1)
        for rank, position in enumerate(colon_positions)
    ]
    for start, first_colon_rank in starts:
        for colon_count in range(2, 10):
            end_rank = first_colon_rank + colon_count
            if end_rank > len(colon_positions):
                break
            end = len(candidate) if end_rank == len(colon_positions) else colon_positions[end_rank]
            trimmed_start = start
            trimmed_end = end
            while trimmed_start < trimmed_end and candidate[trimmed_start] in ".-":
                trimmed_start += 1
            while trimmed_end > trimmed_start and candidate[trimmed_end - 1] in ".-":
                trimmed_end -= 1
            if 0 < trimmed_end - trimmed_start <= 128:
                yield trimmed_start, trimmed_end


def _find_ipv6_span(candidate: str) -> tuple[int, int] | None:
    best: tuple[int, int] | None = None
    for start, end in _ipv6_candidate_ranges(candidate):
        try:
            ipaddress.IPv6Address(candidate[start:end])
        except ValueError:
            continue
        if best is None or start < best[0] or (start == best[0] and end > best[1]):
            best = (start, end)
    return best


def _redact_ipv6_addresses(value: str) -> str:
    def replace(match: re.Match[str]) -> str:
        candidate = match.group(0)
        if candidate.count(":") > _MAX_IPV6_COLONS_PER_TOKEN:
            return "<redacted-address>"
        pieces: list[str] = []
        while candidate:
            span = _find_ipv6_span(candidate)
            if span is None:
                pieces.append(candidate)
                break
            start, end = span
            pieces.append(candidate[:start])
            pieces.append("<redacted-address>")
            candidate = candidate[end:]
        return "".join(pieces)

    return _IPV6_CANDIDATE_RE.sub(replace, value)


def sanitize_text(value: str, *, limit: int = 512, redact_network: bool = False) -> str:
    scan_limit = min(_MAX_SANITIZE_SCAN, max(limit * 4, limit + 256))
    source_was_truncated = len(value) > scan_limit
    source = value[:scan_limit]
    if source_was_truncated:
        whitespace_boundary = max(source.rfind(character) for character in (" ", "\t", "\r", "\n"))
        source = source[: whitespace_boundary + 1] if whitespace_boundary >= 0 else ""

    text = _CONTROL_RE.sub(" ", source).replace("\r", " ").replace("\n", " ")
    text = _EMAIL_RE.sub("<redacted-email>", text)
    text = _URL_SECRET_RE.sub(r"\1<redacted>", text)
    text = _BEARER_RE.sub(lambda match: f"{match.group(1)}=<redacted>", text)
    text = _UDID_DASHED_RE.sub("<redacted-udid>", text)
    text = _LONG_HEX_RE.sub("<redacted-identifier>", text)
    text = _IMEI_RE.sub("<redacted-imei>", text)
    text = _PHONE_RE.sub("<redacted-phone>", text)
    if redact_network:
        text = _redact_ipv6_addresses(text)
    text = _MAC_RE.sub("<redacted-mac>", text)
    text = _USER_PATH_RE.sub("/Users/<redacted>", text)
    if redact_network:
        text = _IPV4_RE.sub("<redacted-address>", text)
    if len(text) > limit or source_was_truncated:
        text = text[: max(0, limit - 1)] + "…"
    return text


def sanitize_note(value: Any) -> str:
    if not isinstance(value, str):
        raise ValueError("note must be a string")
    return sanitize_text(value.strip(), limit=256, redact_network=True)


def _is_sensitive_key(key: Any) -> bool:
    return isinstance(key, str) and key.replace("-", "").replace("_", "").casefold() in _NORMALIZED_SENSITIVE_KEYS


def to_safe_json(value: Any, *, redact_network: bool = False) -> Any:
    if dataclasses.is_dataclass(value) and not isinstance(value, type):
        value = dataclasses.asdict(value)
    if value is None or isinstance(value, (bool, int)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if isinstance(value, str):
        return sanitize_text(value, redact_network=redact_network)
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, Path):
        return sanitize_text(str(value), redact_network=redact_network)
    if isinstance(value, bytes):
        return {"redacted_binary_bytes": len(value)}
    if isinstance(value, dict):
        result: dict[str, Any] = {}
        for key, item in value.items():
            safe_key = sanitize_text(str(key), limit=128)
            result[safe_key] = "<redacted>" if _is_sensitive_key(key) else to_safe_json(
                item, redact_network=redact_network
            )
        return result
    if isinstance(value, (list, tuple, set)):
        return [to_safe_json(item, redact_network=redact_network) for item in value]
    return sanitize_text(str(value), redact_network=redact_network)
