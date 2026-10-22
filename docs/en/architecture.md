# Architecture and security boundaries

[简体中文](../架构与安全边界.md) | **English**

## Call chain

`双网分流.exe` → verify the backend files and place them in a protected folder → child process Windows PowerShell (`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`) → `C:\ProgramData\WifiLanSplit\app\backend.ps1` → `network-core.ps1`.

The window runs as administrator, so it never executes the scripts in its own folder directly.

- At build time, the SHA-256 of `backend.ps1`, `network-core.ps1` and `RouteGuard.exe` is compiled into the window program.
- Before every operation (including a status check), the window reads the three files and verifies their hashes, then runs them from `ProgramData\WifiLanSplit\app`, which only SYSTEM and Administrators can write to.
  - If an identical, trusted copy is already there, it is left alone.
  - Otherwise the exact verified bytes are written to a temporary file and swapped in.
  - If a file in the program folder was modified or is missing, the window refuses to run and says why.
- The backend's output is not piped back to the window. The backend writes it to `last-operation.log` in the data folder, so closing the window cannot interrupt a change half way.
- PowerShell, Explorer, Notepad and Control Panel are started by their full system path, so files with the same name in the program folder or current folder cannot hijack them.
- Before running any command, the backend limits the module search path to Windows PowerShell's own `System32\WindowsPowerShell\v1.0\Modules`:
  - an inherited PowerShell 7 path cannot put a same-named module ahead of the built-in one (otherwise `Get-Acl` fails to load and every check fails);
  - the elevated backend never loads modules from the user's own writable `Documents\WindowsPowerShell\Modules`.

The data folder `C:\ProgramData\WifiLanSplit` is created by the window or the backend. It is created already restricted to SYSTEM and Administrators, owned by Administrators, without inheriting ProgramData's "users may create files" permission.

- If the folder already exists with a trusted owner but loose permissions, it is tightened, and every item already inside is checked. An untrusted owner or write permission on any of them stops the operation.
- If its owner is not SYSTEM, Administrators or TrustedInstaller, the tool refuses to continue and asks an administrator to check.
- Before enabling, repairing, renewing or restoring, the backend checks the owner and write permissions of `state.json` the same way.
  - If the owner is the current administrator account (some machines make new files belong to their creator), ownership is handed back to Administrators and the operation continues.
  - Anything else is refused.
- `state.json`, backup copies, the guard program and the backend copies written by the tool are explicitly owned by Administrators.

The background `RouteGuard.exe` receives route notifications through the native IP Helper API and does not depend on the window being open.

## Setup order

1. Identify the physical adapters; verify DHCP, addresses, gateway, DNS and that the subnets do not overlap. Stop if there are extra active adapters (VPN, Tailscale, Hyper-V/WSL/Docker virtual adapters) or conflicting routes.
2. Back up before changing anything:
   - `state.json`: machine state, original DNS, interface metrics, removed routes, firewall profile states;
   - a full firewall export;
   - an untouched copy of `state.json` as `state-at-setup.json`, next to the firewall export in a `backup-*` folder.

   Every save of `state.json` writes a temporary file and swaps it in, keeping the previous version as `state.json.previous`. If the swap fails, `state.json` is guaranteed to still exist.
3. Create the firewall rules and check that they are in effect:
   - for all Wired interfaces, all profiles, all protocols and ports;
   - IPv4 destinations outside 192.168 blocked, all IPv6 blocked;
   - the hotspot subnet additionally blocked when it lies inside 192.168;
   - the limited broadcast address (255.255.255.255) left open for DHCP on the wired side;
   - the firewall switched on.
4. Change routes and DNS:
   - Wi-Fi IPv4 metric 10, wired 500, plus IgnoreDefaultRoutes on the wired adapter;
   - a 192.168/16 route through the office gateway; routes recorded in the backup that lead outside the LAN through the gateway are removed;
   - the wired DNS switched to the current Wi-Fi DNS.
5. Deploy the guard into the protected ProgramData folder and create a boot task running as SYSTEM. The adapter is found by GUID; its interface index is read again on every pass.

Compatibility with an earlier version:

- The earlier rule group `CodexStrictSplit20261016` has only 3 outbound rules and applies to a single adapter alias. The current version uses `WifiPublicWiredLAN-v2`, with outbound and inbound rules for all Wired interfaces. Their scope differs, so review them separately.
- The status check recognises the earlier group and marks the firewall check as "仅限" (only) that adapter. If another wired adapter connects, the verdict becomes "'adapter name' can reach the Internet" or "has no firewall protection". Restore removes both groups.

## Route guard

GetIpForwardTable2 reads the IPv4 routes, NotifyRouteChange2 wakes the guard, and DeleteIpForwardEntry2 removes prefix-length-0 routes on the configured wired adapter. A fallback scan also runs every 500 ms.

