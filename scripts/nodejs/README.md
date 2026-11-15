# TCPViewer Release Utility

This directory keeps the interactive compatibility entrypoint for release builds.
It delegates to `../release.mjs`, which owns the TCPViewer Beta and Production
release workflow.

## Usage

```sh
npm start
npm start -- --type=beta
npm start -- --type=production
npm start -- --type=homebrew
npm start -- --homebrew-only
```

From the repository root, `make beta`, `make production` and `make homebrew` run the same commands.

## Production release

`make production` runs in a terminal and never with `--yes`:

1. **Pre-flight.** Checks everything before it asks anything: `.env` values, Release build settings,
   the bundled Wireshark runtime, Xcode and the release tools, free disk space, the Developer ID
   identity (with a test signature), the notarization credentials, the Sparkle key against the
   app's `SUPublicEDKey`, the Sentry token, the R2 credentials, and that the default branch is
   clean and in sync with origin. It lists every failed check, then stops before changing anything.
2. **Version.** Asks the version and build number. The defaults are the next release: the next
   minor version and build number after the latest GitHub release, or the project's own when they
   were already raised. It asks again until the tag, GitHub release, R2 object and (when enabled)
   backend release are all free.
3. **Release notes.** Drafts short, plain notes from the app changes on the default branch since
   the last release tag. Claude Code (`claude`) rewrites the commit titles without tools, MCP
   servers or repository context; without it, the draft lists the commit titles to rewrite. The
   draft is kept at `~/Desktop/tcpviewer-production/release-notes/<version>.md` until it's released.
   Answer `c` to edit it in VS Code, `YES` to continue, or `n` to cancel.
4. **Commit.** After `YES`, it writes the version and build number to the app target, adds the notes
   to `ReleaseNote.json`, commits `Bump <version>`, pushes it, and checks the release target again.
5. **Build and publish.** Without asking again, it builds, notarizes and verifies the DMG, uploads
   dSYMs to Sentry and the DMG to R2, then publishes the appcast (when the backend is enabled), the
   tag, and the GitHub release.

A production release doesn't open a Homebrew Cask pull request. Run `make homebrew` after it is published.

If a release stops after its version commit, run `make production` again: it suggests the same
version and reuses the draft notes, and commits nothing new.

`--homebrew-only` creates a Homebrew Cask pull request for the production build
in the latest public GitHub release. It does not rebuild or republish the app.

All real signing, notarization, Sentry, and R2 values must stay in the
ignored root `.env` file or the shell environment. Use `.env.example` for safe
placeholder names only. The release output never prints them, and Claude Code and
VS Code run without them in their environment.
