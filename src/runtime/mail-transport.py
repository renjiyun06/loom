"""One-shot IMAP/SMTP operations for the GT mail worker."""

import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
from email.utils import format_datetime
from hashlib import sha256
from html.parser import HTMLParser
import imaplib
import json
from pathlib import Path
import re
import smtplib
import sqlite3
import ssl
import sys


class Credential(ctypes.Structure):
    _fields_ = [
        ("flags", wintypes.DWORD), ("type", wintypes.DWORD),
        ("target", wintypes.LPWSTR), ("comment", wintypes.LPWSTR),
        ("written", wintypes.FILETIME), ("size", wintypes.DWORD),
        ("blob", ctypes.c_void_p), ("persist", wintypes.DWORD),
        ("attribute_count", wintypes.DWORD), ("attributes", ctypes.c_void_p),
        ("alias", wintypes.LPWSTR), ("username", wintypes.LPWSTR),
    ]


def read_credential(account):
    api = ctypes.WinDLL("Advapi32.dll", use_last_error=True)
    api.CredReadW.argtypes = [
        wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
        ctypes.POINTER(ctypes.POINTER(Credential)),
    ]
    api.CredReadW.restype = wintypes.BOOL
    api.CredFree.argtypes = [ctypes.c_void_p]
    api.CredFree.restype = None
    record = ctypes.POINTER(Credential)()
    if not api.CredReadW("Loom/Mail/IMAP/" + account, 1, 0, ctypes.byref(record)):
        raise RuntimeError("Windows Credential Manager has no mail authorization code")
    try:
        return ctypes.string_at(record.contents.blob, record.contents.size).decode("utf-16-le")
    finally:
        api.CredFree(record)


def connect_inbox(account, code):
    inbox = imaplib.IMAP4_SSL(
        "imap.163.com", 993, ssl_context=ssl.create_default_context(), timeout=15
    )
    try:
        inbox.login(account, code)
        if "ID" in inbox.capabilities:
            imap_result(inbox.xatom("ID", '("name" "Loom" "version" "1.0")'), "ID")
        imap_result(inbox.select("INBOX", readonly=True), "EXAMINE")
        return inbox
    except BaseException:
        inbox.shutdown()
        raise


def connect_smtp(account, code):
    smtp = smtplib.SMTP_SSL(
        "smtp.163.com", 465, context=ssl.create_default_context(), timeout=15
    )
    try:
        smtp.login(account, code)
        return smtp
    except BaseException:
        smtp.close()
        raise


def imap_result(response, operation):
    status, items = response
    if status != "OK":
        raise RuntimeError(f"IMAP {operation} failed")
    return items


def fetch(inbox, uid, fields):
    items = imap_result(inbox.uid("FETCH", uid, fields), "FETCH")
    return next((item[1] for item in items if isinstance(item, tuple)), None)


class PlainHTML(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []
        self.hidden = 0

    def handle_starttag(self, tag, attrs):
        if tag in {"script", "style", "head"}:
            self.hidden += 1
        elif not self.hidden and tag in {"br", "div", "li", "p", "tr"}:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if self.hidden and tag in {"script", "style", "head"}:
            self.hidden -= 1

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)


def addresses(header):
    return tuple(address.addr_spec.casefold() for address in header.addresses)


def is_allowed(message, sender):
    headers = message.get_all("From", [])
    auto_submitted = str(message.get("Auto-Submitted", "no")).split(";", 1)[0]
    return (
        len(headers) == 1 and not headers[0].defects
        and addresses(headers[0]) == (sender,)
        and auto_submitted.strip().casefold() == "no"
    )


def message_ids(text):
    return re.findall(r"<[^<>\s@]+@[^<>\s@]+>", str(text))


