# Verification record and open items

[简体中文](../验证记录.md) | **English**

All verification below was done on the author's own machine: Windows 10, a phone hotspot over Wi-Fi plus an office LAN cable. Raw captures and logs contain internal network details and are not published.

## Disconnect and renewal tests (2026-10-19)

- **In-memory capture while disconnecting Wi-Fi**:
  - wired transmit: 4 packets / 239 bytes with Wi-Fi online, 106 packets / 10708 bytes with Wi-Fi off;
  - wired receive: 28 packets / 3819 bytes and 219 packets / 166026 bytes;
  - counters, raw XML and an independently parsed pcap agree on frame and byte counts.
- **Wired transmit with Wi-Fi off, by type**: ARP 4, UDP broadcast 3, ICMP to the LAN gateway 1, TCP to LAN servers 98. No public IPv4, IPv6 or hotspot-subnet packets were observed. Public HTTP/HTTPS/TCP/UDP/ICMP/IPv6 probes all failed, and the WFP log records a TCP connection bound to the wired adapter as blocked.
- An independent Wi-Fi auto-recovery was scheduled before the disconnect test. After recovery HTTPS returned 200, and the temporary task was removed.
- With the route guard in place, three real wired DHCP renewals were done, one of them through the tool's backend. Each time the wired default-route count was 0 afterwards, and the guard log recorded the removal; Wi-Fi stayed connected and HTTPS kept working.
- **One-time post-reboot check**:
  - the pre-check (run as SYSTEM) passed: HTTPS source address on Wi-Fi, remote 1.1.1.1;
  - after a real reboot, the audit task wrote its formal report about one minute after boot, with result PASS;
  - this is a configuration and representative-connection check, not a capture of the whole boot.

In disk/ring capture mode the counters and the frames written to disk disagreed: some packets were never written to the raw record. So an empty record from that run is not evidence of "no traffic". The same controlled experiment in memory mode matched counters and frames, and every formal disconnect test after that used memory mode. The split rules were not changed to work around the capture problem.

## After code review and fixes (2026-10-19 to 10-20)

- `tests/Run-Tests.ps1` passes, covering:
  - syntax and encoding checks;
  - the build;
  - isolated simulations of restore, enable, status (17 scenarios) and guard update/repair (6 scenarios);
  - the window's file-integrity check;
  - a layout check of every window state and confirmation dialog at 100%–175% scaling, on the real screen and on a simulated 1024×768 screen, with no clipped text, overflow or overlap.

  In the tests, every network and scheduled-task command is replaced by a stub that throws, and `netsh`/`ipconfig` called by full path are blocked too. A test fails immediately if its paths point outside its temp folder.
- The window had two rounds of independent review, followed by an independent code review. Everything the code review found was fixed:
  - a failed guard update could leave no guard;
  - operations were not mutually exclusive;
  - closing the window could interrupt the backend;
  - the heartbeat did not prove the guard was working;
  - the lock file was misjudged;
  - file ownership;
  - firewall filters that were not checked;
  - a missing `state.json` was taken as "not enabled".
- The new backend's status check ran read-only on the author's machine. The verdict was "split in effect", with the earlier rule group correctly recognised as "only" one adapter, 0 wired default routes and the guard running. A before/after comparison of the data folder showed only the guard's own heartbeat file had changed.
- GitHub Actions runs the same test suite on every push.

## Get-Acl module load failure (2026-10-22)

- Reported: every check failed with "The 'Get-Acl' command was found in the module 'Microsoft.PowerShell.Security', but the module could not be loaded".
- Possible cause one (reproduced on the author's machine): the module path the backend inherited listed a PowerShell 7 style `Microsoft.PowerShell.Security` ahead of Windows PowerShell's own. Its types file repeats definitions Windows PowerShell already has, so loading it fails with "The member Path is already present". `Join-Path` and `Test-Path` are unaffected, so the first `Get-Acl` in the script is what fails. The backend now loads modules only from the built-in folder, which fixes this case.
- Possible cause two (reproduced on the author's machine): the backend sets `$ErrorActionPreference='Stop'`. Any error during a module import that would otherwise not be fatal then becomes the same message. In this case the real cause is not attached to the error; it is only in `$Error`.
- The reporter's first diagnosis (script version 1):
  - no PowerShell 7, a normal system module path and no look-alike modules;
  - `Get-Acl` worked with both module paths.

  So it does not support cause one. But version 1 ran its child processes without "stop on error", so it also shows "normal" in the cause-two case (confirmed on the author's machine with a stand-in module). It cannot rule out cause two.
- Changes that followed:
  - The backend's failure message names the cause: from the inner exception, or, when there is none, by importing the module once more. If that second import works, it says the problem may be passing.
  - Diagnosis version 2 runs like the backend and records the full exception chain.
  - `tests/Test-ModulePath.ps1` covers all of the above; it fails with exactly this error against the `backend.ps1` from before the fix.
  - Version 2 was run on the author's machine with three module paths (PowerShell 7 look-alike, normal, a non-fatal import error); its conclusions and causes were as expected.
- Not verified: the actual cause on the reporter's machine, and how the fixed version behaves there. This waits for the new version's log and a version 2 diagnosis report.

## Still to verify

- A complete walk-through of the new window's enable, repair, renew and restore flows on a real system.
- Whether the scheduled task's "restart on failure" applies when the program exits with a non-zero code. The new guard no longer exits on a failed pass.
- A first install and a real restore on a second machine.
- Full traffic verification of the whole boot, and with VMs, containers, VPNs, kernel drivers or a LAN proxy.
- How rules that apply to all Wired interfaces affect Hyper-V/WSL/Docker virtual adapters.
- Behaviour on new hardware, other Windows versions, under company group policy, or after the hotspot subnet or office gateway changes.
