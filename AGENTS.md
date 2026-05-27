
### Requirement
- Keep the code simple, testable, and don't create too many abstraction
- Follow best coding practice
- This repo is open source; treat every committed file, fixture, log, and config as public.
- Never generate, synthesize, or restore the top-level `Fixtures/` directory or packet capture fixtures. If tests require missing fixtures, report the missing official fixture data instead.
- Never store or commit secrets, credentials, tokens, API keys, private certificates, signing identities, personal data, or machine-specific sensitive paths.
- Keep secrets in local environment variables, ignored local config files, or the platform keychain; document required values with safe placeholders only.
- Before committing, review changes for accidental secrets, sensitive packet captures, debug logs, or generated artifacts that could expose private data.
- Follow OSS security hygiene: validate untrusted input, avoid unsafe defaults, keep dependencies minimal and justified, and prefer secure-by-default behavior.
- Avoid duplication code
- Core logic should be carefully tested by Unit Test or Integration Test
- Don't write UI Tests
- Add the standard header to Swift and Objective-C source files with the correct filename, `TCPViewer` project name, and `Created by Proxyman LLC on <file created date>.`
- If the logic is complicated and hard to understand, explain why you do it
- Make sure to build the project if you change code, to verify all syntax are correct and works
- Run Unit Tests that you've made a change or created or entire test suit if it's possible
- For tiny change, no need to run project, because it can slows the development process
- TCP Viewer is the main macOS app; do not reintroduce the deleted TCPViewer SwiftUI app or TCPViewerTests target
- TCPViewer main window and inspector must be 100% AppKit: NSViewController, NSSplitViewController/NSSplitView, NSTableView, NSScrollView, NSStackView, NSToolbar, NSSegmentedControl
- SwiftUI is allowed only for helper onboarding and settings views through NSHostingController
- TCPViewer and PcapPlusPlusCore production code must not use Task, async/await, actors, Combine, Publisher, ObservableObject, @Published, or SwiftUI bindings
- Use dedicated DispatchQueue instances for background work in TCPViewer/core, and manually return results through callbacks
- Use simple weak delegate protocols for view-model/controller signals; child controllers receive explicit render models and call delegate methods for user actions
- Keep TCPViewer view models controller-specific and testable; do not add broad global state or automatic observation
- Keep PcapPlusPlusCore public APIs callback-based unless a future ticket explicitly changes this architecture
- After TCPViewer or core changes, verify with `xcodebuild -project TCPViewer.xcodeproj -scheme TCPViewer build`
- Run `xcodebuild test -project TCPViewer.xcodeproj -scheme TCPViewer -destination 'platform=macOS'` and relevant `PcapPlusPlusCore` tests when app/core behavior changes
- Try adding 1 line and concise short comment to explain a group of logic if the func is big
- Add 1 line concise comment to explain a func in the top of func

### AI-written Pull Requests
- AI-written or AI-assisted pull requests are welcome only when the contributor fully reviews, tests, and takes responsibility for the change.
- Clearly disclose when a pull request was written or substantially assisted by AI.
- Keep AI-generated changes small, focused, easy to review, and aligned with the existing architecture and coding style.
- Do not submit broad rewrites, speculative refactors, or unrelated cleanup just because an AI suggested them.
- The project author may freely reject any AI-written pull request, even if it is technically correct or reasonable to merge, to preserve the project's direction, taste, maintainability, and long-term goals.