def mail_task(raw, key, sender, directory):
    message = BytesParser(policy=policy.default).parsebytes(raw)
    if not is_allowed(message, sender):
        return None
    part = message.get_body(preferencelist=("plain", "html"))
    text = "" if part is None else part.get_content(errors="replace")
    if part is not None and part.get_content_subtype() == "html":
        parser = PlainHTML()
        parser.feed(text)
        text = "".join(parser.parts)
    attachments = []
    for index, attachment in enumerate(message.iter_attachments(), 1):
        content = attachment.get_payload(decode=True)
        if content is None:
            continue
        name = attachment.get_filename() or f"attachment-{index}"
        extension = re.search(r"\.[A-Za-z0-9]{1,12}$", name)
        path = directory / "attachments" / key.replace(":", "-") / (
            str(index) + (extension[0] if extension else "")
        )
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        attachments.append({"name": name, "path": str(path)})
    identifiers = message_ids(message.get("Message-ID", ""))
    return {
        "id": key,
        "sender": sender,
        "subject": str(message.get("Subject", "")),
        "text": text.strip(),
        "messageId": identifiers[0] if identifiers else "",
        "references": message_ids(message.get("References", "")),
        "attachments": attachments,
    }


def open_database(directory):
    directory.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(directory / "mail.sqlite", timeout=5)
    connection.row_factory = sqlite3.Row
    with connection:
        connection.execute("BEGIN IMMEDIATE")
        connection.execute("""
            CREATE TABLE IF NOT EXISTS mail (
                id TEXT PRIMARY KEY,
                message_id TEXT UNIQUE,
                phase TEXT NOT NULL,
                task TEXT,
                reply TEXT,
                reply_subject TEXT
            )
        """)
        columns = {column["name"] for column in connection.execute("PRAGMA table_info(mail)")}
        if "reply_subject" not in columns:
            connection.execute("ALTER TABLE mail ADD COLUMN reply_subject TEXT")
    return connection


def scan(inbox, db, sender, directory):
    validity = inbox.response("UIDVALIDITY")[1][0]
    if not validity or not validity.isdigit():
        raise RuntimeError("IMAP UIDVALIDITY is unavailable")
    matches = imap_result(inbox.uid("SEARCH", None, "UNSEEN"), "SEARCH")[0].split()
    for uid in matches:
        if not uid.isdigit():
            raise RuntimeError("IMAP returned an invalid UID")
        key = validity.decode("ascii") + ":" + uid.decode("ascii")
        if db.execute("SELECT 1 FROM mail WHERE id = ?", (key,)).fetchone():
            continue
        header = fetch(inbox, uid, "(BODY.PEEK[HEADER.FIELDS (FROM AUTO-SUBMITTED MESSAGE-ID)])")
        if header is None:
            continue
        candidate = BytesParser(policy=policy.default).parsebytes(header)
        task = None
        if is_allowed(candidate, sender):
            identifiers = message_ids(candidate.get("Message-ID", ""))
            duplicate = identifiers and db.execute(
                "SELECT 1 FROM mail WHERE message_id = ?", (identifiers[0],)
            ).fetchone()
            if not duplicate:
                raw = fetch(inbox, uid, "(BODY.PEEK[])")
                if raw is None:
                    continue
                task = mail_task(raw, key, sender, directory)
        with db:
            db.execute(
                "INSERT OR IGNORE INTO mail (id, message_id, phase, task) VALUES (?, ?, ?, ?)",
                (key, (task["messageId"] or None) if task else None,
                 "pending" if task else "ignored", json.dumps(task) if task else None),
            )


def save_reply(db, key, subject, text):
    if not isinstance(subject, str) or not subject.strip():
        raise ValueError("The reply must contain a subject")
    if not isinstance(text, str) or not text.strip():
        raise ValueError("The reply must contain text")
    subject = " ".join(subject.splitlines()).strip()
    with db:
        result = db.execute(
            """UPDATE mail SET reply_subject = ?, reply = ?, phase = 'ready'
            WHERE id = ? AND phase = 'pending'""",
            (subject, text.strip(), key),
        )
        if result.rowcount != 1:
            raise RuntimeError("The mail task is no longer pending")


