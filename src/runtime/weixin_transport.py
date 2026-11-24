"""Weixin iLink transport and durable queue for the GT message worker."""

import argparse
import base64
from contextlib import closing, contextmanager
import ctypes
from ctypes import wintypes
import json
from pathlib import Path
import secrets
import shutil
import sqlite3
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from uuid import uuid4

import weixin_media as media


BASE = "https://ilinkai.weixin.qq.com"
# iLink compatibility version, with Loom identified as the implementation.
VERSION = (2, 4, 10)
BASE_INFO = {"channel_version": "2.4.10/loom-1.0.0", "bot_agent": "Loom/1.0.0"}


class TransportError(Exception):
    pass


class Rejected(TransportError):
    def __init__(self, operation, code):
        super().__init__(f"iLink {operation} rejected the request ({code})")
        self.code = code


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def weixin_origin(value):
    url = urlsplit(value)
    if (url.scheme != "https" or not url.hostname or not url.hostname.endswith(".weixin.qq.com")
            or url.netloc != url.hostname or url.path not in ("", "/") or url.query or url.fragment):
        raise TransportError("iLink returned an unexpected API origin")
    return "https://" + url.hostname


def request(operation, *, origin=BASE, params=None, data=None, token=None, timeout=15):
    major, minor, patch = VERSION
    headers = {"Accept": "application/json", "iLink-App-Id": "bot",
               "iLink-App-ClientVersion": str(major << 16 | minor << 8 | patch)}
    body = None
    if data is not None:
        headers.update({"Content-Type": "application/json", "AuthorizationType": "ilink_bot_token",
                        "X-WECHAT-UIN": base64.b64encode(str(secrets.randbits(32)).encode()).decode()})
        if token:
            headers["Authorization"] = "Bearer " + token
            data = {**data, "base_info": BASE_INFO}
        body = json.dumps(data, ensure_ascii=False).encode()
    url = weixin_origin(origin) + "/ilink/bot/" + operation
    if params:
        url += "?" + urlencode(params)
    try:
        with build_opener(NoRedirect).open(Request(url, data=body, headers=headers), timeout=timeout) as response:
            result = json.loads(response.read(8_000_000))
    except HTTPError as error:
        raise TransportError(f"iLink {operation} returned HTTP {error.code}") from None
    except URLError as error:
        if isinstance(error.reason, TimeoutError):
            raise TimeoutError from None
        raise TransportError(f"Could not connect to iLink {operation}") from None
    except (ValueError, OSError) as error:
        if isinstance(error, TimeoutError):
            raise TimeoutError from None
        raise TransportError(f"Could not read the iLink {operation} response") from None
    if not isinstance(result, dict):
        raise TransportError(f"iLink {operation} returned an unexpected response")
    for field in ("errcode", "ret"):
        try:
            code = int(result.get(field) or 0)
        except (ValueError, TypeError):
            raise TransportError(f"iLink {operation} returned an invalid error code") from None
        if code:
            raise Rejected(operation, code)
    return result


class DataBlob(ctypes.Structure):
    _fields_ = [("size", wintypes.DWORD), ("data", ctypes.c_void_p)]


def dpapi(value, protect):
    """Encrypt credentials for the Windows account running Loom."""
    crypt = ctypes.WinDLL("crypt32", use_last_error=True)
    free = ctypes.WinDLL("kernel32").LocalFree
    free.argtypes = [ctypes.c_void_p]
    free.restype = ctypes.c_void_p
    buffer = ctypes.create_string_buffer(value)
    source = DataBlob(len(value), ctypes.addressof(buffer))
    output = DataBlob()
    transform = crypt.CryptProtectData if protect else crypt.CryptUnprotectData
    transform.argtypes = [ctypes.POINTER(DataBlob), ctypes.c_void_p, ctypes.c_void_p,
                          ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(DataBlob)]
    transform.restype = wintypes.BOOL
    if not transform(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(output)):
        raise TransportError("Windows could not access the Weixin binding credential")
    try:
        return ctypes.string_at(output.data, output.size)
    finally:
        free(output.data)


