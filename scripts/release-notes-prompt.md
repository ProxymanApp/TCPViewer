You're writing the release notes for TCP Viewer {{version}}, a free macOS app that captures and inspects network
traffic (TCP, UDP, TLS, HTTP, DNS) with a Wireshark-powered packet inspector, and lets AI agents use it through MCP and
a command-line tool. People read these notes in the app's update window and on GitHub. They use the app, but they
have never seen its code.

Below are the changes merged since the last release: for each one, its title and the description its developer
wrote. Both are written by developers, for developers. Turn them into short release notes for the people who use the
app.

How to write them:

- Say what changed for the reader: what they can do now, what works better, what no longer goes wrong. Not how it
  was built.
- Use simple, everyday words. Leave out the code's names: classes, functions, files, frameworks, preferences keys,
  and numbers that only matter inside the app (epan, NSTableView, tls.keylog_file). Name only what people see or
  type: a button, a menu, a window, a panel, a command they run. Describe an MCP tool by what agents can now do with
  it, not by its name.
- One short sentence per line, about 15 words at most.
- Keep it short enough to take in at a glance: 8 lines at most in total, however many changes there are. Put related
  changes on one line. Leave out what people won't notice: clean-ups, tests, refactors, build and release scripts.
- Only say what the changes say. Don't guess at reasons, numbers or features.
- Put each line in one section: Features (something new people can do), Improvements (something that works better),
  Bug Fixes (something that no longer goes wrong). Start each bug fix with "Fixed: ". Leave a section without lines
  when nothing belongs in it.

Give the release a title too: what it brings, in 2 to 6 plain words, 50 characters at most, so people see at a glance
what this version is about. Title Case, no version number, no "TCP Viewer", no period at the end. A release of small
fixes only: "Bug Fixes and Improvements".

For example, these developer titles:

    Add TLS decryption with key log files and HTTP Preview
    Keep TCP reassembly when inspecting after Wireshark ownership changes
    Release packet storage after clearing

become:

    # TCP Viewer 1.26.0: TLS Decryption and HTTP Preview

    ## Features
    - Decrypt HTTPS traffic with a TLS key log file, and preview HTTP requests and responses.

    ## Improvements
    - Clearing a capture frees its memory right away.

    ## Bug Fixes
    - Fixed: Packet details could lose reassembled TCP data.

Answer with the notes only, in exactly this Markdown format, with nothing before or after it:

# TCP Viewer {{version}}: <title>

## Features
- <line>

## Improvements
- <line>

## Bug Fixes
- Fixed: <line>
