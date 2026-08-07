"""Shared Gemini error helpers used by the API and all pollers."""


class GeminiQuotaError(Exception):
    """Raised when Gemini returns a 429 / quota / spending cap error."""


def is_quota_error(e: Exception) -> bool:
    """True when the exception looks like a rate-limit / quota / billing-cap error."""
    s = str(e).lower()
    return "429" in str(e) or "spending cap" in s or "quota" in s or "resource_exhausted" in s
