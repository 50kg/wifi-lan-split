# wifi-lan-split · User guide

[简体中文](../使用说明.txt) | **English**

> The interface is in Simplified Chinese. Labels are given in Chinese with an English gloss.

## Purpose

- Wi-Fi connects to a phone hotspot and carries the Internet.
- The office cable reaches only the 192.168.x.x LAN, with no extra port limits.
- The hotspot's own subnet stays on Wi-Fi and cannot be reached over the office cable.
- Proxies or tunnels on the LAN that relay the Internet are not handled.

## Using it

1. Extract the whole package to a fixed folder, ideally one only administrators can write to, such as `C:\Program Files\双网分流`. Double-click `双网分流.exe` and accept the administrator prompt.
2. The window checks once on open, and the top line is the verdict:
   - **Green**, 分流已生效 (Split in effect): the cable reaches only the 192.168 LAN; the Internet goes through Wi-Fi.
   - **Amber**: something needs attention, but the cable is not exposed. Example: 路由看守没有运行 (Route guard not running), while the firewall still blocks.
   - **Red**: the cable may be able to reach the Internet. Examples: 尚未启用分流 (Not enabled yet), "USB 以太网"可以直接上公网 ("USB Ethernet" can reach the Internet).

   Under the verdict are the reason and the next step. When the tool can fix it, a button appears, such as 修复路由看守 (Repair route guard).
3. On a computer where the split is already enabled, opening the window and reading the verdict is enough; do not enable it again.
4. **First use**:
   - get Wi-Fi online first, then connect the office cable;
   - close sensitive software that depends on a fixed exit;
   - click 启用分流… (Enable split…). A dialog lists every setting that will change, and nothing happens until you confirm.

   Before the tool runs there is no protection from it, and plugging in the cable can by itself make Windows use the office exit. To avoid that window, an administrator should deploy the firewall in advance.
5. 有线续租并验证 (Renew and verify the cable) appears only while the split is in effect. It renews the cable's lease only, with no release and no change to Wi-Fi, then checks the default routes and the guard.
6. 还原设置… (Restore settings…) asks for confirmation, then stops the guard and restores the network settings from the backup. After restoring, the cable may reach the Internet again, so close sensitive software first.
7. The tool and restore work without a network as well. You can also double-click `Restore.cmd` and type Y to restore. Keep the extracted folder complete.
8. 打开数据文件夹 (Open data folder) opens `C:\ProgramData\WifiLanSplit`, which holds this computer's state, backups and logs.
   - The full output of enable, repair, renew and restore is in `last-operation.log`; failure reasons are also written to `last-operation-error.txt`.
   - Closing the window during an operation does not interrupt it. If you reopen the window before it finishes, it shows 另一项操作正在进行 (another operation is in progress), and no new operation can start.
   - Never restore one computer's backup on another. Restore checks the Windows installation ID and the adapter GUIDs.
9. Press F5 or click 重新检查 (Check again) to check again. 查看日志 (View log) shows the actions taken since the window opened.

## What each check means

- **防火墙阻断 (Firewall blocking)**: the cable reaches only the 192.168 LAN and all IPv6 is blocked.
  - It checks the actual rules' addresses, protocols, ports, programs and interface scope, and that the firewall is on for every network profile; it does not just count rules.
  - "仅限" (only) followed by an adapter name means the rules apply to that one adapter.
- **网线默认路由 (Cable default routes)**: should be 0. A DHCP renewal may briefly add one back; the route guard removes it.
- **路由看守 (Route guard)**: the boot task exists and the heartbeat is less than 6 seconds old.
- **看守版本 (Guard version)**: appears when the running guard differs from this version.
  - Click 更新 (Update) on that row.
  - The update prepares the new program first, then swaps it in and restarts it; the boot task is kept.
  - If the swap fails, the old program is put back.
- **其他网线网卡 (Other wired adapters)**: another wired adapter is not covered by the block, or has a default route.
- **其他接口 (Other interfaces)**: Tailscale, VPNs and similar are outside this tool's control.

Checks only read the configuration. They never disconnect Wi-Fi and never capture traffic. A configuration check is not proof of actual traffic.

## Requirements and scope

- Windows 10/11 64-bit, Windows PowerShell 5.1, .NET Framework 4.x, and the built-in Windows Firewall.
- A first setup needs exactly one connected physical Wi-Fi adapter and one connected physical wired adapter.
- The cable stays on DHCP and must get a 192.168.x.x address and a 192.168.x.x gateway.
- Wi-Fi already has a working IPv4 address, default route and IPv4 DNS.
- The two adapters' subnets must not overlap.
- On a first setup, the tool stops and explains instead of changing third-party connections when it finds:
  - other active network interfaces (VPN, Tailscale, Hyper-V/WSL/Docker virtual adapters);
  - an existing /16 route;
  - a company policy that disables local firewall rules.
