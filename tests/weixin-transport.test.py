import sys
from contextlib import closing
import base64
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

SOURCE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOURCE_ROOT / "src" / "runtime"))
import weixin_transport as transport


class WeixinQueueTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(TemporaryDirectory())).resolve()
        self.db = self.enterContext(closing(transport.open_database(self.root)))
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
        messages = transport.history(self.db, self.root)
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
        transport.stage_reply(self.db, task["id"], body, self.root)
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
            self.assertEqual(transport.post_part(self.db, self.account, client, item, self.root)["phase"], phase)
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
            self.assertEqual(transport.poll(self.db, self.account["generation"], self.root)["phase"], "awaiting_binding")
        self.assertEqual(transport.report_status(self.db), {"phase": "awaiting_binding", "counts": {"reply_ready": 1}})

    def test_image_only_message_and_attachment_only_reply(self):
        content = b"\x89PNG\r\n\x1a\nimage payload"
        key = bytes(range(16))
        real_aes = transport.media.aes
        ciphertext = real_aes(SOURCE_ROOT, "encrypt", key, content)
        self.enterContext(patch.object(transport.media, "aes", side_effect=lambda root, *args: real_aes(SOURCE_ROOT, *args)))
        cdn = self.enterContext(patch.object(transport.media, "cdn_request", side_effect=[ciphertext, "download-token"]))
        incoming = dict(self.text(), item_list=[{"type": 2, "image_item": {"media": {
            "encrypt_query_param": "inbound-token", "aes_key": base64.b64encode(key.hex().encode()).decode(),
        }}}])
        transport.save_updates(self.db, self.account, {"msgs": [incoming]})
        transport.save_updates(self.db, self.account, {"msgs": [incoming]})
        self.assertEqual(transport.receive(self.db, self.root, self.account, None)["phase"], "receiving_attachment")
        message = transport.receive(self.db, self.root, self.account, None)["message"]
        self.assertEqual(message["text"], "")
        [received] = message["attachments"]
        self.assertEqual(received["phase"], "saved")
        self.assertEqual(Path(received["path"]).read_bytes(), content)
        workspace = Path(message["attachmentDirectory"])
        workspace.mkdir(parents=True)
        source = workspace / "回复.png"
        source.write_bytes(content)
        transport.stage_reply(self.db, message["id"], "", self.root, [{"path": str(source)}])
        source.unlink()
        calls = []

        def client(operation, payload):
            calls.append((operation, payload))
            if operation == "getuploadurl":
                return {"upload_param": "upload-token"}
            return {"message_id": "delivery-id"}

        task = transport.take(self.db, self.account, "reply_ready", "preparing_reply")
        self.assertEqual(transport.post_part(self.db, self.account, client, task, self.root)["phase"], "reply_ready")
        transport.take(self.db, self.account, "reply_ready", "preparing_reply")
        transport.recover(self.db)
        task = transport.take(self.db, self.account, "reply_ready", "preparing_reply")
        self.assertEqual(transport.post_part(self.db, self.account, client, task, self.root)["phase"], "accepted")
        self.assertEqual([name for name, _ in calls], ["getuploadurl", "sendmessage"])
        self.assertEqual(calls[0][1]["rawsize"], len(content))
        ciphertext_sent = cdn.call_args.args[1]
        self.assertEqual(real_aes(SOURCE_ROOT, "decrypt", bytes.fromhex(calls[0][1]["aeskey"]), ciphertext_sent), content)
        item = calls[1][1]["msg"]["item_list"][0]
        self.assertEqual(item["image_item"]["media"]["encrypt_query_param"], "download-token")
        [record] = transport.history(self.db, self.root)
        [reply] = record["replyAttachments"]
        self.assertEqual(reply["phase"], "accepted")
        self.assertEqual(Path(reply["path"]).read_bytes(), content)

    def test_file_and_voice_are_stored_in_order_and_failed_media_remains_visible(self):
        body = b"text file data"
        incoming = dict(self.text(), item_list=[
            {"type": 1, "text_item": {"text": "另外输入的文字"}},
            {"type": 4, "file_item": {"file_name": "../报告.txt", "media": {}, "len": str(len(body))}},
            {"type": 3, "voice_item": {"encode_type": 6, "text": "语音转写"}},
        ])
        transport.save_updates(self.db, self.account, {"msgs": [incoming]})
        failure = transport.media.MediaError("不可下载")
        with patch.object(transport.media, "download", side_effect=[body, failure, failure, failure]):
            for attempt in range(4):
                self.assertEqual(transport.receive(self.db, self.root, self.account, None)["phase"], "receiving_attachment")
        task = transport.receive(self.db, self.root, self.account, None)["message"]
        self.assertEqual(task["text"], "另外输入的文字\n语音转写")
        received, missing = task["attachments"]
        self.assertEqual(received["name"], "_报告.txt")
        self.assertEqual(Path(received["path"]).read_bytes(), body)
        self.assertNotIn("transcript", received)
        self.assertEqual(missing["transcript"], "语音转写")
        self.assertEqual((missing["name"], missing["phase"], missing["path"]), ("语音.silk", "download_failed", None))

    def test_migrates_old_voice_records_and_distinguishes_new_clips_without_a_transcript(self):
        incoming = dict(self.text(), item_list=[{"type": 3, "voice_item": {"text": "已有转写"}}])
        transport.save_updates(self.db, self.account, {"msgs": [incoming]})
        self.db.execute("ALTER TABLE attachments DROP COLUMN transcript")
        with closing(transport.open_database(self.root)) as reopened:
            [legacy] = transport.history(reopened, self.root)
            self.assertEqual(legacy["text"], "已有转写")
            self.assertNotIn("transcript", legacy["attachments"][0])
            clip = dict(incoming, message_id=incoming["message_id"] + 1,
                        item_list=[{"type": 3, "voice_item": {}}])
            transport.save_updates(reopened, self.account, {"msgs": [clip]})
            [_, latest] = transport.history(reopened, self.root)
            self.assertEqual(latest["text"], "")
            self.assertEqual(latest["attachments"][0]["transcript"], "")

    def test_rejects_outgoing_paths_outside_the_reply_directory(self):
        transport.save_updates(self.db, self.account, {"msgs": [self.text()]})
        task = transport.take(self.db, self.account, "pending", "answering")
        source = self.root / "outside.txt"
        source.touch()
        with self.assertRaises(transport.TransportError):
            transport.stage_reply(self.db, task["id"], "", self.root, [{"path": str(source)}])
        self.assertEqual(transport.report_status(self.db)["counts"], {"answering": 1})
        self.assertEqual(transport.attachment_view(self.db, self.root, task["id"], "outbound"), [])

    def test_video_and_generic_file_use_distinct_upload_and_message_types(self):
        path = self.root / "payload"
        path.write_bytes(b"payload")
        calls = []

        def client(operation, data):
            self.assertEqual(operation, "getuploadurl")
            calls.append(data["media_type"])
            return {"upload_full_url": "https://novac2c.cdn.weixin.qq.com/upload"}

        with patch.object(transport.media, "aes", return_value=b"ciphertext"), patch.object(
                transport.media, "cdn_request", return_value="download-token"):
            video = transport.media.upload(self.root, client, "owner", path, "video", "视频.mp4")
            file = transport.media.upload(self.root, client, "owner", path, "file", "报告.txt")
        self.assertEqual(calls, [2, 3])
        self.assertEqual((video["type"], video["video_item"]["video_size"]), (5, len(b"ciphertext")))
        self.assertEqual((file["type"], file["file_item"]["file_name"], file["file_item"]["len"]), (4, "报告.txt", "7"))

    @staticmethod
    def stale_client(operation, payload):
        raise transport.Rejected(operation, -14)


if __name__ == "__main__":
    unittest.main()
