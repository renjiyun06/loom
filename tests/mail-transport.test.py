import importlib.util
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
import json
from pathlib import Path
import smtplib
import sqlite3
import tempfile
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location(
    "transport", Path(__file__).resolve().parents[1] / "src/runtime/mail-transport.py"
)
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)
ACCOUNT = "loom@example.net"
SENDER = "owner@example.org"


def message(sender, message_id):
    mail = EmailMessage()
    mail["From"] = sender
    mail["Reply-To"] = "other@example.org"
    mail["Message-ID"] = message_id
    mail["Subject"] = "测试"
    mail.set_content("这是一封测试邮件。")
    return mail


class TestMailTransport(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.directory = Path(scratch.name)
        self.db = transport.open_database(self.directory)
        self.addCleanup(self.db.close)

    def inbox(self, messages):
        inbox = Mock()
        inbox.response.return_value = ("UIDVALIDITY", [b"7"])

        def uid(command, target, fields):
            if command == "SEARCH":
                self.assertEqual(fields, "UNSEEN")
                return "OK", [b" ".join(messages)]
            self.assertTrue(fields.startswith("(BODY.PEEK["))
            mail = messages[target]
            if fields == "(BODY.PEEK[])":
                raw = mail.as_bytes()
            else:
                raw = (f'From: {mail["From"]}\r\nMessage-ID: {mail["Message-ID"]}\r\n\r\n').encode()
            return "OK", [(b"FETCH", raw)]

        inbox.uid.side_effect = uid
        return inbox

    def test_poll_filters_and_deduplicates(self):
        allowed = message(SENDER, "<allowed@example.org>")
        allowed.add_attachment(b"reference", maintype="application", subtype="octet-stream", filename="../reference.txt")
        inbox = self.inbox({
            b"1": allowed,
            b"2": message("other@example.org", "<filtered@example.org>"),
            b"3": allowed,
        })
        for _ in range(2):
            transport.scan(inbox, self.db, SENDER, self.directory)
        phases = self.db.execute("SELECT phase FROM mail ORDER BY rowid").fetchall()
        self.assertEqual([row[0] for row in phases], ["pending", "ignored", "ignored"])
        only_full_fetch = [call.args[1] for call in inbox.uid.call_args_list
                           if call.args[2] == "(BODY.PEEK[])"]
        self.assertEqual(only_full_fetch, [b"1"])
        self.assertEqual((self.directory / "attachments" / "7-1" / "1.txt").read_bytes(), b"reference")

    def test_qq_quoted_encoded_display_name_keeps_exact_sender_check(self):
        raw = (
            b'From: "=?utf-8?B?cmVu?=" <owner@example.org>\r\n'
            b'Subject: Test\r\n\r\nHello.\r\n'
        )
        parser = BytesParser(policy=policy.default)
        parsed = parser.parsebytes(raw)
        self.assertTrue(transport.is_allowed(parsed, SENDER))
        self.assertIsNotNone(transport.mail_task(raw, "7:1", SENDER, self.directory))
        wrong = raw.replace(b"<owner@example.org>", b"<other@example.org>")
        self.assertFalse(transport.is_allowed(parser.parsebytes(wrong), SENDER))
        ambiguous = raw.replace(b"<owner@example.org>", b"<owner@example.org>, <other@example.org>")
        self.assertFalse(transport.is_allowed(parser.parsebytes(ambiguous), SENDER))
        broken = raw.replace(b"<owner@example.org>", b"<owner@example.org")
        self.assertFalse(transport.is_allowed(parser.parsebytes(broken), SENDER))

    def queue_task(self):
        inbox = self.inbox({b"1": message(SENDER, "<original@example.org>")})
        transport.scan(inbox, self.db, SENDER, self.directory)

    def queue_reply(self):
        self.queue_task()
        transport.save_reply(self.db, "7:1", "邮件入口已就绪", "收到。")

    def test_reply_stays_in_thread_and_goes_only_to_owner(self):
        self.queue_reply()
        with patch.object(transport, "connect_smtp") as connect:
            transport.deliver(self.db, ACCOUNT, SENDER, "fake", self.directory)
            transport.deliver(self.db, ACCOUNT, SENDER, "fake", self.directory)
        send = connect.return_value.send_message
        send.assert_called_once()
        self.assertEqual(send.call_args.kwargs, {"from_addr": ACCOUNT, "to_addrs": [SENDER]})
        reply = send.call_args.args[0]
        self.assertEqual(str(reply["To"]), SENDER)
        self.assertEqual(str(reply["Subject"]), "邮件入口已就绪")
        self.assertEqual(reply.get_content().strip(), "收到。")
        self.assertEqual(str(reply["In-Reply-To"]), "<original@example.org>")
        self.assertEqual(str(reply["References"]), "<original@example.org>")

    def test_saved_body_from_older_database_can_still_be_sent(self):
        legacy_dir = self.directory / "legacy"
        legacy_dir.mkdir()
        task = transport.mail_task(
            message(SENDER, "<original@example.org>").as_bytes(), "7:1", SENDER, legacy_dir
        )
        legacy_db = sqlite3.connect(legacy_dir / "mail.sqlite")
        try:
            with legacy_db:
                legacy_db.execute("""
                    CREATE TABLE mail (
                        id TEXT PRIMARY KEY, message_id TEXT UNIQUE,
                        phase TEXT NOT NULL, task TEXT, reply TEXT
                    )
                """)
                legacy_db.execute(
                    "INSERT INTO mail VALUES (?, ?, 'ready', ?, ?)",
                    (task["id"], task["messageId"], json.dumps(task), "旧版回信。"),
                )
        finally:
            legacy_db.close()

        db = transport.open_database(legacy_dir)
        self.addCleanup(db.close)
        with patch.object(transport, "connect_smtp") as connect:
            transport.deliver(db, ACCOUNT, SENDER, "fake", legacy_dir)
        reply = connect.return_value.send_message.call_args.args[0]
        self.assertEqual(str(reply["Subject"]), "Re: 测试")
        self.assertEqual(reply.get_content().strip(), "旧版回信。")
        self.assertEqual(db.execute("SELECT phase FROM mail").fetchone()[0], "sent")

    def test_disconnect_keeps_uncertain_delivery_from_replaying(self):
        self.queue_reply()
        with patch.object(transport, "connect_smtp") as connect:
            connect.return_value.send_message.side_effect = smtplib.SMTPServerDisconnected()
            with self.assertRaises(smtplib.SMTPServerDisconnected):
                transport.deliver(self.db, ACCOUNT, SENDER, "fake", self.directory)
            transport.deliver(self.db, ACCOUNT, SENDER, "fake", self.directory)
        self.assertEqual(self.db.execute("SELECT phase FROM mail").fetchone()[0], "sending")
        connect.return_value.send_message.assert_called_once()

    def test_corrected_attachment_is_saved_and_sent_from_its_snapshot(self):
        self.queue_task()
        task = transport.next_task(self.db, self.directory)
        workspace = Path(task["attachmentDirectory"])
        outside = workspace.parent / "outside.txt"
        outside.write_bytes(b"outside")
        response = {
            "id": task["id"], "subject": "文件", "text": "见附件。",
            "attachments": [
                {"path": "report.pdf"},
                {"path": str(workspace / ".." / outside.name)},
                {"path": str(workspace / "missing.pdf")},
            ],
        }
        outcome = transport.submit_reply(self.db, self.directory, response)
        self.assertEqual(outcome["phase"], "correcting")
        self.assertEqual(len(outcome["draft"]["errors"]), 3)
        self.assertIn("绝对路径", outcome["draft"]["errors"][0])
        self.assertIn("目录之外", outcome["draft"]["errors"][1])
        self.assertIn("不存在", outcome["draft"]["errors"][2])
        with patch.object(transport, "connect_smtp") as connect:
            transport.deliver(self.db, ACCOUNT, SENDER, "fake", self.directory)
        connect.assert_not_called()

        reopened = transport.open_database(self.directory)
        self.addCleanup(reopened.close)
        self.assertEqual(transport.next_task(reopened, self.directory)["replyDraft"], outcome["draft"])
        path = workspace / "report.pdf"
        path.write_bytes(b"original result")
        response["attachments"] = [{"path": str(path), "name": "整理结果.pdf"}]
        self.assertEqual(transport.submit_reply(reopened, self.directory, response), {"phase": "ready"})
        path.write_bytes(b"later edit")
        with patch.object(transport, "connect_smtp") as connect:
            transport.deliver(reopened, ACCOUNT, SENDER, "fake", self.directory)
        reply = connect.return_value.send_message.call_args.args[0]
        attachment, = reply.iter_attachments()
        self.assertEqual(attachment.get_filename(), "整理结果.pdf")
        self.assertEqual(attachment.get_content_type(), "application/pdf")
        self.assertEqual(attachment.get_payload(decode=True), b"original result")

    def test_invalid_correction_keeps_draft_and_releases_the_queue(self):
        self.queue_task()
        response = {
            "id": "7:1", "subject": "文件", "text": "见附件。",
            "attachments": [{"path": "still-relative.pdf"}],
        }
        transport.submit_reply(self.db, self.directory, response)
        outcome = transport.submit_reply(self.db, self.directory, response)
        self.assertEqual(outcome["phase"], "validation_failed")
        row = self.db.execute("SELECT reply_draft FROM mail WHERE id = '7:1'").fetchone()
        self.assertEqual(json.loads(row["reply_draft"]), outcome["draft"])
        self.assertIsNone(transport.next_task(self.db, self.directory))


if __name__ == "__main__":
    unittest.main()
