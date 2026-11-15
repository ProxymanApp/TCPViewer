import { assertReleaseTitleReflectsChanges, parseReleaseNotes } from "./release-lib.mjs";

// Folders whose changes reach people who use the app; scripts, tests, docs and the Xcode project alone don't.
export const shippingPaths = [
  "TCPViewer/",
  "PcapPlusPlusCore/",
  "TCPViewerHelperTool/",
  "TCPViewerCLIShared/",
  "TCPViewerMCPShared/",
  "tcpviewer-cli/",
  "tcpviewer-mcp/",
  "NetworkHelperLaunchDaemons/",
  "Vendor/",
  "scripts/patches/"
];

// The git log format parseGitChanges reads: one record per commit, with the files it changed after it.
export const gitChangesLogFormat = "%x1e%H%x1f%s%x1f%b%x1f";

// Marks a draft made from raw commit titles; the review refuses it until someone rewrites the notes.
export const releaseNotesDraftMarker = "<!-- DRAFT";

export const releaseTitleMaxLength = 50;

const maxChangeDetailLines = 40;
const sectionKeys = new Map([
  ["features", "features"],
  ["improvements", "improvements"],
  ["bug fixes", "bugs"],
  ["bugs", "bugs"],
  ["fixes", "bugs"]
]);

// Parse `git log --name-only --format=<gitChangesLogFormat>` output into commits with their changed files.
export function parseGitChanges(output) {
  return String(output)
    .split("\x1e")
    .filter((record) => record.trim())
    .map((record) => {
      const [hash = "", subject = "", body = "", files = ""] = record.split("\x1f");
      return {
        hash: hash.trim(),
        subject: subject.trim(),
        body: body.trim(),
        files: files.split("\n").map((file) => file.trim()).filter(Boolean)
      };
    });
}

