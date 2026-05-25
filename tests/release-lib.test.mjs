import assert from "node:assert/strict";
import { test } from "node:test";
import {
  backendCheckURL,
  backendCreateURL,
  findReleaseNote,
  generateAppcastXML,
  makeBetaDMGFileName,
  makeR2ObjectKey,
  mergeEnv,
  missingRequiredEnv,
  normalizeBetaDMGCustomName,
  nextBuildNumber,
  parseEnvFile,
  parseReleaseNotes,
  parseSparkleSignatureOutput,
  publicR2URL,
  redactEnvValue,
  releaseNotesToHTML,
  requiredEnvNames,
  updateProjectVersions
} from "../scripts/release-lib.mjs";

test("parses and validates release notes", () => {
  const notes = parseReleaseNotes(JSON.stringify({
    releases: [
      {
        version: "1.2.0",
        features: ["New capture mode"],
        improvements: ["Faster table reload"],
        bugs: ["Fixed export crash"]
      }
    ]
  }));

  assert.equal(findReleaseNote(notes, "1.2.0").features[0], "New capture mode");
  assert.throws(
    () => parseReleaseNotes(JSON.stringify({ releases: [{ version: "1.0" }] })),
    /features string array/
  );
});

test("increments integer build numbers only", () => {
  assert.equal(nextBuildNumber("41"), "42");
  assert.throws(() => nextBuildNumber("41.2"), /non-negative integer/);
});

test("generates Sparkle appcast XML from structured notes", () => {
  const xml = generateAppcastXML({
    version: "1.2.0",
    buildNumber: "42",
    downloadURL: "https://downloads.example.com/tcpviewer.dmg",
    signature: {
      edSignature: "abc123",
      length: "12345"
    },
    releaseNote: {
      version: "1.2.0",
      features: ["New <feature>"],
      improvements: [],
      bugs: []
    },
    pubDate: new Date("2026-05-10T12:00:00Z")
  });

  assert.match(xml, /<sparkle:version>42<\/sparkle:version>/);
  assert.match(xml, /<sparkle:minimumSystemVersion>15.6<\/sparkle:minimumSystemVersion>/);
  assert.match(xml, /sparkle:edSignature="abc123"/);
  assert.match(xml, /New &lt;feature&gt;/);
});

test("builds R2 keys and public URLs", () => {
  assert.equal(
    makeR2ObjectKey({
      releaseType: "beta",
      version: "1.2.0",
      buildNumber: "42",
      timestamp: "20260510T120000Z",
      fileName: "tcpviewer_1.2.0_qa.dmg"
    }),
    "beta/tcpviewer_1.2.0_qa.dmg"
  );
  assert.equal(
    makeR2ObjectKey({ releaseType: "production", version: "1.2.0", buildNumber: "42" }),
    "production/1.2.0/42/tcpviewer.dmg"
  );
  assert.equal(
    publicR2URL("https://downloads.example.com/", "production/1.2.0/42/tcpviewer.dmg"),
    "https://downloads.example.com/production/1.2.0/42/tcpviewer.dmg"
  );
});

test("builds beta DMG file names from a safe custom name", () => {
  assert.equal(
    makeBetaDMGFileName({ version: "1.2.0", customName: "QA build" }),
    "tcpviewer_1.2.0_QA_build.dmg"
  );
  assert.equal(normalizeBetaDMGCustomName(" rc_1 "), "rc_1");
  assert.throws(() => makeBetaDMGFileName({ version: "1.2.0", customName: "../secret" }), /custom name/i);
  assert.throws(
    () => makeR2ObjectKey({
      releaseType: "beta",
      version: "1.2.0",
      buildNumber: "42",
      timestamp: "20260510T120000Z",
      fileName: "../tcpviewer.dmg"
    }),
    /plain \.dmg file name/
  );
});

test("builds backend URLs for release script endpoints", () => {
  assert.equal(
    backendCheckURL("https://api.example.com", { version: "1.2.0", buildNumber: "42" }),
    "https://api.example.com/api/releases/check-can-script-release-new-build?platform=macos&build_number=42&build_version=1.2.0"
  );
  assert.equal(
    backendCreateURL("https://api.example.com", { version: "1.2.0", buildNumber: "42" }),
    "https://api.example.com/api/releases/create-new-release?platform=macos&build_number=42&build_version=1.2.0"
  );
});

test("parses xcconfig-style env files and redacts secrets", () => {
  const parsed = parseEnvFile([
    "TCPVIEWER_BACKEND_URL=https:/$()/api.example.com",
    "TCPVIEWER_SCRIPT_SECRET=secret",
    "// ignored comment"
  ].join("\n"));

  assert.equal(parsed.TCPVIEWER_BACKEND_URL, "https://api.example.com");
  assert.equal(redactEnvValue("TCPVIEWER_SCRIPT_SECRET", parsed.TCPVIEWER_SCRIPT_SECRET), "<redacted>");
  assert.equal(redactEnvValue("TCPVIEWER_BACKEND_URL", parsed.TCPVIEWER_BACKEND_URL), "https://api.example.com");
});

test("validates release env names without leaking values", () => {
  const env = mergeEnv({ TCPVIEWER_DEVELOPMENT_TEAM: "ABCDE12345" }, {});
  const missing = missingRequiredEnv(env, requiredEnvNames("production"));

  assert.ok(missing.includes("TCPVIEWER_SCRIPT_SECRET"));
  assert.ok(missing.includes("TCPVIEWER_R2_SECRET_ACCESS_KEY"));
  assert.ok(missing.includes("TCPVIEWER_NOTARIZATION_USERNAME"));
  assert.ok(missing.includes("SENTRY_AUTH_TOKEN"));
  assert.ok(!missing.includes("TCPVIEWER_NOTARY_KEYCHAIN_PROFILE"));
});

test("parses Sparkle signing output and updates Xcode versions", () => {
  assert.deepEqual(
    parseSparkleSignatureOutput('sparkle:edSignature="sig" length="99"'),
    { edSignature: "sig", length: "99" }
  );
  assert.equal(
    updateProjectVersions("MARKETING_VERSION = 1.0;\nCURRENT_PROJECT_VERSION = 1;", {
      version: "1.2.0",
      buildNumber: "42"
    }),
    "MARKETING_VERSION = 1.2.0;\nCURRENT_PROJECT_VERSION = 42;"
  );
});

test("renders all release-note sections", () => {
  const html = releaseNotesToHTML({
    version: "1.2.0",
    features: [],
    improvements: ["Better release checks"],
    bugs: []
  });

  assert.match(html, /Features/);
  assert.match(html, /Better release checks/);
  assert.match(html, /Bug Fixes/);
});
