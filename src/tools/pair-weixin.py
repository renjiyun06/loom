"""Show the iLink QR code locally and save a confirmed personal binding."""

from contextlib import closing
from pathlib import Path
from queue import Empty, Queue
import sys
from threading import Event, Thread
import time
import tkinter as tk
from tkinter import ttk

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src" / "runtime"))
sys.path.insert(0, str(ROOT / "runtime" / "weixin"))

from weixin_transport import BASE, TransportError, open_database, report_status, request, store_binding, weixin_origin


class PairingWindow:
    def __init__(self):
        self.window = tk.Tk()
        self.window.title("织境 · 绑定微信")
        self.window.geometry("510x520")
        self.window.attributes("-topmost", True)
        self.window.after(6000, lambda: self.window.attributes("-topmost", False))
        self.window.protocol("WM_DELETE_WINDOW", self.close)
        self.events = Queue()
        self.codes = Queue()
        self.stop = Event()
        panel = ttk.Frame(self.window, padding=20)
        panel.pack(fill="both", expand=True)
        ttk.Label(panel, text="绑定织境的微信入口", font=("Microsoft YaHei UI", 17, "bold")).pack(pady=(0, 10))
        self.status = tk.StringVar(value="正在向微信申请二维码…")
        ttk.Label(panel, textvariable=self.status, wraplength=445, justify="center").pack(pady=4)
        self.canvas = tk.Canvas(panel, width=300, height=300, background="white", highlightthickness=0)
        self.pin = ttk.Frame(panel)
        self.code = ttk.Entry(self.pin, show="*", width=16)
        self.code.pack(side="left", padx=8)
        self.pin_button = ttk.Button(self.pin, text="提交验证码", command=self.submit_code)
        self.pin_button.pack(side="left")
        ttk.Button(panel, text="关闭", command=self.close).pack(side="bottom")

    def close(self):
        self.stop.set()
        self.window.destroy()

    def submit_code(self):
        value = self.code.get().strip()
        if value.isascii() and value.isdigit() and len(value) <= 12:
            self.codes.put(value)
            self.code.delete(0, "end")
            self.pin_button.configure(state="disabled")

    def show_qr(self, content):
        import qrcode

        qr = qrcode.QRCode(border=4)
        qr.add_data(content)
        qr.make(fit=True)
        matrix = qr.get_matrix()
        scale = 300 // len(matrix)
        margin = (300 - scale * len(matrix)) // 2
        self.canvas.delete("all")
        for row, modules in enumerate(matrix):
            for col, dark in enumerate(modules):
                if dark:
                    x, y = margin + col * scale, margin + row * scale
                    self.canvas.create_rectangle(x, y, x + scale, y + scale, fill="black", width=0)
        self.pin.pack_forget()
        self.canvas.pack(pady=10)
        self.status.set("请用手机微信「扫一扫」扫描二维码，再在手机上确认绑定。")

    def update(self):
        while True:
            try:
                kind, text = self.events.get_nowait()
            except Empty:
                break
            if kind == "qr":
                self.show_qr(text)
                continue
            self.status.set(text)
            self.pin.pack_forget()
            if kind == "pin":
                self.pin.pack(pady=4)
                self.pin_button.configure(state="normal")
                self.code.focus_set()
            if kind == "done":
                self.canvas.pack_forget()
        self.window.after(100, self.update)

    def pair(self):
        try:
            import qrcode  # Check the display dependency before requesting a credential.
        except ImportError:
            self.events.put(("done", "本机缺少二维码组件 qrcode。请按织境文档安装后重开绑定窗口。"))
            return
        try:
            with closing(open_database(ROOT)) as db:
                if report_status(db)["phase"] != "bound":
                    self.bind(db)
                self.events.put(("done", "微信已绑定。现在可以在手机的「微信 ClawBot」窗口给织境发送文字。"))
        except (TransportError, TimeoutError, OSError, ValueError) as error:
            description = str(error) if isinstance(error, TransportError) else "无法完成微信绑定，请重开窗口再试。"
            self.events.put(("done", description))

    def bind(self, db):
        deadline = time.monotonic() + 420
        for _ in range(3):
            self.check_wait(deadline)
            issued = request("get_bot_qrcode", params={"bot_type": 3}, data={"local_token_list": []})
            if not all(isinstance(issued.get(key), str) and issued[key] for key in ("qrcode", "qrcode_img_content")):
                raise TransportError("微信未返回可用的绑定二维码。")
            self.events.put(("qr", issued["qrcode_img_content"]))
            params = {"qrcode": issued["qrcode"]}
            origin = BASE
            while True:
                self.check_wait(deadline)
                try:
                    reply = request("get_qrcode_status", origin=origin, params=params, timeout=35)
                except TimeoutError:
                    continue
                state = reply.get("status")
                if state == "confirmed":
                    self.check_wait(deadline)
                    store_binding(db, reply)
                    return
                if state == "expired":
                    break
                if state == "verify_code_blocked":
                    raise TransportError("微信已锁定本次验证码，请按手机端提示操作。")
                if state == "binded_redirect":
                    raise TransportError("微信显示该会话已绑定，并未签发本次连接所需的凭证。")
                if state == "scaned_but_redirect":
                    origin = weixin_origin("https://" + (reply.get("redirect_host") or ""))
                if state in ("scaned", "scaned_but_redirect"):
                    params.pop("verify_code", None)
                    self.events.put(("progress", "已扫码，等待手机确认。"))
                if "need_verifycode" in str(state):
                    self.events.put(("pin", "请输入手机微信显示的验证码。"))
                    while True:
                        self.check_wait(deadline)
                        try:
                            params["verify_code"] = self.codes.get(timeout=0.5)
                            break
                        except Empty:
                            continue
                self.stop.wait(0.5)
        raise TransportError("微信二维码已失效。需要时可重开绑定窗口。")

    def check_wait(self, deadline):
        if self.stop.is_set() or time.monotonic() >= deadline:
            raise TransportError("已结束等待微信确认。")

    def run(self):
        Thread(target=self.pair, daemon=True).start()
        self.window.after(100, self.update)
        self.window.mainloop()


if __name__ == "__main__":
    PairingWindow().run()