// Keep the commits that changed what ships, newest first, as titles without PR numbers and short descriptions.
export function shippedChanges(commits) {
  const seenTitles = new Set();
  const changes = [];
  for (const commit of commits) {
    const shipsInApp = commit.files.some((file) => shippingPaths.some((prefix) => file.startsWith(prefix)));
    const title = commit.subject.replace(/\s+\(#\d+\)$/, "").trim();
    if (!shipsInApp || !title || seenTitles.has(title)) {
      continue;
    }

    seenTitles.add(title);
    changes.push({ title, details: changeDetails(commit.body) });
  }
  return changes;
}

// Build the request for the notes writer: the prompt, then every change's title and description.
export function makeReleaseNotesRequest({ prompt, version, changes }) {
  const lines = [String(prompt).replaceAll("{{version}}", version).trimEnd(), "", `The changes in TCP Viewer ${version}, newest first:`];
  for (const change of changes) {
    lines.push("", `## ${change.title}`);
    if (change.details) {
      lines.push("", change.details);
    }
  }
  return `${lines.join("\n")}\n`;
}

// Take the notes from the writer's answer: from its first "# " heading, without Markdown code fences.
export function extractReleaseNotesAnswer(answer) {
  const lines = String(answer)
    .replaceAll("\r\n", "\n")
    .split("\n")
    .filter((line) => !/^\s*```/.test(line));
  const headingIndex = lines.findIndex((line) => /^#\s+\S/.test(line.trim()));
  if (headingIndex === -1) {
    return null;
  }

  return `${lines.slice(headingIndex).join("\n").trim()}\n`;
}

// Draft notes from raw commit titles when no writer is available; the marker makes someone rewrite them first.
export function fallbackReleaseNotesDraft(version, changes) {
  const sections = { features: [], improvements: [], bugs: [] };
  for (const { title } of changes) {
    if (/^fix/i.test(title)) {
      sections.bugs.push(`Fixed: ${title.replace(/^fix(es|ed)?\s*:?\s*/i, "")}`);
    } else if (/^(add|introduce|support|new)\b/i.test(title)) {
      sections.features.push(title);
    } else {
      sections.improvements.push(title);
    }
  }

  return [
    `${releaseNotesDraftMarker}: these are the commit titles, written for developers. Rewrite them in plain words,`
      + " give the heading a short title, then delete this line. -->",
    formatReleaseNotesMarkdown({ version, shortTitle: "", ...sections })
  ].join("\n");
}

// Notes for a release without shipped changes since the last one.
export function emptyReleaseNotesDraft(version) {
  return formatReleaseNotesMarkdown({
    version,
    shortTitle: "Bug Fixes and Improvements",
    features: [],
    improvements: ["Bug fixes and improvements."],
    bugs: []
  });
}

// Turn a ReleaseNote.json entry into the editable Markdown draft, keeping its title under the standard heading.
export function releaseNoteToDraftMarkdown(release) {
  const versionPrefix = new RegExp(`^TCP Viewer\\s+v?${escapeRegExp(release.version)}\\s*:?\\s*`, "i");
  const shortTitle = release.title.replace(versionPrefix, "").trim() || release.title;
  return formatReleaseNotesMarkdown({
    version: release.version,
    shortTitle,
    features: release.features,
    improvements: release.improvements,
    bugs: release.bugs
  });
}

// Read the reviewed Markdown notes into a ReleaseNote.json entry, rejecting anything it can't place.
export function parseReleaseNotesMarkdown(text, version) {
  const lines = String(text).replaceAll("\r\n", "\n").split("\n");
  if (lines.some((line) => line.includes(releaseNotesDraftMarker))) {
    throw new Error("The notes are still a draft: rewrite them, then delete the <!-- DRAFT line.");
  }

  const heading = `"# TCP Viewer ${version}: <a few plain words>"`;
  const release = { version, title: "", features: [], improvements: [], bugs: [] };
  let section = null;
  for (const [index, rawLine] of lines.entries()) {
    const line = rawLine.trim();
    if (!line || /^<!--.*-->$/.test(line)) {
      continue;
    }

    if (!release.title) {
      const match = line.match(/^#\s+TCP Viewer\s+(\S+?):\s*(.*)$/);
      if (!match) {
        throw new Error(`The notes must start with the heading ${heading}.`);
      }
      if (match[1] !== version) {
        throw new Error(`The heading names version ${match[1]}, not ${version}.`);
      }
      release.title = `TCP Viewer ${version}: ${validateShortTitle(match[2].trim(), heading)}`;
      continue;
    }

    const sectionHeading = line.match(/^##\s+(.+)$/);
    if (sectionHeading) {
      section = sectionKeys.get(sectionHeading[1].trim().toLowerCase());
      if (!section) {
        throw new Error(`Line ${index + 1}: unknown section "${sectionHeading[1]}". Use Features, Improvements or Bug Fixes.`);
      }
      continue;
    }

    const item = line.match(/^[-*]\s+(.+)$/);
    if (item && section) {
      release[section].push(item[1].trim());
      continue;
    }

    throw new Error(
      `Line ${index + 1} must be a "## Features", "## Improvements" or "## Bug Fixes" heading, `
      + `or a "- " line under one: ${line}`
    );
  }

  if (!release.title) {
    throw new Error(`The notes need the heading ${heading}.`);
  }
  if (!release.features.length && !release.improvements.length && !release.bugs.length) {
    throw new Error('The notes need at least one "- " line.');
  }
  assertReleaseTitleReflectsChanges(release);
  return release;
}

// Add the release to ReleaseNote.json, or replace the entry an earlier run wrote for the same version.
export function upsertReleaseNote(content, release) {
  const releaseNotes = parseReleaseNotes(content);
  const entry = {
    version: release.version,
    title: release.title,
    features: release.features,
    improvements: release.improvements,
    bugs: release.bugs
  };
  const index = releaseNotes.releases.findIndex((candidate) => candidate.version === release.version);
  if (index === -1) {
    releaseNotes.releases.push(entry);
  } else {
    releaseNotes.releases[index] = entry;
  }
  return `${JSON.stringify(releaseNotes, null, 2)}\n`;
}

function validateShortTitle(shortTitle, heading) {
  if (!shortTitle) {
    throw new Error(`Give the release a title in its heading: ${heading}.`);
  }
  if (shortTitle.length > releaseTitleMaxLength) {
    throw new Error(`The title is ${shortTitle.length} characters, longer than ${releaseTitleMaxLength}: ${shortTitle}`);
  }
  if (/[.:]$/.test(shortTitle)) {
    throw new Error(`The title ends with "${shortTitle.slice(-1)}": ${shortTitle}`);
  }
  return shortTitle;
}

function formatReleaseNotesMarkdown({ version, shortTitle, features, improvements, bugs }) {
  const section = (title, entries) => [`## ${title}`, ...entries.map((entry) => `- ${entry}`)].join("\n");
  return [
    `# TCP Viewer ${version}: ${shortTitle}`.trimEnd(),
    section("Features", features),
    section("Improvements", improvements),
    section("Bug Fixes", bugs)
  ].join("\n\n") + "\n";
}

// A change's description for the writer: no trailers or separators, blank lines squeezed, and capped in length.
function changeDetails(body) {
  const lines = [];
  let pendingBlank = false;
  for (const rawLine of String(body).split("\n")) {
    const line = rawLine.trimEnd();
    if (/^\s*(co-authored-by|signed-off-by):/i.test(line) || /^-+\s*$/.test(line) || /Generated with \[?Claude Code/i.test(line)) {
      continue;
    }
    if (!line.trim()) {
      pendingBlank = lines.length > 0;
      continue;
    }
    if (pendingBlank) {
      lines.push("");
      pendingBlank = false;
    }
    lines.push(line);
    if (lines.length >= maxChangeDetailLines) {
      break;
    }
  }
  return lines.join("\n");
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
