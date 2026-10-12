# HazloSimple Office disposable QA

Manual-only, standard public GitHub-hosted disposable Windows Server 2022 and macOS 15 runners. Only public pinned installer/activator sources are used; no private customer packages, customer codes, Microsoft accounts or production credentials are uploaded.

## Results, 2026-10-12

- Exact packaged MAS AIO and standalone Ohook executed with /Ohook for both Office LTSC 2024 and Microsoft 365 desktop: four successful exit-0 executions, expected hook installed, Word/Excel/PowerPoint remained running afterward.
- Exact Microsoft-signed VL Serializer executed on macOS 15.7.9 ARM64: installation succeeded, new nonempty syntactically valid licensingV2 plist and package receipts found, three Office apps restarted afterward. License contents were not logged.
- Windows document editing automation did not pass: all four attempts timed out after four minutes. The overall Windows run is failed for this reason, despite successful installation and activator steps. Document editing and visible in-app Mac activation remain unverified.
- Native runner Defender baseline was AntivirusEnabled=True and RealTimeProtectionEnabled=False before/after; no endpoint-protection settings were changed. Windows 11 with active realtime Defender was not tested.

[Windows execution and editing-timeout evidence](https://github.com/eduarditoramos/hazlosimple-office-qa/actions/runs/38304047360)

[Successful macOS Serializer job](https://github.com/eduarditoramos/hazlosimple-office-qa/actions/runs/38303057727/job/114990407015)

[Earlier official installation/startup tests](https://github.com/eduarditoramos/hazlosimple-office-qa/actions/runs/38300525368)

Activator success and generated license files do not establish Microsoft license entitlement, resale rights or a Microsoft 365 subscription. No EULA acceptance flag is enabled and no customer code is supplied. Tests retain no document/license artifacts. The workflow offers all/windows/mac selection and never runs automatically on push.
