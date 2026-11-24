"""One-shot IMAP/SMTP operations for the GT mail worker."""

import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
from email import policy
from email.errors import InvalidHeaderDefect
from email.message import EmailMessage
from email.parser import BytesParser
from email.utils import format_datetime
from hashlib import sha256
from html.parser import HTMLParser
import imaplib
import json
import mimetypes
import os
from pathlib import Path
import re
import shutil
import smtplib
import sqlite3
import ssl
import sys
import tempfile


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


def allowed_from_defects(defects):
    if not defects:
        return True
    # QQ Mail can place an encoded display name inside quotes around an otherwise valid address.
    quoted_name = "encoded word inside quoted string"
    display_name_defects = {quoted_name, "missing trailing whitespace after encoded-word"}
    return any(str(defect) == quoted_name for defect in defects) and all(
        isinstance(defect, InvalidHeaderDefect) and str(defect) in display_name_defects
        for defect in defects
    )


def is_allowed(message, sender):
    headers = message.get_all("From", [])
    auto_submitted = str(message.get("Auto-Submitted", "no")).split(";", 1)[0]
    return (
        len(headers) == 1 and allowed_from_defects(headers[0].defects)
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
                reply_subject TEXT,
                reply_attachments TEXT,
                reply_draft TEXT
            )
        """)
        columns = {column["name"] for column in connection.execute("PRAGMA table_info(mail)")}
        for column in ("reply_subject", "reply_attachments", "reply_draft"):
            if column not in columns:
                connection.execute(f"ALTER TABLE mail ADD COLUMN {column} TEXT")
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


def attachment_directory(directory, key):
    if not re.fullmatch(r"[0-9]+:[0-9]+", key):
        raise ValueError("Invalid mail task ID")
    workspace = directory.resolve() / "outgoing" / key.replace(":", "-")
    if workspace.resolve() != workspace:
        raise ValueError("The attachment directory must stay under the mail state directory")
    workspace.mkdir(parents=True, exist_ok=True)
    return workspace


def attachment_source(workspace, entry):
    if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
        raise ValueError("path 必须是字符串")
    source = Path(entry["path"])
    if not source.is_absolute():
        raise ValueError("path 必须是绝对路径")
    if not source.is_relative_to(workspace):
        raise ValueError("文件位于这封回信的附件目录之外")
    source = source.resolve(strict=True)
    if not source.is_relative_to(workspace):
        raise ValueError("文件实际位于这封回信的附件目录之外")
    if not source.is_file():
        raise ValueError("路径必须指向普通文件")
    name = entry.get("name", source.name)
    if (not isinstance(name, str) or not name.strip() or name.strip() in {".", ".."}
            or re.search(r"[\x00-\x1f\x7f/\\]", name)):
        raise ValueError("name 必须是有效的文件名")
    return source, name.strip()


def remove_staged_attachments(stage):
    if stage is not None:
        for part in stage.iterdir():
            part.unlink()
        stage.rmdir()


def stage_attachments(directory, key, entries):
    if not isinstance(entries, list):
        return None, [], ["attachments 必须是附件列表"]
    if not entries:
        return None, [], []
    workspace = attachment_directory(directory, key)
    outbox = directory.resolve() / "outbox"
    if outbox.resolve() != outbox:
        raise ValueError("The outbox must stay under the mail state directory")
    outbox.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=workspace.name + "-", dir=outbox))
    manifest, errors = [], []
    try:
        for index, entry in enumerate(entries, 1):
            try:
                source, name = attachment_source(workspace, entry)
                snapshot = stage / str(index)
                with source.open("rb") as input_file, snapshot.open("xb") as output_file:
                    shutil.copyfileobj(input_file, output_file)
                    output_file.flush()
                    os.fsync(output_file.fileno())
                manifest.append({"path": snapshot.relative_to(outbox.parent).as_posix(), "name": name})
            except (ValueError, RuntimeError) as error:
                errors.append(f"第 {index} 个附件：{error}")
            except OSError as error:
                reason = "文件不存在" if isinstance(error, FileNotFoundError) else "文件无法读取或保存"
                errors.append(f"第 {index} 个附件：{reason}")
    except BaseException:
        remove_staged_attachments(stage)
        raise
    if errors:
        remove_staged_attachments(stage)
        return None, [], errors
    return stage, manifest, []


def save_reply(db, key, subject, text, attachments=None):
    if not isinstance(subject, str) or not subject.strip():
        raise ValueError("The reply must contain a subject")
    if not isinstance(text, str) or not text.strip():
        raise ValueError("The reply must contain text")
    subject = " ".join(subject.splitlines()).strip()
    with db:
        result = db.execute(
            """UPDATE mail
            SET reply_subject = ?, reply = ?, reply_attachments = ?, reply_draft = NULL, phase = 'ready'
            WHERE id = ? AND phase IN ('pending', 'correcting')""",
            (subject, text.strip(), json.dumps(attachments or []), key),
        )
        if result.rowcount != 1:
            raise RuntimeError("The mail task is no longer pending")


def submit_reply(db, directory, response):
    key = response["id"]
    row = db.execute("SELECT phase FROM mail WHERE id = ?", (key,)).fetchone()
    if row is None or row["phase"] not in ("pending", "correcting"):
        raise RuntimeError("The mail task is no longer pending")
    stage, manifest, errors = stage_attachments(directory, key, response.get("attachments", []))
    if errors:
        draft = {"reply": response, "errors": errors}
        phase = "correcting" if row["phase"] == "pending" else "validation_failed"
        with db:
            result = db.execute(
                "UPDATE mail SET phase = ?, reply_draft = ? WHERE id = ? AND phase = ?",
                (phase, json.dumps(draft), key, row["phase"]),
            )
            if result.rowcount != 1:
                raise RuntimeError("The mail task changed during attachment validation")
        return {"phase": phase, "draft": draft}
    try:
        save_reply(db, key, response["subject"], response["text"], manifest)
    except Exception:
        remove_staged_attachments(stage)
        raise
    return {"phase": "ready"}


def next_task(db, directory):
    row = db.execute("""
        SELECT task, reply_draft FROM mail
        WHERE phase IN ('pending', 'correcting') ORDER BY rowid LIMIT 1
    """).fetchone()
    if row is None:
        return None
    task = json.loads(row["task"])
    task["attachmentDirectory"] = str(attachment_directory(directory, task["id"]))
    if row["reply_draft"] is not None:
        task["replyDraft"] = json.loads(row["reply_draft"])
    return task


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


def deliver(db, account, sender, code, directory):
    row = db.execute("SELECT * FROM mail WHERE phase = 'ready' ORDER BY rowid LIMIT 1").fetchone()
    if row is None:
        return
    reply = reply_message(
        json.loads(row["task"]), row["reply"], account, sender, subject=row["reply_subject"]
    )
    for attachment in json.loads(row["reply_attachments"] or "[]"):
        content = (directory / attachment["path"]).read_bytes()
        mime = mimetypes.guess_type(attachment["name"])[0] or "application/octet-stream"
        main_type, sub_type = mime.split("/", 1)
        reply.add_attachment(content, maintype=main_type, subtype=sub_type, filename=attachment["name"])
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
        if args.operation == "reply":
            response = json.loads(args.reply_file.read_text(encoding="utf-8-sig"))
            outcome = submit_reply(db, directory, response)
            if outcome["phase"] == "ready":
                deliver(db, account, sender, read_credential(account), directory)
            return outcome
        code = read_credential(account)
        with connect_inbox(account, code) as inbox:
            scan(inbox, db, sender, directory)
        deliver(db, account, sender, code, directory)
        return {"task": next_task(db, directory)}


if __name__ == "__main__":
    try:
        print(json.dumps(main(), ensure_ascii=True))
    except (imaplib.IMAP4.error, smtplib.SMTPException, OSError) as error:
        print(f"Mail transport failed: {type(error).__name__}", file=sys.stderr)
        sys.exit(1)
