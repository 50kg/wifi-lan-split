# 更新记录 · Changelog

**简体中文** | [English](#english)

## 未发布

- 修复：屏幕比窗口窄（例如 1024×768 屏幕配 175% 缩放）时，界面会超出屏幕，内容整体上移几个像素。现在宽度和高度不够时都会出现滚动条，并且每次重新排版都从顶部开始。
- 测试：界面布局检查增加一轮“模拟 1024×768 屏幕”；预览模式新增 `--screen 宽x高` 参数。
- 文档：README、使用说明、架构与安全边界、验证记录、需求说明增加英文版；程序文件夹里多了 `User-Guide.en.md`。

## v1.0.0 — 2026-10-20

第一个公开版本。

### 分流与保护
- 防火墙阻断有线访问 192.168.0.0/16 以外的 IPv4 和全部 IPv6，不限应用、协议和端口；热点子网落在 192.168 内时额外阻断。
- 路由看守 `RouteGuard.exe` 以 SYSTEM 开机运行，删除 DHCP 补回的网线默认路由。它会：
  - 单轮出错不退出；
  - 只在检查成功后写心跳；
  - 日志限频，并在过大时轮转。
- 改动前先备份，还原时按网卡 GUID 和 Windows 安装标识核对。
- `state.json` 先写临时文件再整体替换，同时另存一份启用时的原始副本。

### 界面
- 打开就做只读检查：顶部是结论和原因，下面逐项列出当前值，有问题的项排在最前，能自动修复时直接给出修复按钮。
- 启用和还原前都有确认框，先写清后果。
- 操作失败时单独提示，可以重试或查看日志。
- 能识别另一块未受保护的网线网卡、热点网段变化、看守版本过旧、另一项操作正在进行等情况。
- 支持 100%–175% 显示缩放。

### 安全
- 界面运行后台前，核对构建时写入的 SHA-256，然后从受保护目录执行。
- 外部程序都用完整路径启动。
- 数据目录创建时就收紧权限，发现被预先创建就拒绝继续。
- 启用、修复、续租、还原互斥执行；关掉窗口不会中断后台操作。
- 更新看守时，先备好新程序再替换，失败就放回旧的；开机任务保持注册。

### 测试
- `tests/Run-Tests.ps1` 包括：
  - 语法与编码检查、构建；
  - 启用、还原、状态判断、看守更新的隔离模拟；
  - 文件校验测试；
  - 界面布局检查。
  网络命令一律替换成会报错的替身。

---

## English

### Unreleased

- Fix: on a screen narrower than the window (for example 1024×768 at 175% scaling) the window overflowed the screen and its content shifted up a few pixels. It now scrolls when either the width or the height does not fit, and every layout pass starts from the top.
- Tests: the UI layout check also runs on a simulated 1024×768 screen; preview mode gains a `--screen WxH` option.
- Docs: English versions of the README, user guide, architecture, verification record and requirements; the program folder now includes `User-Guide.en.md`.

### v1.0.0 — 2026-10-20

First public release.

#### Split and protection
- The firewall blocks the cable from IPv4 outside 192.168.0.0/16 and from all IPv6, for every application, protocol and port; the hotspot subnet is also blocked when it lies inside 192.168.
- The route guard `RouteGuard.exe` runs as SYSTEM from boot and removes default routes that DHCP adds back to the cable. It:
  - keeps running when a pass fails;
  - writes its heartbeat only after a successful pass;
  - rate-limits its log and rotates it when it grows too large.
- Everything is backed up before a change; restore checks adapter GUIDs and the Windows installation ID.
- `state.json` is written to a temporary file and swapped in, and an untouched copy from the moment of enabling is kept.

#### Interface
- A read-only check on open: the verdict and its reason at the top, every check with its current value below, problems first, and a fix button when the tool can fix it.
- Confirmation dialogs before enabling and restoring, stating the consequence first.
- A failed action gets its own notice with retry and log.
- Recognises an unprotected second wired adapter, a changed hotspot subnet, an outdated guard and another operation in progress.
- Supports 100%–175% display scaling.

#### Security
- The window verifies the backend's SHA-256 recorded at build time before running it from a protected folder.
- External programs are started by their full path.
- The data folder is locked down when it is created; a folder created by someone else first is refused.
- Enable, repair, renew and restore are mutually exclusive; closing the window does not interrupt a background operation.
- Updating the guard stages the new program first and puts the old one back on failure; the boot task stays registered.

#### Tests
- `tests/Run-Tests.ps1` covers:
  - syntax and encoding checks, and the build;
  - isolated simulations of enable, restore, status and guard update;
  - the file-integrity check;
  - a UI layout check.

  Every network command is replaced by a stub that throws.