def open_database(root):
    directory = root / "state" / "weixin"
    directory.mkdir(parents=True, exist_ok=True)
    database = sqlite3.connect(directory / "weixin.sqlite", isolation_level=None)
    database.row_factory = sqlite3.Row
    database.executescript("""
        CREATE TABLE IF NOT EXISTS account (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            generation TEXT NOT NULL, bot TEXT NOT NULL, owner TEXT NOT NULL,
            origin TEXT NOT NULL, credential BLOB NOT NULL, bound_ms INTEGER NOT NULL,
            cursor TEXT NOT NULL DEFAULT '', needs_binding INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS messages (
            sequence INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE,
            bot TEXT NOT NULL, owner TEXT NOT NULL, remote_id TEXT NOT NULL,
            text TEXT NOT NULL, context TEXT NOT NULL,
            created_ms INTEGER, phase TEXT NOT NULL DEFAULT 'pending',
            reply TEXT, parts TEXT, next_part INTEGER NOT NULL DEFAULT 0,
            server_reply_id TEXT, error TEXT,
            UNIQUE (bot, owner, remote_id)
        );
        CREATE INDEX IF NOT EXISTS message_queue ON messages (bot, owner, phase, sequence);
        CREATE TABLE IF NOT EXISTS attachments (
            id TEXT PRIMARY KEY, message_id TEXT NOT NULL, direction TEXT NOT NULL,
            position INTEGER NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL,
            relative_path TEXT, size INTEGER, phase TEXT NOT NULL, reference TEXT,
            attempts INTEGER NOT NULL DEFAULT 0, error TEXT, server_reply_id TEXT,
            UNIQUE (message_id, direction, position)
        );
        CREATE INDEX IF NOT EXISTS attachment_queue ON attachments (phase, message_id);
        """)
    return database


@contextmanager
def transaction(db):
    db.execute("BEGIN IMMEDIATE")
    try:
        yield
        db.commit()
    except BaseException:
        db.rollback()
        raise


def account_at(db):
    return db.execute("SELECT * FROM account WHERE singleton = 1").fetchone()


def store_binding(db, confirmed):
    token = confirmed.get("bot_token")
    bot = confirmed.get("ilink_bot_id")
    owner = confirmed.get("ilink_user_id")
    if not all(isinstance(value, str) and value for value in (token, bot, owner)):
        raise TransportError("iLink did not return a complete binding")
    origin = weixin_origin(confirmed.get("baseurl") or BASE)
    credential = dpapi(token.encode(), protect=True)
    with transaction(db):
        previous = account_at(db)
        if previous and previous["owner"] != owner:
            raise TransportError("This Loom installation is already bound to a different Weixin account")
        same_bot = previous and previous["bot"] == bot
        cursor = previous["cursor"] if same_bot else ""
        bound_ms = previous["bound_ms"] if same_bot else int(time.time() * 1000)
        db.execute("INSERT OR REPLACE INTO account VALUES (1, ?, ?, ?, ?, ?, ?, ?, 0)",
                   (uuid4().hex, bot, owner, origin, credential, bound_ms, cursor))


def account_client(account):
    token = dpapi(account["credential"], protect=False).decode()

    def call(operation, data, timeout=15):
        return request(operation, origin=account["origin"], data=data, token=token, timeout=timeout)

    return call


