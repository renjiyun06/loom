import sys
from contextlib import closing
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src" / "runtime"))
import weixin_transport as transport


class WeixinQueueTest(unittest.TestCase):
    def setUp(self):
        self.directory = self.enterContext(TemporaryDirectory())
        self.db = self.enterContext(closing(transport.open_database(Path(self.directory))))
        self.enterContext(patch.object(transport, "dpapi", side_effect=lambda value, protect: value))
        transport.store_binding(self.db, {"ilink_bot_id": "bot", "ilink_user_id": "owner", "bot_token": "test"})
        self.account = transport.account_at(self.db)

    def text(self, sender="owner", group=None):
        return {"message_id": 2**63 + 5, "from_user_id": sender, "message_type": 1,
                "group_id": group, "context_token": "fixture-context",
                "item_list": [{"type": 1, "text_item": {"text": "你好"}}]}

    def test_receives_owner_only_and_deduplicates_atomically_with_cursor(self):
        updates = {"get_updates_buf": "cursor", "msgs": [self.text("other"), self.text(group="group"), self.text()]}
        self.assertEqual(transport.save_updates(self.db, self.account, updates), {"received": 3, "recorded": 1})
        self.assertEqual(transport.save_updates(self.db, self.account, updates), {"received": 3, "recorded": 0})
        messages = transport.history(self.db)
        self.assertEqual([item["text"] for item in messages], ["你好"])
        self.assertEqual(transport.account_at(self.db)["cursor"], "cursor")
        self.assertEqual(self.db.execute("SELECT remote_id FROM messages").fetchone()[0], str(2**63 + 5))

    def test_preserves_messages_missing_the_reply_context_without_dispatching(self):
        transport.save_updates(self.db, self.account, {"msgs": [dict(self.text(), context_token="")]})
        self.assertEqual(transport.report_status(self.db)["counts"], {"missing_context": 1})
        self.assertIsNone(transport.take(self.db, self.account, "pending", "answering"))

    def pending_reply(self, body):
        transport.save_updates(self.db, self.account, {"msgs": [self.text()]})
        task = transport.take(self.db, self.account, "pending", "answering")
        transport.stage_reply(self.db, task["id"], body)
        return task

    def test_sends_each_part_once_with_matching_reply_context(self):
        task = self.pending_reply("回" * 1901)
        sent = []

        def client(operation, payload):
            self.assertEqual(operation, "sendmessage")
            sent.append(payload["msg"])
            return {"message_id": len(sent)}

        for phase in ("reply_ready", "accepted"):
            item = transport.take(self.db, self.account, "reply_ready", "sending")
            self.assertEqual(transport.post_part(self.db, self.account, client, item)["phase"], phase)
        self.assertEqual([msg["client_id"] for msg in sent], [f"loom-{task['id']}-{part}" for part in range(2)])
        self.assertTrue(all(msg["to_user_id"] == "owner" and msg["context_token"] == "fixture-context" for msg in sent))
        self.assertEqual("".join(msg["item_list"][0]["text_item"]["text"] for msg in sent), "回" * 1901)
        self.assertIsNone(transport.take(self.db, self.account, "reply_ready", "sending"))

    def test_restart_does_not_replay_an_uncertain_send(self):
        self.pending_reply("答复")
        transport.take(self.db, self.account, "reply_ready", "sending")
        transport.recover(self.db)
        self.assertEqual(transport.report_status(self.db)["counts"], {"delivery_unknown": 1})
        self.assertIsNone(transport.take(self.db, self.account, "reply_ready", "sending"))

    def test_stale_binding_pauses_without_losing_ready_reply(self):
        self.pending_reply("答复")
        with patch.object(transport, "account_client", return_value=self.stale_client):
            self.assertEqual(transport.poll(self.db, self.account["generation"])["phase"], "awaiting_binding")
        self.assertEqual(transport.report_status(self.db), {"phase": "awaiting_binding", "counts": {"reply_ready": 1}})

    @staticmethod
    def stale_client(operation, payload):
        raise transport.Rejected(operation, -14)


if __name__ == "__main__":
    unittest.main()
