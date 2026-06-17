#!/usr/bin/env python3
# Unit tests for the pure logic in olcrtc-bot.py (#424). Run with:
#     python3 scripts/test_olcrtc_bot.py
# Not part of the Xcode test target (that's Swift only) — a standalone python3
# check over the command-decision and update-parsing helpers, which need no
# network or podman.

import importlib.util
import pathlib
import unittest

_PATH = pathlib.Path(__file__).resolve().parent / "olcrtc-bot.py"
_spec = importlib.util.spec_from_file_location("olcrtc_bot", _PATH)
bot = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bot)

CFG = {
    "start_cmd": "go", "stop_cmd": "halt",
    "start_reply": "up", "stop_reply": "down", "unknown_reply": "?",
}


class DecideTests(unittest.TestCase):
    def test_start(self):
        self.assertEqual(bot.decide(CFG, "go"), ("start", "up"))

    def test_stop(self):
        self.assertEqual(bot.decide(CFG, "halt"), ("stop", "down"))

    def test_trims_whitespace(self):
        self.assertEqual(bot.decide(CFG, "  go\n"), ("start", "up"))

    def test_exact_match_only(self):
        # near-misses are "unknown", never a partial command match
        self.assertEqual(bot.decide(CFG, "go now"), (None, "?"))
        self.assertEqual(bot.decide(CFG, "GO"), (None, "?"))

    def test_unknown_gets_unknown_reply(self):
        self.assertEqual(bot.decide(CFG, "hello"), (None, "?"))

    def test_empty_is_silent(self):
        self.assertEqual(bot.decide(CFG, ""), (None, None))
        self.assertEqual(bot.decide(CFG, "   "), (None, None))

    def test_blank_unknown_reply_is_silent(self):
        cfg = dict(CFG, unknown_reply="")
        self.assertEqual(bot.decide(cfg, "hello"), (None, None))

    def test_blank_command_reply_falls_back(self):
        cfg = dict(CFG, start_reply="")
        self.assertEqual(bot.decide(cfg, "go"), ("start", "OK"))


class ExtractTests(unittest.TestCase):
    def test_telegram_message(self):
        upd = {"update_id": 5, "message": {"text": " go ", "chat": {"id": 42}}}
        self.assertEqual(bot.tg_extract(upd), ("go", 42))

    def test_telegram_no_message(self):
        self.assertEqual(bot.tg_extract({"update_id": 5}), ("", None))

    def test_max_message_created(self):
        upd = {"update_type": "message_created",
               "message": {"body": {"text": " halt "}, "recipient": {"chat_id": 7}}}
        self.assertEqual(bot.max_extract(upd), ("halt", 7))

    def test_max_other_update_ignored(self):
        self.assertEqual(bot.max_extract({"update_type": "bot_started"}), (None, None))

    def test_max_missing_fields(self):
        self.assertEqual(bot.max_extract({"update_type": "message_created"}), ("", None))


if __name__ == "__main__":
    unittest.main()
