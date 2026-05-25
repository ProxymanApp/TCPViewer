# TCPViewer Release Utility

This directory keeps the interactive compatibility entrypoint for release builds.
It delegates to `../release.mjs`, which owns the TCPViewer Beta and Production
release workflow.

## Usage

```sh
npm start
npm start -- --type=beta
npm start -- --type=production
```

All real signing, notarization, Sentry, and R2 values must stay in the
ignored root `.env` file or the shell environment. Use `.env.example` for safe
placeholder names only.
