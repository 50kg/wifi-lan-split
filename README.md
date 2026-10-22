# 双网分流 · wifi-lan-split

**简体中文** | [English](README.en.md)

[![CI](https://github.com/50kg/wifi-lan-split/actions/workflows/ci.yml/badge.svg)](https://github.com/50kg/wifi-lan-split/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Windows 10/11](https://img.shields.io/badge/Windows-10%20%2F%2011-0078D6)

一台 Windows 电脑同时连着**手机热点 Wi-Fi** 和**公司网线**时：

- 公网只走 Wi-Fi，网线只能访问 `192.168.0.0/16` 内网；
- Wi-Fi 断了，网线也不会接管公网；
- 用 Windows 自带防火墙和一个很小的路由看守实现，不装驱动、不联网下载任何东西；
- 每一步都可以检查，也可以还原。

<p align="center"><img src="docs/images/status-ok.png" width="560" alt="分流已生效时的主界面"></p>

## 为什么需要它

两张网卡同时在线时，Windows 会按“跃点数”自动挑出口，公网流量很可能走公司网线。公司网络因此能看到、记录甚至拦截这些流量，有的单位还明确禁止用办公网访问外网。

手动调网卡跃点不可靠：公司 DHCP 续租时会把网线的默认网关加回来，Wi-Fi 一断，Windows 也会立刻改走网线。

双网分流把“网线只进内网”交给防火墙强制执行，路由只负责让流量走对的口。即使路由表瞬间出错，防火墙也会拦住。

## 它做了什么

| 层 | 作用 |
| --- | --- |
| 防火墙（主保障） | 有线接口阻断 192.168.0.0/16 以外的全部 IPv4 和全部 IPv6，不分应用、协议和端口；保留 DHCP 广播。热点子网落在 192.168 内时，额外从有线阻断。 |
| 路由 | Wi-Fi 跃点优先；网线只保留经公司网关到 192.168.0.0/16 的路由；网线 DNS 改用 Wi-Fi 的 DNS。 |
| 路由看守 | `RouteGuard.exe` 以 SYSTEM 开机运行，通过 Windows IP Helper 监听路由变化，删除 DHCP 补回的网线默认路由。 |
| 备份与还原 | 改动前先备份防火墙和网络参数；还原时按网卡 GUID 和 Windows 安装标识核对，拒绝跨机器误还原。 |

界面打开就自动检查。最上面一句话就是结论，下面逐项写出当前值，有问题的项排在最前，能修的问题旁边就是修复按钮。

<p align="center">
  <img src="docs/images/status-problem.png" width="420" alt="发现另一块网线网卡没有保护">
  <img src="docs/images/confirm-setup.png" width="380" alt="启用前的确认框">
</p>

<sub>截图使用虚构数据。</sub>

## 快速开始

**环境**：Windows 10/11 64 位，自带的 Windows PowerShell 5.1 和 .NET Framework 4.x，Windows 防火墙处于开启状态。

1. 从 [Releases](https://github.com/50kg/wifi-lan-split/releases) 下载 zip，**完整解压**到只有管理员能写入的位置，例如 `C:\Program Files\双网分流`。
2. 先连上手机热点 Wi-Fi，再插公司网线。网线需要用 DHCP 拿到 192.168.x.x 的地址和网关。
3. 双击 `双网分流.exe`，接受管理员提示。
4. 点“启用分流…”。确认框会列出所有改动，确认后才执行。
5. 以后打开看结论即可。“还原设置…”会恢复启用前的全部网络参数。

程序没有代码签名，第一次运行时 Windows SmartScreen 可能提示“未知发布者”。不放心可以对照 Release 页面上的 SHA-256，或者[自己从源码构建](#从源码构建)。

详细用法见 [docs/使用说明.txt](docs/使用说明.txt)。

## 安全设计

- **只读检查**：打开界面、按 F5、点“重新检查”都只读取配置，不改网络。
- **后台文件校验**：界面以管理员身份运行，不直接执行程序目录里的脚本。构建时，三个后台文件的 SHA-256 写进 exe；运行前逐个核对，再从只有 SYSTEM/管理员可写的数据目录执行。文件被改过就拒绝运行。
- **受保护的数据目录**：`C:\ProgramData\WifiLanSplit` 创建时就只授权 SYSTEM 和 Administrators；发现被别人预先创建，就拒绝继续。
- **同一时间只做一件事**：启用、修复、续租、还原互斥。关掉窗口不会中断正在进行的操作。
- **看守本身也要稳**：更新看守时，先备好新程序再替换，替换失败就放回旧的；开机任务始终保持注册。心跳只在检查成功后写，所以“运行中”就代表它真的在工作。

完整说明见 [docs/架构与安全边界.md](docs/架构与安全边界.md)。

## 能力边界

请在使用前读完这一节。

- **防火墙才是主保障**：看守在 DHCP 补回默认路由之后才删除它，中间这段时间靠防火墙拦截。
- **管不了间接转发**：只按目标地址和网卡控制。允许访问的 192.168 内网服务器如果替你转发公网（代理、跳板机），本工具管不到。
- **隧道和虚拟网卡不在范围内**：Tailscale 等 VPN、虚拟机桥接、WSL/Docker 虚拟网卡、内核驱动，都不在控制范围内。界面会把它们列出来，但不会处理。
- **管理员可以改掉一切**：有管理员权限的软件或公司组策略可以修改这些设置。本工具不是对抗管理员的隔离系统。
- **内网域名可能解析不了**：网线 DNS 换成了热点的 DNS，公司内网服务建议用 IP 访问。
- **已验证和未验证的范围**：作者的电脑上做过断网抓包、续租和重启验证，详见[验证记录](docs/验证记录.md)。其他硬件、其他网络环境、第二台电脑的首次安装还没有验证。

## 从源码构建

不需要联网，也不需要安装 Visual Studio，用系统自带的 .NET Framework 编译器即可：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

产物在 `dist/`。**改了 `backend.ps1`、`network-core.ps1` 或 `RouteGuard.cs` 之后必须重新构建**，否则界面校验不通过，会拒绝运行。

## 测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

`Run-Tests.ps1` 依次执行：

- 语法与编码检查；
- 构建到临时目录；
- 启用、还原、状态判断、看守更新的隔离模拟；
- 后台文件校验测试；
- 界面在 100%–175% 缩放下的布局检查，本机屏幕和模拟的 1024×768 小屏幕各跑一遍。

所有网络、防火墙和计划任务命令都先被替换成会报错的函数，漏掉替身的命令会直接让测试失败，碰不到真实系统。后两项需要管理员 PowerShell。GitHub Actions 每次提交都会运行这套测试。

界面预览只用虚构数据，不调用后台：

```powershell
.\dist\双网分流.exe --preview .\build\preview
.\dist\双网分流.exe --preview .\build\preview-small --screen 1024x768
```

## 项目结构

```text
src/native/        WinForms 界面 LanSplit.cs、路由看守 RouteGuard.cs、程序清单
src/powershell/    backend.ps1（检查/启用/修复/续租/还原入口）、network-core.ps1（备份、防火墙、路由、DNS）、离线还原 Restore.cmd
src/postboot/      可选的重启后一次性检查脚本
src/diagnostics/   只读诊断脚本（PowerShell 模块加载问题），构建时复制到程序文件夹
tests/             隔离测试与测试运行器
docs/              中文文档：使用说明、架构与安全边界、验证记录；docs/en/ 是英文版
build.ps1          只编译和打包到 dist/，不安装、不启动
```

## 参与贡献

欢迎提交 issue 和 PR，请先读 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## 许可证

[MIT](LICENSE)