def reply_message(task, text, account, sender, subject=None):
    if task["sender"] != sender:
        raise ValueError("The saved sender differs from the configured address")
    reply = EmailMessage()
    reply["From"] = account
    reply["To"] = sender
    if subject is None:
        original = " ".join(task["subject"].splitlines()).strip()
        subject = original if original.lower().startswith("re:") else "Re: " + original
    reply["Subject"] = subject
    reply["Date"] = format_datetime(datetime.now(timezone.utc))
    key = sha256(f'{account}:{task["id"]}'.encode()).hexdigest()[:32]
    reply["Message-ID"] = f"<loom.{key}@{account.split('@')[1]}>"
    if task["messageId"]:
        reply["In-Reply-To"] = task["messageId"]
        refs = dict.fromkeys([*task["references"], task["messageId"]])
        reply["References"] = " ".join(refs)
    reply["Auto-Submitted"] = "auto-replied"
    reply.set_content(text)
    return reply


def delivery_phase(db, key, previous, new):
    with db:
        return db.execute(
            "UPDATE mail SET phase = ? WHERE id = ? AND phase = ?",
            (new, key, previous),
        ).rowcount == 1


def deliver(db, account, sender, code):
    row = db.execute("SELECT * FROM mail WHERE phase = 'ready' ORDER BY rowid LIMIT 1").fetchone()
    if row is None:
        return
    reply = reply_message(
        json.loads(row["task"]), row["reply"], account, sender, subject=row["reply_subject"]
    )
    smtp = connect_smtp(account, code)
    try:
        if not delivery_phase(db, row["id"], "ready", "sending"):
            return
        # A disconnect after DATA leaves the outcome uncertain. Never replay it automatically.
        try:
            smtp.send_message(reply, from_addr=account, to_addrs=[sender])
        except (smtplib.SMTPSenderRefused, smtplib.SMTPRecipientsRefused, smtplib.SMTPDataError) as failure:
            response = (
                next(iter(failure.recipients.values()))[0]
                if isinstance(failure, smtplib.SMTPRecipientsRefused) else failure.smtp_code
            )
            delivery_phase(db, row["id"], "sending", "ready" if 400 <= response < 500 else "failed")
            raise RuntimeError(f"SMTP rejected the reply ({response})") from None
        delivery_phase(db, row["id"], "sending", "sent")
    finally:
        smtp.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    parser.add_argument("operation", choices=("check", "poll", "reply", "status"))
    parser.add_argument("reply_file", type=Path, nargs="?")
    args = parser.parse_args()
    config = json.loads(args.config.read_text(encoding="utf-8-sig"))
    account = config["account"].strip().casefold()
    sender = config["sender"].strip().casefold()
    directory = args.config.resolve().parent.parent / "state" / "mail"
    if args.operation == "check":
        code = read_credential(account)
        with connect_inbox(account, code), connect_smtp(account, code):
            return {"imap": True, "smtp": True}
    with open_database(directory) as db:
        if args.operation == "status":
            rows = db.execute("SELECT phase, count(*) FROM mail GROUP BY phase")
            return {"messages": dict(rows)}
        code = read_credential(account)
        if args.operation == "reply":
            response = json.loads(args.reply_file.read_text(encoding="utf-8-sig"))
            save_reply(db, response["id"], response["subject"], response["text"])
        else:
            with connect_inbox(account, code) as inbox:
                scan(inbox, db, sender, directory)
        deliver(db, account, sender, code)
        row = db.execute("SELECT task FROM mail WHERE phase = 'pending' ORDER BY rowid LIMIT 1").fetchone()
        return {"task": json.loads(row["task"]) if row else None}


if __name__ == "__main__":
    try:
        print(json.dumps(main(), ensure_ascii=True))
    except (imaplib.IMAP4.error, smtplib.SMTPException, OSError) as error:
        print(f"Mail transport failed: {type(error).__name__}", file=sys.stderr)
        sys.exit(1)