def inbound_message(message, owner, bound_ms):
    if (not isinstance(message, dict) or message.get("from_user_id") != owner
            or message.get("message_type") in (2, "2")
            or message.get("group_id") not in (None, "", 0, "0")
            or message.get("delete_time_ms")):
        return None
    remote = message.get("message_id") or message.get("client_id") or message.get("seq")
    if remote is None:
        return None
    context = message.get("context_token")
    if not isinstance(context, str):
        context = ""
    items = message.get("item_list")
    if not isinstance(items, list):
        return None
    texts, attachments = [], []
    for position, item in enumerate(items):
        if not isinstance(item, dict):
            continue
        item_type = str(item.get("type"))
        if item_type == "1":
            text_item = item.get("text_item")
            if isinstance(text_item, dict) and isinstance(text_item.get("text"), str):
                texts.append(text_item["text"])
        elif item_type in ("2", "3", "4", "5"):
            kind = media.ITEM_TYPES[int(item_type)]
            reference = item.get(kind + "_item")
            reference = reference if isinstance(reference, dict) else {}
            if kind == "voice" and isinstance(reference.get("text"), str) and reference["text"].strip():
                texts.append(reference["text"])
            default_name = {"image": "图片.bin", "video": "视频.mp4", "file": "文件.bin", "voice": "语音.bin"}[kind]
            if kind == "voice":
                extension = {"1": "pcm", "4": "speex", "5": "amr", "6": "silk", "7": "mp3", "8": "ogg"}
                default_name = "语音." + extension.get(str(reference.get("encode_type")), "bin")
            name = media.name_for(reference.get("file_name"), default_name)
            attachments.append((position, kind, name, json.dumps(reference)))
    body = "\n".join(texts).strip()
    if not body and not attachments:
        return None
    try:
        created = int(message.get("create_time_ms") or 0)
    except (TypeError, ValueError):
        created = 0
    if created and created < bound_ms - 5_000:
        return None
    return (str(remote), body, context, created or None), attachments


def save_updates(db, account, updates):
    messages = updates.get("msgs") or []
    if not isinstance(messages, list):
        raise TransportError("iLink returned an invalid message list")
    added = 0
    with transaction(db):
        if account_at(db)["generation"] != account["generation"]:
            return {}
        for message in messages:
            inbound = inbound_message(message, account["owner"], account["bound_ms"])
            if inbound is not None:
                data, attachments = inbound
                message_id = uuid4().hex
                phase = "pending" if data[2] else "missing_context"
                row = db.execute("""INSERT INTO messages (id, bot, owner, remote_id, text, context, created_ms, phase)
                                    VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (bot, owner, remote_id) DO NOTHING""",
                                 (message_id, account["bot"], account["owner"], *data, phase))
                if row.rowcount:
                    db.executemany("""INSERT INTO attachments
                        (id, message_id, direction, position, kind, name, reference, phase)
                        VALUES (?, ?, 'inbound', ?, ?, ?, ?, 'download_pending')""",
                                   [(uuid4().hex, message_id, *attachment) for attachment in attachments])
                added += row.rowcount
        cursor = updates.get("get_updates_buf")
        if isinstance(cursor, str) and cursor:
            db.execute("UPDATE account SET cursor = ? WHERE singleton = 1", (cursor,))
    return {"received": len(messages), "recorded": added}


def file_location(root, attachment, name):
    relative = Path("attachments", attachment["direction"], attachment["message_id"], attachment["id"], name)
    return relative, root / "state" / "weixin" / relative


def attachment_view(db, root, message_id, direction):
    rows = db.execute("SELECT * FROM attachments WHERE message_id = ? AND direction = ? ORDER BY position",
                      (message_id, direction))
    return [dict(id=row["id"], kind=row["kind"], name=row["name"], size=row["size"],
                 phase=row["phase"], error=row["error"],
                 path=str(root / "state" / "weixin" / row["relative_path"]) if row["relative_path"] else None)
            for row in rows]


