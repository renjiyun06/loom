"""Weixin iLink transport and durable queue for the GT message worker."""

import argparse
import base64
from contextlib import closing, contextmanager
import ctypes
from ctypes import wintypes
import json
from pathlib import Path
import secrets
import sqlite3
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from uuid import uuid4


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


def inbound_text(message, owner, bound_ms):
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
    texts = [item["text_item"]["text"] for item in items
             if isinstance(item, dict) and item.get("type") in (1, "1")
             and isinstance(item.get("text_item"), dict) and isinstance(item["text_item"].get("text"), str)]
    body = "\n".join(texts).strip()
    if not body:
        return None
    try:
        created = int(message.get("create_time_ms") or 0)
    except (TypeError, ValueError):
        created = 0
    if created and created < bound_ms - 5_000:
        return None
    return str(remote), body, context, created or None


def save_updates(db, account, updates):
    messages = updates.get("msgs") or []
    if not isinstance(messages, list):
        raise TransportError("iLink returned an invalid message list")
    added = 0
    with transaction(db):
        if account_at(db)["generation"] != account["generation"]:
            return {}
        for message in messages:
            data = inbound_text(message, account["owner"], account["bound_ms"])
            if data is not None:
                phase = "pending" if data[2] else "missing_context"
                row = db.execute("""INSERT INTO messages (id, bot, owner, remote_id, text, context, created_ms, phase)
                                    VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (bot, owner, remote_id) DO NOTHING""",
                                 (uuid4().hex, account["bot"], account["owner"], *data, phase))
                added += row.rowcount
        cursor = updates.get("get_updates_buf")
        if isinstance(cursor, str) and cursor:
            db.execute("UPDATE account SET cursor = ? WHERE singleton = 1", (cursor,))
    return {"received": len(messages), "recorded": added}


def take(db, account, from_phase, to_phase):
    with transaction(db):
        if account_at(db)["generation"] != account["generation"]:
            return None
        item = db.execute("SELECT * FROM messages WHERE bot = ? AND owner = ? AND phase = ? ORDER BY sequence LIMIT 1",
                          (account["bot"], account["owner"], from_phase)).fetchone()
        if item:
            db.execute("UPDATE messages SET phase = ? WHERE id = ?", (to_phase, item["id"]))
        return item


def post_part(db, account, client, item):
    parts = json.loads(item["parts"])
    part = item["next_part"]
    try:
        result = client("sendmessage", {"msg": {
            "from_user_id": "", "to_user_id": account["owner"], "context_token": item["context"],
            "client_id": f"loom-{item['id']}-{part}", "message_type": 2, "message_state": 2,
            "item_list": [{"type": 1, "text_item": {"text": parts[part]}}],
        }})
    except Rejected as error:
        phase = "reply_ready" if error.code == -14 else "send_failed"
        db.execute("UPDATE messages SET phase = ?, error = ? WHERE id = ?", (phase, str(error), item["id"]))
        raise
    except (TransportError, TimeoutError):
        db.execute("UPDATE messages SET phase = 'delivery_unknown' WHERE id = ?", (item["id"],))
        raise
    # An HTTP-level acknowledgement without a message ID does not establish delivery.
    response_id = result.get("message_id")
    phase = "accepted" if part + 1 == len(parts) else "reply_ready"
    if not response_id:
        phase = "delivery_unconfirmed"
    db.execute("UPDATE messages SET phase = ?, next_part = ?, server_reply_id = ?, error = NULL WHERE id = ?",
               (phase, part + 1, str(response_id) if response_id else None, item["id"]))
    return {"phase": phase}


def poll(db, online_generation):
    account = account_at(db)
    if not account or account["needs_binding"]:
        return {"phase": "awaiting_binding"}
    client = account_client(account)
    generation = account["generation"]
    try:
        if generation != online_generation:
            client("msg/notifystart", {}, timeout=10)
        item = take(db, account, "reply_ready", "sending")
        if item:
            result = post_part(db, account, client, item)
        else:
            item = take(db, account, "pending", "answering")
            diagnostics = {}
            if not item:
                try:
                    updates = client("getupdates", {"get_updates_buf": account["cursor"]}, timeout=42)
                except TimeoutError:
                    diagnostics = {"pollTimedOut": True}
                else:
                    diagnostics = save_updates(db, account, updates)
                item = take(db, account, "pending", "answering")
            result = {"phase": "ready", "message": None, **diagnostics}
            if item:
                result["message"] = {"id": item["id"], "text": item["text"], "kind": "text"}
    except Rejected as error:
        if error.code != -14:
            raise
        db.execute("UPDATE account SET needs_binding = 1 WHERE generation = ?", (generation,))
        return {"phase": "awaiting_binding"}
    return {**result, "onlineGeneration": generation}


def stage_reply(db, message_id, text):
    body = text.strip()
    if not body:
        raise TransportError("The Weixin reply is empty")
    # Keep each part under the client limit, including surrogate pairs on UTF-16 clients.
    parts = [body[index:index + 1900] for index in range(0, len(body), 1900)]
    row = db.execute("""UPDATE messages SET reply = ?, parts = ?, phase = 'reply_ready'
                        WHERE id = ? AND phase = 'answering'""", (body, json.dumps(parts), message_id))
    if not row.rowcount:
        raise TransportError("The Weixin message is not waiting for a reply")


def recover(db):
    with transaction(db):
        db.execute("UPDATE messages SET phase = 'interrupted' WHERE phase = 'answering'")
        db.execute("UPDATE messages SET phase = 'delivery_unknown' WHERE phase = 'sending'")


def report_status(db):
    account = account_at(db)
    state = "bound" if account and not account["needs_binding"] else "awaiting_binding"
    if not account:
        return {"phase": state, "counts": {}}
    scope = (account["bot"], account["owner"])
    counts = dict(db.execute("SELECT phase, COUNT(*) FROM messages WHERE bot = ? AND owner = ? GROUP BY phase", scope))
    return {"phase": state, "counts": counts}


def history(db):
    account = account_at(db)
    if not account:
        return []
    rows = db.execute("""SELECT id, text, created_ms AS createdAtMs,
                         CASE WHEN phase = 'accepted' THEN reply END AS reply, phase
                         FROM messages WHERE owner = ? ORDER BY sequence DESC LIMIT 40""", (account["owner"],))
    return [dict(row) for row in rows][::-1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("command", choices=("poll", "reply", "fail", "recover", "status", "history", "offline"))
    parser.add_argument("value", nargs="?")
    args = parser.parse_args()
    with closing(open_database(args.root)) as db:
        result = {"ok": True}
        if args.command == "poll":
            result = poll(db, args.value)
        elif args.command == "reply":
            message = json.loads(Path(args.value).read_text(encoding="utf-8-sig"))
            stage_reply(db, message["id"], message["text"])
        elif args.command == "fail":
            db.execute("UPDATE messages SET phase = 'answer_failed' WHERE id = ? AND phase = 'answering'", (args.value,))
        elif args.command == "recover":
            recover(db)
        elif args.command == "status":
            result = report_status(db)
        elif args.command == "history":
            result = {"messages": history(db)}
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
