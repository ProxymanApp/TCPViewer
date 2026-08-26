# Homebrew Cask release setup

The production release can create the initial TCP Viewer cask or update the existing cask.

The Homebrew-only command submits the latest public production release:

```bash
npm run release:homebrew
```

It downloads the public production DMG and checks its size and SHA-256 against the
matching GitHub release asset before changing the cask repository. It does not build,
upload, tag, or republish TCP Viewer.

You can also run `make build` and choose `Homebrew Cask PR from latest release`.
The script shows the release and pull request branches, then asks for confirmation
before it fetches or changes the Homebrew checkout.

The pull request body starts from the current template in upstream `origin/main`.
The script keeps its checklist text intact, marks completed actions, and adds the
repository metrics and AI/LLM disclosure before creating the pull request.

## One-time setup

```bash
brew tap --force homebrew/cask
cd "$(brew --repository homebrew/cask)"
git remote add proxyman git@github.com:ProxymanApp/homebrew-cask.git
```

Set `TCPVIEWER_HOMEBREW_CASK_REPO` in the local `.env` file to the path printed by:

```bash
brew --repository homebrew/cask
```

The release always creates its cask branch from current `origin/main`. It pushes only that branch to the `proxyman` fork remote, so a stale fork default branch cannot enter the pull request. GitHub hosts the pull request in `Homebrew/homebrew-cask`, with `ProxymanApp:<branch>` as its source.

## Initial cask

The initial cask uses `tcpviewer.rb` in this directory. The release fills in its version, build number, and SHA-256.

The release runs these maintained Homebrew checks:

- `brew style --fix --cask tcpviewer`
- `brew audit --cask --online --new tcpviewer`
- `brew livecheck --cask --autobump tcpviewer`
- `brew lgtm --online`

Before the initial pull request is created, the interactive release pauses for the required install and uninstall checks:

```bash
HOMEBREW_NO_INSTALL_FROM_API=1 brew install --cask tcpviewer
brew uninstall --cask tcpviewer
```

For a non-interactive release, add `--homebrew-install-tested` only after both commands have passed.

Review Homebrew's current [cask acceptance](https://docs.brew.sh/Acceptable-Casks) and [package acceptance](https://docs.brew.sh/Package-Acceptance-Policy) policies before submitting the initial cask. Homebrew maintainers make the final acceptance decision.

## Release flags

- `--bump-homebrew` creates the cask pull request.
- `--no-bump-homebrew` skips Homebrew.
- `--yes` skips Homebrew unless `--bump-homebrew` is also present.
- `--homebrew-install-tested` confirms the initial install and uninstall checks already passed.
- `--homebrew-only` submits the latest public production release without publishing it again.

After Homebrew merges the initial cask, users can install the app with:

```bash
brew install --cask tcpviewer
```
