import assert from "node:assert/strict";
import { test } from "node:test";
import {
  emptyReleaseNotesDraft,
  extractReleaseNotesAnswer,
  fallbackReleaseNotesDraft,
  gitChangesLogFormat,
  makeReleaseNotesRequest,
  parseGitChanges,
  parseReleaseNotesMarkdown,
  releaseNoteToDraftMarkdown,
  shippedChanges,
  upsertReleaseNote
} from "../scripts/release-notes.mjs";

function gitLogRecord({ hash, subject, body = "", files }) {
  return `\x1e${hash}\x1f${subject}\x1f${body}\x1f\n\n${files.join("\n")}\n`;
}

test("reads git log records with their changed files", () => {
  assert.equal(gitChangesLogFormat, "%x1e%H%x1f%s%x1f%b%x1f");
  const commits = parseGitChanges([
    gitLogRecord({ hash: "a1", subject: "Hide the banner (#148)", body: "Line one\n", files: ["TCPViewer/A.swift"] }),
    gitLogRecord({ hash: "b2", subject: "Update Fastfile", files: ["fastlane/Fastfile"] })
  ].join(""));

  assert.deepEqual(commits, [
    { hash: "a1", subject: "Hide the banner (#148)", body: "Line one", files: ["TCPViewer/A.swift"] },
    { hash: "b2", subject: "Update Fastfile", body: "", files: ["fastlane/Fastfile"] }
  ]);
});

test("keeps only changes that ship in the app, without PR numbers, trailers or duplicates", () => {
  const changes = shippedChanges([
    {
      subject: "Add TLS decryption (#147)",
      body: "Decrypt HTTPS.\n\n\n- Add a menu.\n---\nCo-Authored-By: Someone <someone@example.com>",
      files: ["TCPViewer/TLS.swift", "tests/tls.test.mjs"]
    },
    { subject: "Bump 1.26.0", body: "", files: ["ReleaseNote.json", "TCPViewer.xcodeproj/project.pbxproj"] },
    { subject: "Update Fastfile", body: "", files: ["fastlane/Fastfile"] },
    { subject: "Add TLS decryption (#150)", body: "", files: ["PcapPlusPlusCore/Core.cpp"] },
    { subject: "Patch Wireshark", body: "", files: ["scripts/patches/wireshark.patch"] }
  ]);

  assert.deepEqual(changes, [
    { title: "Add TLS decryption", details: "Decrypt HTTPS.\n\n- Add a menu." },
    { title: "Patch Wireshark", details: "" }
  ]);
});

test("builds the notes writer request from the prompt and changes", () => {
  const request = makeReleaseNotesRequest({
    prompt: "Write notes for TCP Viewer {{version}}.\n",
    version: "1.27.0",
    changes: [{ title: "Hide the banner", details: "It no longer shows." }, { title: "Faster table", details: "" }]
  });

  assert.equal(request, [
    "Write notes for TCP Viewer 1.27.0.",
    "",
    "The changes in TCP Viewer 1.27.0, newest first:",
    "",
    "## Hide the banner",
    "",
    "It no longer shows.",
    "",
    "## Faster table",
    ""
  ].join("\n"));
});

test("takes the notes from the writer's answer", () => {
  const answer = "Here are the notes:\n\n```markdown\n# TCP Viewer 1.27.0: Cleaner Inspector\n\n## Improvements\n- Less noise.\n```\n";
  assert.equal(extractReleaseNotesAnswer(answer), "# TCP Viewer 1.27.0: Cleaner Inspector\n\n## Improvements\n- Less noise.\n");
  assert.equal(extractReleaseNotesAnswer("I can't help with that."), null);
});

test("parses reviewed Markdown notes into a ReleaseNote.json entry", () => {
  const release = parseReleaseNotesMarkdown([
    "<!-- Kept from an earlier run -->",
    "# TCP Viewer 1.27.0: Cleaner TLS Inspector",
    "",
    "## Features",
    "- Search packets by app name.",
    "",
    "## Improvements",
    "* The inspector no longer shows the encrypted traffic banner.",
    "",
    "## Bug Fixes",
    ""
  ].join("\n"), "1.27.0");

  assert.deepEqual(release, {
    version: "1.27.0",
    title: "TCP Viewer 1.27.0: Cleaner TLS Inspector",
    features: ["Search packets by app name."],
    improvements: ["The inspector no longer shows the encrypted traffic banner."],
    bugs: []
  });
});

