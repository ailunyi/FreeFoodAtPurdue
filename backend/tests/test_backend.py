"""Tests for backend.py: Gemini response parsing and message handling."""

import pytest


@pytest.fixture(scope="module")
def backend_module(scratch_dbs):
    import backend
    return backend


class FakeResponse:
    def __init__(self, text):
        self.text = text


class FakeModel:
    def __init__(self, reply):
        self.reply = reply
        self.calls = []

    def generate_content(self, contents):
        self.calls.append(contents)
        return FakeResponse(self.reply)


class QuotaModel:
    def generate_content(self, contents):
        raise RuntimeError("429 Resource has been exhausted (check quota)")


def test_parse_gemini_response_plain_json(backend_module):
    parsed = backend_module._parse_gemini_response('{"name": "Pizza", "confidence": 0.8}')
    assert parsed["name"] == "Pizza"


def test_parse_gemini_response_strips_markdown_fences(backend_module):
    raw = '```json\n{"name": "Pizza", "confidence": 0.8}\n```'
    parsed = backend_module._parse_gemini_response(raw)
    assert parsed["name"] == "Pizza"


def test_parse_gemini_response_rejects_low_confidence(backend_module):
    assert backend_module._parse_gemini_response('{"name": "Pizza", "confidence": 0.3}') is None


def test_parse_gemini_response_rejects_invalid_json(backend_module):
    assert backend_module._parse_gemini_response("not json at all") is None


def test_parse_message_keeps_history_slim(backend_module):
    model = FakeModel('{"name": "Pizza", "building": "WALC", "confidence": 0.9}')
    history = []
    message = {"text": "free pizza in WALC", "name": "Alan", "attachments": []}

    raw, event = backend_module.parse_message(model, message, history)

    assert event and event["name"] == "Pizza"
    # The live call included the extraction prompt...
    live_parts = model.calls[0][-1]["parts"]
    assert any("food event extractor" in str(p) for p in live_parts)
    # ...but the stored history contains only the plain message text.
    assert history[0]["parts"] == ["[From: Alan]\nfree pizza in WALC"]
    assert "food event extractor" not in str(history)


def test_parse_message_history_window_capped_at_ten(backend_module):
    model = FakeModel('{"name": "Pizza", "confidence": 0.9}')
    history = []
    for i in range(8):
        message = {"text": f"message {i}", "name": "Alan", "attachments": []}
        backend_module.parse_message(model, message, history)
    assert len(history) == 10


def test_parse_message_raises_on_quota_error(backend_module):
    from gemini_utils import GeminiQuotaError

    message = {"text": "free pizza", "name": "Alan", "attachments": []}
    with pytest.raises(GeminiQuotaError):
        backend_module.parse_message(QuotaModel(), message, [])


def test_parse_message_skips_empty_messages(backend_module):
    model = FakeModel("null")
    raw, event = backend_module.parse_message(model, {"text": "", "attachments": []}, [])
    assert raw is None and event is None
    assert model.calls == []


def test_is_quota_error_detection():
    from gemini_utils import is_quota_error

    assert is_quota_error(RuntimeError("429 too many requests"))
    assert is_quota_error(RuntimeError("You exceeded your current quota"))
    assert is_quota_error(RuntimeError("Spending cap reached"))
    assert not is_quota_error(RuntimeError("connection reset by peer"))
