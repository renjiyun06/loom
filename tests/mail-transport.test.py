import importlib.util
from email.message import EmailMessage
from pathlib import Path
import smtplib
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

    def queue_reply(self):
        inbox = self.inbox({b"1": message(SENDER, "<original@example.org>")})
        transport.scan(inbox, self.db, SENDER, self.directory)
        transport.save_reply(self.db, "7:1", "收到。")

    def test_reply_stays_in_thread_and_goes_only_to_owner(self):
        self.queue_reply()
        with patch.object(transport, "connect_smtp") as connect:
            transport.deliver(self.db, ACCOUNT, SENDER, "fake")
            transport.deliver(self.db, ACCOUNT, SENDER, "fake")
        send = connect.return_value.send_message
        send.assert_called_once()
        self.assertEqual(send.call_args.kwargs, {"from_addr": ACCOUNT, "to_addrs": [SENDER]})
        reply = send.call_args.args[0]
        self.assertEqual(str(reply["To"]), SENDER)
        self.assertEqual(str(reply["In-Reply-To"]), "<original@example.org>")
        self.assertEqual(str(reply["References"]), "<original@example.org>")

    def test_disconnect_keeps_uncertain_delivery_from_replaying(self):
        self.queue_reply()
        with patch.object(transport, "connect_smtp") as connect:
            connect.return_value.send_message.side_effect = smtplib.SMTPServerDisconnected()
            with self.assertRaises(smtplib.SMTPServerDisconnected):
                transport.deliver(self.db, ACCOUNT, SENDER, "fake")
            transport.deliver(self.db, ACCOUNT, SENDER, "fake")
        self.assertEqual(self.db.execute("SELECT phase FROM mail").fetchone()[0], "sending")
        connect.return_value.send_message.assert_called_once()


if __name__ == "__main__":
    unittest.main()
