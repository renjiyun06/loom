---
id: "readme"
title: "织境（Loom）"
summary: "面向使用者的启动入口，说明怎样打开织境环境、原生文字对话标签，以及到哪里阅读现行说明。"
updated: "2026-11-22T08:16:23+08:00"
---
# 织境（Loom）

本环境统一位于 `D:\Loom`。Glamorous Toolkit 承载程序、活对象和原生界面，程序通过本机 Codex App Server 请求模型，模型可以检查并演进发起调用的同一个运行环境。

桌面 **织境** 快捷方式启动或唤出本工程的 Glamorous Toolkit，沿用当前已提交镜像。它不额外打开对话窗口。也可以执行：

```powershell
& D:\Loom\start.ps1 -Gui
& D:\Loom\stop.ps1
```

需要对话时，点击 GT 主窗口右上角的聊天图标，在同一窗口中打开「织境对话」标签。麦克风入口可录制和发送语音，原音和讯飞转录显示在同一条消息里。关闭后可由图标重新打开，历史与未发送草稿保留，也可以运行 `runtime\node\node.exe src\bridge\open-conversation.mjs`。原生 Save 和保存退出均接入统一恢复流程，详见 [保存恢复与生命周期](workspace/03-保存恢复与生命周期.md)。

Codex 的 `cwd` 指向 `workspace`，这里只作为环境加载入口，不是默认的业务工作目录。助理从 [AGENTS.md](workspace/AGENTS.md) 认识环境，再按目录选择现行文档：

- [环境组成与目录](workspace/00-环境组成与目录.md)
- [运行环境的观察与演进](workspace/01-运行环境的观察与演进.md)
- [对话程序与调用机制](workspace/02-对话程序与调用机制.md)
- [保存恢复与生命周期](workspace/03-保存恢复与生命周期.md)
- [工具技能与能力发现](workspace/04-工具技能与能力发现.md)
- [验证与故障排查](workspace/05-验证与故障排查.md)
- [文档编写与维护](workspace/06-文档编写与维护.md)
- [长录音消息与转录](workspace/07-长录音消息与转录.md)

运行程序、长期状态、日志和验证结果各自保存在根目录下的对应位置。
