# Contributing

Thank you for considering a contribution to KADO Desk, maintained by Links Tam.

Use Issues for reproducible bugs or focused feature suggestions. Include the app version, OS, steps, expected/actual behavior and a screenshot made with synthetic content. State whether an issue affects an installed app or a source build. Do not attach a personal database, unredacted log, API key, SSH config or private files.

Keep changes focused and preserve stable IDs, Schema 3 migration compatibility and existing user data. Discuss any destructive behavior or schema change before implementation. Match Dart formatting/analysis rules, maintain Material 3/Flame conventions, and keep strings readable in narrow layouts. Avoid adding a new UI framework for a small control.

Run relevant tests, `flutter analyze`, then the complete fixture-prepared suite for a milestone. Test cancellation/error paths when changing jobs, IO or networking. For platform work, distinguish source compilation from real device verification. Explain validation and remaining limits in the change description.

Contributions must be your work or correctly licensed. Keep third-party copyright/license notices and update the dependency/asset inventory. Do not add commercial sprites, model weights or external executable bundles without review. Project code is MIT; independently licensed assets remain under their own terms. No contributor agreement or rights transfer is implied.

Security issues follow [SECURITY.md](SECURITY.md), not a public issue containing an exploit credential. Public repository access and normal web contribution features are managed by the owner; this package does not create accounts or submit changes for you.
