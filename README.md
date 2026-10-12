# HazloSimple Office QA

Isolated native macOS and Windows checks using standard GitHub-hosted runners.
Only public Microsoft installer sources are downloaded. No customer data, codes, private packages, production credentials or artifacts are uploaded.

Tests cover native prerequisites, package trust and official Office installation/application process startup in disposable machines.
No Serializer or MAS is executed. No Microsoft account sign-in or automatic EULA acceptance is performed. Process startup does not prove activation, GUI interaction or document editing.

Local private launcher flow tests use generated RSA keys and stub installers, separately from these native vendor-installation checks.
