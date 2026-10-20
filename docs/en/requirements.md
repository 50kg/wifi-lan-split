# Requirements

[简体中文](../../需求说明.md) | **English**

## Goal

A small Windows 10/11 x64 tool that lets one computer use a phone-hotspot Wi-Fi and an office Ethernet cable at the same time, with a split that can be checked and restored.

1. Internet traffic must go through Wi-Fi, for every application and protocol on the normal Windows network stack: HTTP/HTTPS, WebSocket, TCP/UDP sockets, QUIC and DNS. No domain, URL or port lists.
2. The wired side may reach only `192.168.0.0/16`, with no extra application or port limits; the hotspot's own subnet always stays on Wi-Fi. The wired adapter keeps getting its address from DHCP.
3. When Wi-Fi drops or has no Internet route, the cable must not take over Internet access. A persistent firewall does the blocking; a guard removes the wired IPv4 default route that DHCP adds back.
4. Never disconnect, disable or reconfigure the Wi-Fi connection; renewal applies to the cable only.
5. Back up before any change and provide an offline restore on the same machine. The Windows installation ID and adapter GUIDs prevent restoring onto another machine; interface indexes, which can change, are not relied on.
6. A native Chinese interface: status check, enable, check and repair the guard, renew and verify the cable, restore, open backups and help.
7. The guard starts with the system and keeps working after the window closes. A post-reboot check must not take a check of the current boot as reboot verification, and must never reboot on the user's behalf.

## Explicit boundaries

- No handling of proxy forwarding on the LAN, and no management of VPNs or tunnels such as Tailscale. An allowed 192.168 server can relay traffic itself; the tool must not claim to prevent that indirect Internet access.
- "All ports on the LAN" means the tool adds no port limits. It does not mean Windows' existing inbound rules are disabled, nor that every LAN service is reachable.
- Necessary LAN control traffic such as ARP and DHCP is allowed, including DHCP's `255.255.255.255` limited broadcast.
- A DHCP default route may appear briefly and the guard removes it asynchronously. The guard must not be described as preventing it from ever existing; the firewall covers that window.
- VM bridging, WSL/containers, other VPNs, kernel drivers, and rules rewritten by administrators or group policy need separate verification.
- A first setup on another computer requires exactly one connected physical Wi-Fi and one connected physical Ethernet adapter, non-overlapping subnets and a valid gateway. On anomalies such as extra active adapters it stops instead of guessing.

## Acceptance

- With Wi-Fi connected, representative Internet route choices and connection source addresses point to Wi-Fi; the cable reaches the required 192.168 services normally.
- After a wired DHCP renewal, the guard clears the wired default route and Wi-Fi stays connected.
- Before any authorised Wi-Fi disconnect test, an independent automatic recovery must be scheduled. Verify that the cable carries no public IPv4/IPv6 or hotspot-subnet traffic.
- Capture statistics must check both packet and byte counts sent; an empty file alone is not proof of no leak. Report configuration checks and capture results separately.
- Reboot acceptance confirms, for the current boot, the guard task, process, heartbeat, wired default-route count and Internet exit; if any is missing, report it as not done.
- Restore tests cover changed adapter indexes, the original DNS/metrics/routes, rule removal and refusal on another machine. A simulation passing does not replace a real test on a second computer.