test("rejects notes the release can't publish as they are", () => {
  const notes = (heading, body = "## Improvements\n- Faster.") => `${heading}\n\n${body}\n`;

  assert.throws(() => parseReleaseNotesMarkdown(notes("TCP Viewer 1.27.0: Faster"), "1.27.0"), /must start with the heading/);
  assert.throws(() => parseReleaseNotesMarkdown(notes("# TCP Viewer 1.26.0: Faster"), "1.27.0"), /names version 1\.26\.0/);
  assert.throws(() => parseReleaseNotesMarkdown(notes("# TCP Viewer 1.27.0:"), "1.27.0"), /Give the release a title/);
  assert.throws(() => parseReleaseNotesMarkdown(notes("# TCP Viewer 1.27.0: Faster."), "1.27.0"), /ends with "\."/);
  assert.throws(
    () => parseReleaseNotesMarkdown(notes(`# TCP Viewer 1.27.0: ${"Long ".repeat(11)}Title`), "1.27.0"),
    /longer than 50/
  );
  assert.throws(() => parseReleaseNotesMarkdown(notes("# TCP Viewer 1.27.0: Faster", "## Misc\n- Faster."), "1.27.0"), /unknown section "Misc"/);
  assert.throws(() => parseReleaseNotesMarkdown(notes("# TCP Viewer 1.27.0: Faster", "Faster."), "1.27.0"), /Line 3 must be/);
  assert.throws(() => parseReleaseNotesMarkdown(notes("# TCP Viewer 1.27.0: Faster", "## Features"), "1.27.0"), /at least one/);
  assert.throws(() => parseReleaseNotesMarkdown(notes("# TCP Viewer 1.27.0: Maintenance Build"), "1.27.0"), /too generic/);
});

test("marks drafts made from raw commit titles until someone rewrites them", () => {
  const draft = fallbackReleaseNotesDraft("1.27.0", [
    { title: "Add packet search", details: "" },
    { title: "Fix crash when closing a capture", details: "" },
    { title: "Hide the banner", details: "" }
  ]);

  assert.match(draft, /^<!-- DRAFT/);
  assert.match(draft, /## Features\n- Add packet search/);
  assert.match(draft, /## Improvements\n- Hide the banner/);
  assert.match(draft, /## Bug Fixes\n- Fixed: crash when closing a capture/);
  assert.throws(() => parseReleaseNotesMarkdown(draft, "1.27.0"), /still a draft/);
  assert.equal(
    parseReleaseNotesMarkdown(emptyReleaseNotesDraft("1.27.0"), "1.27.0").title,
    "TCP Viewer 1.27.0: Bug Fixes and Improvements"
  );
});

test("round-trips a ReleaseNote.json entry through the editable draft", () => {
  const release = {
    version: "1.26.0",
    title: "TCP Viewer 1.26.0: TLS Decryption and HTTP Preview",
    features: ["Add TLS decryption with key log files and HTTP Preview feature"],
    improvements: [],
    bugs: ["Fixed: Few crashes in Sentry"]
  };

  assert.deepEqual(parseReleaseNotesMarkdown(releaseNoteToDraftMarkdown(release), "1.26.0"), release);
  assert.match(
    releaseNoteToDraftMarkdown({ ...release, title: "TCP Viewer 1.26.0 TLS Decryption" }),
    /^# TCP Viewer 1\.26\.0: TLS Decryption\n/
  );
});

test("adds a release to ReleaseNote.json or replaces the same version's entry", () => {
  const content = JSON.stringify({
    releases: [{ version: "1.26.0", title: "TCP Viewer 1.26.0: TLS", features: [], improvements: ["A"], bugs: [] }]
  });
  const release = { version: "1.27.0", title: "TCP Viewer 1.27.0: Search", features: ["B"], improvements: [], bugs: [] };

  const added = JSON.parse(upsertReleaseNote(content, release));
  assert.deepEqual(added.releases.map((entry) => entry.version), ["1.26.0", "1.27.0"]);

  const replaced = JSON.parse(upsertReleaseNote(JSON.stringify(added), { ...release, features: ["C"] }));
  assert.deepEqual(replaced.releases.map((entry) => entry.version), ["1.26.0", "1.27.0"]);
  assert.deepEqual(replaced.releases[1].features, ["C"]);
  assert.ok(upsertReleaseNote(content, release).endsWith("}\n"));
});