- Tailscale, VPNs and similar interfaces connected after enabling are neither closed nor configured; they are only listed in the checks.
- After changing the office gateway, hotspot, adapters or network environment, check again. When the hotspot subnet changes, the window tells you to restore and enable again.

## How the protection works

**Layer 1: the firewall.**
- The cable is blocked from IPv4 destinations outside 192.168.0.0/16 and from all IPv6. The local DHCP limited broadcast stays open.
- If the hotspot lies inside 192.168.x.x, the cable is also blocked from the hotspot subnet.
- The rules match every application, protocol and port, covering HTTP/HTTPS, WebSocket, TCP/UDP sockets, QUIC, DNS and more on the normal Windows network stack.
- The rules apply to all wired interfaces. A rule group left by an earlier version applies to one adapter only; it is still recognised, and the check then shows "仅限" (only) for that adapter.
- Existing inbound firewall rules stay in force; "all LAN ports" does not mean all inbound protection is off.

**Layer 2: routing and the guard.**
- The Internet default route prefers Wi-Fi; a persistent 192.168.0.0/16 route goes over the cable through the office gateway; the more specific hotspot subnet still goes over Wi-Fi.
- The cable's IgnoreDefaultRoutes is set to Enabled as a supplement. On the author's machine this switch alone did not stop DHCP renewals from adding the cable's default route back.
- So the tool installs a small local route guard:
  - the program is `C:\ProgramData\WifiLanSplit\RouteGuard.exe`, writable only by SYSTEM and administrators;
  - the scheduled task `WifiLanDefaultRouteGuard` starts it with the system, as SYSTEM;
  - it receives IPv4 route-change notifications from Windows IP Helper and also checks every 500 ms. A failed pass is logged and the guard keeps running. The heartbeat is written only after a successful pass, so a guard that keeps failing shows as not running;
  - it deletes only the IPv4 0.0.0.0/0 route of the configured wired adapter, finding the adapter by GUID each time;
  - it never touches Wi-Fi, never deletes LAN routes and configures no proxy;
  - it keeps running after the window closes. Restore stops the task, ends the program and removes the task.

## Limits you must understand

- This is "remove the default route after DHCP adds it", not a guarantee that it never appears for a moment. Notification handling and the fallback scan take time, and there is a window between boot and the guard starting. The firewall is always the main protection against real Internet traffic; never turn it off for the guard's sake.
- If DHCP must never create a default route, the office DHCP server has to stop handing a gateway to this computer, or the company has to approve a fixed address without a gateway. This tool does not change the office DHCP server.
- Allowing only private destinations on the cable does not stop a LAN proxy from reaching the Internet for you. To limit that, narrow the allowed LAN services or restrict the server side.
- The cable's DNS is switched to the hotspot's DNS, so office DNS names may not resolve; reach office services by IP.
- VM bridging, WSL/containers, extra VPNs, kernel drivers and other exits need separate verification.
- Software with administrator rights, company group policy or security software can change the configuration. This tool is not isolation against administrator rights.

## Backup and restore

- Before the first setup, state is saved and the firewall exported; only then are the block rules created and routes changed. The original backup is never overwritten, and the backup folder also keeps `state-at-setup.json` from the moment of enabling.
- Adapters in the backup are matched by GUID, so changed interface indexes do not matter. If an adapter cannot be found, the tool refuses to guess.
- Restore deletes this tool's rules (and the earlier rule group) and restores the original DNS, interface metrics, default-route preference, removed routes and firewall profile states.
- Restore does not import the whole old firewall, so later unrelated rules are not overwritten; the full export is kept for an administrator's emergency use.
- If setup fails half way, the block and the backup are kept and the block is not undone, so the office exit is never opened by accident. The window then shows 上次启用没有完成 (last enable did not finish); restore, then enable again.
- Enabling again after a restore creates a new backup and keeps the old ones.

## Files

- `双网分流.exe`: the native Windows window. Before running anything it verifies the three backend files below and refuses if they were changed.
- `RouteGuard.exe`: the background route guard. Do not run it by hand; the window deploys it.
- `backend.ps1` / `network-core.ps1`: readable configuration, check and restore logic.
- `Restore.cmd` / `Restore.ps1`: offline restore entry points.

The source is in the repository's `src` folder; rebuild with `build.ps1` in the repository root.

This is an unsigned tool built locally. It needs no runtime downloads, browser or cloud service; configuration changes need administrator rights.