def receive_attachment(db, root, account):
    attachment = db.execute("""SELECT a.* FROM attachments a JOIN messages m ON m.id = a.message_id
                                WHERE m.bot = ? AND m.owner = ? AND a.phase = 'download_pending'
                                ORDER BY m.sequence, a.position LIMIT 1""", (account["bot"], account["owner"])).fetchone()
    if not attachment:
        return False
    try:
        content = media.download(root, json.loads(attachment["reference"]), attachment["kind"])
        name = media.received_name(attachment["kind"], attachment["name"], content)
        relative, path = file_location(root, attachment, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(".download-" + uuid4().hex)
        try:
            temporary.write_bytes(content)
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    except (media.MediaError, OSError) as error:
        description = str(error) if isinstance(error, media.MediaError) else "无法保存收到的附件"
        attempts = attachment["attempts"] + 1
        failed = attempts >= 3
        db.execute("""UPDATE attachments SET attempts = ?, error = ?, phase = ?,
                      reference = CASE WHEN ? THEN NULL ELSE reference END WHERE id = ?""",
                   (attempts, description, "download_failed" if failed else "download_pending", failed, attachment["id"]))
    else:
        db.execute("""UPDATE attachments SET name = ?, relative_path = ?, size = ?, phase = 'saved',
                      reference = NULL, error = NULL WHERE id = ?""", (name, relative.as_posix(), len(content), attachment["id"]))
    return True


def take(db, account, from_phase, to_phase):
    with transaction(db):
        if account_at(db)["generation"] != account["generation"]:
            return None
        item = db.execute("SELECT * FROM messages WHERE bot = ? AND owner = ? AND phase = ? ORDER BY sequence LIMIT 1",
                          (account["bot"], account["owner"], from_phase)).fetchone()
        if item:
            db.execute("UPDATE messages SET phase = ? WHERE id = ?", (to_phase, item["id"]))
        return item


def advance_reply(db, item, parts, attachment, phase, response_id=None, error=None):
    with transaction(db):
        if attachment:
            db.execute("UPDATE attachments SET phase = ?, server_reply_id = ?, error = ?, reference = NULL WHERE id = ?",
                       (phase, response_id, error, attachment["id"]))
        next_part = item["next_part"] + 1
        if phase == "delivery_unconfirmed":
            result = phase
        elif next_part < len(parts):
            result = "reply_ready"
        else:
            failed = db.execute("SELECT 1 FROM attachments WHERE message_id = ? AND phase = 'send_failed' LIMIT 1",
                                (item["id"],)).fetchone()
            result = "partial" if failed else "accepted"
        db.execute("""UPDATE messages SET phase = ?, next_part = ?,
                      server_reply_id = COALESCE(?, server_reply_id), error = ? WHERE id = ?""",
                   (result, next_part, response_id, error, item["id"]))
    return {"phase": result}


def upload_part(db, root, account, client, item, parts, attachment):
    try:
        path = root / "state" / "weixin" / attachment["relative_path"]
        reference = media.upload(root, client, account["owner"], path, attachment["kind"], attachment["name"])
    except (media.MediaError, OSError, TransportError) as error:
        if isinstance(error, Rejected) and error.code == -14:
            db.execute("UPDATE messages SET phase = 'reply_ready' WHERE id = ?", (item["id"],))
            raise
        description = str(error) if isinstance(error, (media.MediaError, TransportError)) else "无法读取或上传回复附件"
        attempts = attachment["attempts"] + 1
        db.execute("UPDATE attachments SET attempts = ?, error = ? WHERE id = ?", (attempts, description, attachment["id"]))
        if attempts >= 3:
            return advance_reply(db, item, parts, attachment, "send_failed", error=description)
    else:
        db.execute("UPDATE attachments SET phase = 'uploaded', reference = ?, error = NULL WHERE id = ?",
                   (json.dumps(reference), attachment["id"]))
    db.execute("UPDATE messages SET phase = 'reply_ready' WHERE id = ?", (item["id"],))
    return {"phase": "reply_ready"}


def post_part(db, account, client, item, root):
    parts = json.loads(item["parts"])
    part = item["next_part"]
    content = parts[part]
    attachment = None
    if isinstance(content, dict):
        attachment = db.execute("SELECT * FROM attachments WHERE id = ? AND message_id = ? AND direction = 'outbound'",
                                (content["attachment"], item["id"])).fetchone()
        if not attachment:
            db.execute("UPDATE messages SET phase = 'send_failed', error = ? WHERE id = ?",
                       ("回复附件记录缺失", item["id"]))
            return {"phase": "send_failed"}
        if not attachment["reference"]:
            return upload_part(db, root, account, client, item, parts, attachment)
        outgoing = json.loads(attachment["reference"])
    else:
        outgoing = {"type": 1, "text_item": {"text": content}}
    with transaction(db):
        db.execute("UPDATE messages SET phase = 'sending' WHERE id = ?", (item["id"],))
        if attachment:
            db.execute("UPDATE attachments SET phase = 'sending' WHERE id = ?", (attachment["id"],))
    try:
        result = client("sendmessage", {"msg": {
            "from_user_id": "", "to_user_id": account["owner"], "context_token": item["context"],
            "client_id": f"loom-{item['id']}-{part}", "message_type": 2, "message_state": 2,
            "item_list": [outgoing],
        }})
    except Rejected as error:
        if attachment and error.code != -14:
            return advance_reply(db, item, parts, attachment, "send_failed", error=str(error))
        phase = "reply_ready" if error.code == -14 else "send_failed"
        with transaction(db):
            db.execute("UPDATE messages SET phase = ?, error = ? WHERE id = ?", (phase, str(error), item["id"]))
            if attachment:
                db.execute("UPDATE attachments SET phase = 'uploaded' WHERE id = ?", (attachment["id"],))
        raise
    except (TransportError, TimeoutError):
        with transaction(db):
            db.execute("UPDATE messages SET phase = 'delivery_unknown' WHERE id = ?", (item["id"],))
            if attachment:
                db.execute("UPDATE attachments SET phase = 'delivery_unknown', reference = NULL WHERE id = ?",
                           (attachment["id"],))
        raise
    response_id = result.get("message_id")
    phase = "accepted" if response_id else "delivery_unconfirmed"
    return advance_reply(db, item, parts, attachment, phase, str(response_id) if response_id else None)


def poll(db, online_generation, root):
    account = account_at(db)
    if not account or account["needs_binding"]:
        return {"phase": "awaiting_binding"}
    client = account_client(account)
    generation = account["generation"]
    try:
        if generation != online_generation:
            client("msg/notifystart", {}, timeout=10)
        item = take(db, account, "reply_ready", "preparing_reply")
        if item:
            result = post_part(db, account, client, item, root)
        else:
            result = receive(db, root, account, client)
    except Rejected as error:
        if error.code != -14:
            raise
        db.execute("UPDATE account SET needs_binding = 1 WHERE generation = ?", (generation,))
        return {"phase": "awaiting_binding"}
    return {**result, "onlineGeneration": generation}


def receive(db, root, account, client):
    if receive_attachment(db, root, account):
        return {"phase": "receiving_attachment"}
    item = take(db, account, "pending", "answering")
    if item:
        folder = root / "state" / "weixin" / "compose" / item["id"]
        return {"phase": "ready", "message": {
            "id": item["id"], "text": item["text"], "kind": "text",
            "attachments": attachment_view(db, root, item["id"], "inbound"),
            "attachmentDirectory": str(folder),
        }}
    try:
        updates = client("getupdates", {"get_updates_buf": account["cursor"]}, timeout=42)
    except TimeoutError:
        return {"phase": "ready", "pollTimedOut": True}
    return {"phase": "ready", **save_updates(db, account, updates)}


def stage_reply(db, message_id, text, root, attachments=()):
    body = text.strip()
    if not isinstance(attachments, (list, tuple)):
        raise TransportError("微信回复的附件必须是一个列表")
    if not body and not attachments:
        raise TransportError("The Weixin reply is empty")
    # Keep each part under the client limit, including surrogate pairs on UTF-16 clients.
    parts = [body[index:index + 1900] for index in range(0, len(body), 1900)]
    copies = []
    try:
        with transaction(db):
            if not db.execute("SELECT 1 FROM messages WHERE id = ? AND phase = 'answering'", (message_id,)).fetchone():
                raise TransportError("The Weixin message is not waiting for a reply")
            for position, entry in enumerate(attachments):
                attachment_id = stage_attachment(db, root, message_id, position, entry, copies)
                parts.append({"attachment": attachment_id})
            db.execute("UPDATE messages SET reply = ?, parts = ?, phase = 'reply_ready' WHERE id = ?",
                       (body, json.dumps(parts), message_id))
    except BaseException:
        for path in copies:
            path.unlink(missing_ok=True)
        raise


def stage_attachment(db, root, message_id, position, entry, copies):
    if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
        raise TransportError("微信回复附件缺少文件路径")
    workspace = root / "state" / "weixin" / "compose" / message_id
    original = Path(entry["path"])
    source = original.resolve()
    if not original.is_absolute() or not source.is_relative_to(workspace) or not source.is_file():
        raise TransportError("微信回复附件必须在本条回复的附件目录内")
    size = source.stat().st_size
    if size > media.MAX_SIZE:
        raise TransportError("微信附件超过 50 MiB")
    name = media.name_for(entry.get("name"), media.name_for(source.name, "附件.bin"))
    extension = source.suffix.lower()
    kind = "image" if extension in media.IMAGE_TYPES else "video" if extension in media.VIDEO_TYPES else "file"
    if entry.get("kind") == "file":
        kind = "file"
    attachment_id = uuid4().hex
    record = {"direction": "outbound", "message_id": message_id, "id": attachment_id}
    relative, destination = file_location(root, record, name)
    destination.parent.mkdir(parents=True, exist_ok=False)
    copies.append(destination)
    with source.open("rb") as read, destination.open("xb") as write:
        shutil.copyfileobj(read, write)
    if destination.stat().st_size != size:
        raise TransportError("微信回复附件在保存期间已变化")
    db.execute("""INSERT INTO attachments (id, message_id, direction, position, kind, name, relative_path, size, phase)
                  VALUES (?, ?, 'outbound', ?, ?, ?, ?, ?, 'staged')""",
               (attachment_id, message_id, position, kind, name, relative.as_posix(), size))
    return attachment_id


def recover(db):
    with transaction(db):
        db.execute("UPDATE messages SET phase = 'interrupted' WHERE phase = 'answering'")
        db.execute("UPDATE messages SET phase = 'delivery_unknown' WHERE phase = 'sending'")
        db.execute("UPDATE attachments SET phase = 'delivery_unknown', reference = NULL WHERE phase = 'sending'")
        db.execute("UPDATE messages SET phase = 'reply_ready' WHERE phase = 'preparing_reply'")


def report_status(db):
    account = account_at(db)
    state = "bound" if account and not account["needs_binding"] else "awaiting_binding"
    if not account:
        return {"phase": state, "counts": {}}
    scope = (account["bot"], account["owner"])
    counts = dict(db.execute("SELECT phase, COUNT(*) FROM messages WHERE bot = ? AND owner = ? GROUP BY phase", scope))
    return {"phase": state, "counts": counts}


def history(db, root):
    account = account_at(db)
    if not account:
        return []
    rows = db.execute("""SELECT id, text, created_ms AS createdAtMs,
                         CASE WHEN phase IN ('accepted', 'partial') THEN reply END AS reply, phase
                         FROM messages WHERE owner = ? ORDER BY sequence DESC LIMIT 40""", (account["owner"],))
    records = [dict(row) for row in rows][::-1]
    for record in records:
        record["attachments"] = attachment_view(db, root, record["id"], "inbound")
        record["replyAttachments"] = attachment_view(db, root, record["id"], "outbound")
    return records


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("command", choices=("poll", "reply", "fail", "recover", "status", "history", "offline"))
    parser.add_argument("value", nargs="?")
    args = parser.parse_args()
    root = args.root.resolve()
    with closing(open_database(root)) as db:
        result = {"ok": True}
        if args.command == "poll":
            result = poll(db, args.value, root)
        elif args.command == "reply":
            message = json.loads(Path(args.value).read_text(encoding="utf-8-sig"))
            stage_reply(db, message["id"], message["text"], root, message.get("attachments", []))
        elif args.command == "fail":
            db.execute("UPDATE messages SET phase = 'answer_failed' WHERE id = ? AND phase = 'answering'", (args.value,))
        elif args.command == "recover":
            recover(db)
        elif args.command == "status":
            result = report_status(db)
        elif args.command == "history":
            result = {"messages": history(db, root)}
        elif args.command == "offline":
            account = account_at(db)
            if account and account["generation"] == args.value and not account["needs_binding"]:
                account_client(account)("msg/notifystop", {}, timeout=4)
        print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except TransportError as error:
        sys.exit(str(error))
    except TimeoutError:
        sys.exit("iLink timed out")
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error):
        sys.exit("The Weixin transport could not complete the local operation")