- **Single instance**: a file lock on `guard.lock` in the protected data folder. A global mutex is not used, because any user could create a mutex with that name first and make the guard exit at start. Only a sharing violation counts as "another guard is running", and it is retried for 5 seconds; any other error exits with a non-zero code.
- **Errors do not end it**: each pass catches its own exceptions. A failed route-table read or an adapter temporarily without IPv4 is logged and retried on the next pass. If route notifications cannot be registered, the 500 ms scan carries on alone.
- **Heartbeat**: written only after a pass that worked. A guard that keeps failing shows as "not running", and 修复路由看守 (Repair route guard) restarts it.
- **Log**: the same error is written at most once a minute, with a count of what was skipped; route-removal entries at most once every 10 seconds. Above 1 MB the log is renamed to `route-guard.old.log`.

Order when updating or repairing the guard:

1. With the old guard still running, copy the new program and verify its hash.
2. Stop the old process; the boot task stays registered.
3. Swap in the new program. If the swap fails, put the old program back and start it again.
4. Start the task. Only a heartbeat written after this point counts as a successful start; one left by the stopped guard does not.
5. If the task shows as running but the heartbeat is stale, first end the process at the same path, since it may still hold `guard.lock`.

The task is re-registered only if it runs a different program or watches a different adapter.

On the author's machine, IgnoreDefaultRoutes alone does not stop a lease renewal from adding a default route back. DontAddDefaultGateway was tried, did not work, and was removed. The guard is not a synchronous filter driver, so it cannot guarantee that a wired default route never appears even for a moment. During boot and event-handling delays, the persistent firewall does the protecting.

## Checks and restore

The backend's Status mode is read-only: it reads the system's network configuration and writes a result file, changes nothing and captures no traffic. What the window does before each check is described under "Call chain": keep the data folder protected, refresh the `app` copy, and delete result files older than 10 minutes. None of that touches network settings.

Enable, repair, renew and restore run one at a time: the backend holds `operation.lock` in the data folder until its process ends. Meanwhile a status check reports "另一项操作正在进行" (another operation is in progress), and the window offers no action buttons.

A check result has one verdict (level, title, reason, suggested action) and a list of checks:

- firewall blocking: the actual outbound rules' addresses, protocols, ports, programs, app packages, services, users and interface scope, and whether every firewall profile is on;
- the number of default routes on the cable;
- the route guard: task and heartbeat;
- whether the running guard matches this version;
- whether other wired adapters are covered by the block and whether they have a default route;
- interfaces outside the tool's control, such as Tailscale;
- data folder permissions;
- whether the backup state is complete. Rules or the guard task without `state.json` is an error, and 启用分流 (Enable split) is not offered, so already-changed settings are never backed up as the "original".

修复路由看守 (Repair route guard) is offered only when every problem is a guard problem. For missing firewall rules, a changed hotspot subnet or an unprotected second adapter, the window explains the cause and the next step (usually restore, then enable again) instead of pretending it can fix it. For a second adapter it offers 打开网络连接 (Open Network Connections).

Repair restores the guard only when firewall coverage is complete; it is not a full configuration repair. Renew renews only the selected wired adapter, without a release, and never touches Wi-Fi.

Restore order:

1. Verify the Windows MachineGuid and both adapter GUIDs.
2. Stop the guard that belongs to this tool.
3. Restore the parameters from the backup.
4. Delete this tool's rule groups, including the earlier one it took over.

The GUI restore does not import the full old firewall, so later unrelated changes are not overwritten; the full export is for emergencies. Both the window and `Restore.cmd` ask for confirmation before restoring.

## What not to claim

Controlling by destination IP and adapter covers HTTP, sockets and other traffic on the normal Windows network stack, regardless of URL or port, but it does not know an application's real business endpoint. An allowed proxy on the LAN can still relay the Internet for you. The tool handles no proxies and does not manage VPNs or tunnels such as Tailscale, so it cannot claim that every possible path out of the machine is isolated.

On the author's machine, no wired Internet packets were observed while Wi-Fi was disconnected. That is not a mathematical proof for every moment. Not yet covered:

- a first install on another machine;
- a real restore;
- a capture of the whole boot process.

A fixed hotspot DNS, a saved hotspot subnet and the office gateway all need another review when the environment changes. Do not move one machine's state to another.

Known trade-offs:

- With the wired DNS switched to the hotspot's DNS, office DNS names may not resolve; reach office services by IP.
- Only the IPv4 metric and DNS of the cable are changed. Wired IPv6 is fully blocked by the firewall, so lookups may slow down if the office network hands out IPv6.
- The current rules apply to all Wired interfaces and may also affect Hyper-V/WSL/Docker virtual adapters (not verified).

There is also a window before deployment: before the first enable there is no firewall from this tool, and plugging in the office cable can by itself create an Internet path. On a new machine, avoid plugging in and installing for the first time while sensitive work is running.
