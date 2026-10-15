# Changelog

## 0.1.0 — 2026-10-15

First public preview of VMnet8 Sync for Windows and VMware Workstation.

- Double-click install, uninstall and status commands; automatic UAC elevation for setup.
- Windows event-triggered synchronization, with no product service, boot/logon trigger or timer.
- NAT/DHCP configuration validation, adapter identity checks and bounded retries.
- Targeted DHCP renewal, with one optional fallback restart of the shared VMware DHCP service.
- Repeat installation and upgrade with rollback; keep previous auditing rules and diagnostic data.
- Source and Windows release ZIPs, SHA-256 checksums and GitHub Actions validation.

Installation and event-rule registration were verified on Windows with Workstation 17.6.3.
Real cross-subnet repair and the full VMware event sequence still require broader validation.
