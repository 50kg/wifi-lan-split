# 参与贡献 · Contributing

**简体中文** | [English](#english)

感谢你愿意改进双网分流。这个工具会改动别人电脑的防火墙和路由，所以下面这些约定比一般项目严格。

## 开发环境

- Windows 10/11 x64，Windows PowerShell 5.1，.NET Framework 4.x。
- 不需要 Visual Studio，`build.ps1` 用系统自带的 `csc.exe` 编译。
- 不要引入需要联网下载的依赖。

## 动手之前

- 先读 [需求说明.md](需求说明.md) 和 [docs/架构与安全边界.md](docs/架构与安全边界.md)。
- **开发和测试都不要改动本机网络**：不要在开发机上执行启用、还原、续租、修复，也不要停掉 RouteGuard。需要验证逻辑时，写隔离测试（见下文）。
- 真要做断网实测，必须先安排一个独立的自动恢复（例如定时重新连接 Wi-Fi），并保持防火墙保护。

## 不要改变的设计约束

- 防火墙是阻断公网的主体。不能用“调高有线跃点”或“删一次默认路由”来代替防火墙。
- 有线只放行 `192.168.0.0/16`。不要扩大到 `10.0.0.0/8` 或 `172.16.0.0/12`，也不要增加端口限制。热点子网继续走 Wi-Fi。
- 不宣称已经解决代理、隧道（Tailscale 等 VPN）、虚拟机这些边界上的问题。
- 改动前先备份；还原按网卡 GUID 和 Windows 安装标识核对，不按接口编号猜测。

## 代码约定

- PowerShell 要兼容 Windows PowerShell 5.1。含中文的 `.ps1` 必须保存为 **UTF-8 with BOM**，否则 5.1 会按本地代码页读成乱码。行尾用 CRLF。
- C# 只能用系统 .NET Framework 编译器支持的 C# 5 语法：不能用 `?.`、`$""`、`nameof`、`out var`、表达式体成员。
- 在双引号字符串里，PowerShell 会把中文弯引号 `“”` 当成字符串的引号。中文文案请放在单引号字符串里。
- 改了 `backend.ps1`、`network-core.ps1` 或 `RouteGuard.cs`，必须重新运行 `build.ps1`。界面会核对构建时写入的哈希，不一致就拒绝运行。
- 界面文案用简体中文，用户能看懂的说法优先；结论先回答“网线现在能不能上公网”。

## 测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

- 每个测试先 dot-source `tests/TestSupport.ps1`，它会把所有网络、防火墙、DNS、网卡和计划任务命令替换成会报错的函数。新测试也要这样做，再为用到的命令写替身。
- 把被测脚本指向临时目录后，调用 `Use-TestRoot`。它会确认路径没有指向 `C:\ProgramData`，并挡住以完整路径调用的 `netsh`、`ipconfig`。
- 测试数据一律虚构，可以用 `192.0.2.0/24`、`203.0.113.0/24` 这类文档专用地址。
- 改了界面，用 `双网分流.exe --preview <目录>` 生成 100%–175% 的截图。看一遍截图，并确认 `layout-report.txt` 里没有裁字、越界和重叠。加上 `--screen 1024x768` 可以模拟小屏幕。

## 不要提交

- 任何电脑的 `state.json`、防火墙完整导出（`.wfw`）、网卡 GUID、MachineGuid；
- 抓包文件、运行日志；
- 公司或家庭网络的真实地址清单；
- `dist/` 和 `build/` 目录（由 `.gitignore` 排除，发布版本通过 Release 提供）。

## 提交 PR

- 说明改了什么、为什么改，以及如何验证：运行了哪些测试，有没有在真机上做过只读检查。
- 涉及网络行为的改动，请写清楚“已验证 / 推断 / 未验证”。

---

## English

Thank you for helping improve wifi-lan-split. This tool changes the firewall and routing of other people's computers, so the rules below are stricter than in most projects.

### Development environment

- Windows 10/11 x64, Windows PowerShell 5.1, .NET Framework 4.x.
- No Visual Studio needed: `build.ps1` compiles with the system's own `csc.exe`.
- Do not add dependencies that must be downloaded.

### Before you start

- Read [需求说明.md](需求说明.md) ([English](docs/en/requirements.md)) and [docs/en/architecture.md](docs/en/architecture.md).
- **Do not change your own network while developing or testing.** Do not run enable, restore, renew or repair on your development machine, and do not stop RouteGuard. To verify logic, write an isolated test (see below).
- If you really need a disconnect test, schedule an independent automatic recovery first (for example, reconnecting Wi-Fi on a timer) and keep the firewall protection in place.

### Design constraints that must not change

- The firewall is what blocks the Internet. Do not replace it with "raise the wired metric" or "delete the default route once".
- The cable is allowed only `192.168.0.0/16`. Do not widen it to `10.0.0.0/8` or `172.16.0.0/12`, and do not add port limits. The hotspot subnet stays on Wi-Fi.
- Do not claim to solve proxies, tunnels (VPNs such as Tailscale) or virtual machines.
- Back up before changing anything; restore matches adapters by GUID and the Windows installation ID, never by interface index.

### Code conventions

- PowerShell must work on Windows PowerShell 5.1. A `.ps1` that contains Chinese must be saved as **UTF-8 with BOM**, or 5.1 reads it with the local code page and garbles it. Use CRLF line endings.
- C# is limited to the C# 5 syntax that the system .NET Framework compiler supports: no `?.`, `$""`, `nameof`, `out var` or expression-bodied members.
- PowerShell treats the Chinese curly quotes `“”` as string quotes inside double-quoted strings. Put Chinese text in single-quoted strings.
- After changing `backend.ps1`, `network-core.ps1` or `RouteGuard.cs`, run `build.ps1` again. The window checks the hashes recorded at build time and refuses to run on a mismatch.
- Interface text is Simplified Chinese, in words users understand; a verdict first answers "can the cable reach the Internet right now".

### Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

- Every test first dot-sources `tests/TestSupport.ps1`, which replaces all network, firewall, DNS, adapter and scheduled-task commands with functions that throw. New tests must do the same, then mock the commands they use.
- After pointing the script under test at a temp folder, call `Use-TestRoot`. It checks that no path points at `C:\ProgramData` and blocks `netsh` and `ipconfig` called by full path.
- Test data is always made up; use documentation ranges such as `192.0.2.0/24` and `203.0.113.0/24`.
- After changing the window, render 100%–175% screenshots with `双网分流.exe --preview <folder>`. Look through them, and check that `layout-report.txt` reports no clipped text, overflow or overlap. Add `--screen 1024x768` to simulate a small screen.

### Do not commit

- Any computer's `state.json`, full firewall exports (`.wfw`), adapter GUIDs or MachineGuid;
- capture files or runtime logs;
- real address lists of office or home networks;
- the `dist/` and `build/` folders. `.gitignore` excludes them, and releases are published through GitHub Releases.

### Pull requests

- Explain what changed, why, and how you verified it: which tests ran, and whether you did a read-only check on a real machine.
- For changes to network behaviour, state clearly what is verified, what is inferred and what is not verified.

