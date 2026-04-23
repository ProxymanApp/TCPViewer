# v1.0.3 Release Engineering

## Summary
Define signing, notarization, crash diagnostics, support bundles, and migration behavior for a safe and trustworthy macOS release.

## What To Build
- Specify release packaging, signing, and notarization requirements.
- Define support-bundle content and crash-diagnostic expectations.
- Cover settings, profile, and workspace migration behavior for upgrades.

## Requirements
- Release builds must be trustworthy and installable on supported macOS versions.
- Support bundles must help diagnose field issues without exposing unnecessary user data.
- Upgrade paths must preserve analyst settings safely.

## Dependencies
- v0.8.1 profiles and saved workspaces.
- v1.0.1 stability sweep.

## Tests
- Unit tests: cover migration logic and support-bundle manifest generation where model-driven.
- Integration tests: cover upgrade installs, profile migration, and release-build packaging verification.
- UI tests: out of scope.

## Out Of Scope
- App Store distribution strategy.
- New feature development.
