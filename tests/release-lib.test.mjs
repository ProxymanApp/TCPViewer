import assert from "node:assert/strict";
import { test } from "node:test";
import {
  emptyPayloadSHA256,
  findReleaseNote,
  generateAppcastXML,
  makeBetaDMGFileName,
  makeR2ObjectURL,
  makeR2ObjectKey,
  makeR2StorageObjectKey,
  mergeEnv,
  missingRequiredEnv,
  normalizeBetaDMGCustomName,
  normalizeReleaseBackendURL,
  normalizeSparklePrivateKey,
  parseEnvFile,
  parseReleaseNotes,
  parseSparkleSignatureOutput,
  publicR2URL,
  publishReleaseToBackendEnabled,
  redactEnvValue,
  releaseBackendRequiredEnvNames,
  releaseNotesToHTML,
  requiredEnvNames,
  signR2Request
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
    bundleId: "com.example.tcpviewer",
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
  assert.equal(
    publicR2URL("https://downloads.example.com/release", "beta/tcpviewer.dmg"),
    "https://downloads.example.com/release/beta/tcpviewer.dmg"
  );
  assert.equal(
    makeR2StorageObjectKey("https://downloads.example.com/release", "beta/tcpviewer.dmg"),
    "release/beta/tcpviewer.dmg"
  );
});

test("signs direct R2 requests without exposing the secret key", () => {
  const url = makeR2ObjectURL({
    accountId: "abc123",
    bucket: "tcpviewer",
    objectKey: "production/1.2.0/42/tcp viewer.dmg"
  });
  const headers = signR2Request({
    method: "HEAD",
    url,
    accessKeyId: "test-access",
    secretAccessKey: "example-private-value",
    payloadHash: emptyPayloadSHA256,
    now: new Date("2026-05-25T01:02:03.000Z")
  });

  assert.equal(url.href, "https://abc123.r2.cloudflarestorage.com/tcpviewer/production/1.2.0/42/tcp%20viewer.dmg");
  assert.equal(headers["x-amz-date"], "20260525T010203Z");
  assert.equal(headers.authorization, "AWS4-HMAC-SHA256 Credential=test-access/20260525/auto/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=31e10693839d229ca9c3be973d27cafafc0d0d29195b92a6197e9abea7623e00");
  assert.ok(!headers.authorization.includes("example-private-value"));
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

test("parses xcconfig-style env files and redacts secrets", () => {
  const parsed = parseEnvFile([
    "TCPVIEWER_APPCAST_URL=https:/$()/updates.example.com/appcast.xml",
    "TCPVIEWER_R2_SECRET_ACCESS_KEY=placeholder-value",
    "// ignored comment"
  ].join("\n"));

  assert.equal(parsed.TCPVIEWER_APPCAST_URL, "https://updates.example.com/appcast.xml");
  assert.equal(redactEnvValue("TCPVIEWER_R2_SECRET_ACCESS_KEY", parsed.TCPVIEWER_R2_SECRET_ACCESS_KEY), "<redacted>");
  assert.equal(redactEnvValue("TCPVIEWER_APPCAST_URL", parsed.TCPVIEWER_APPCAST_URL), "https://updates.example.com/appcast.xml");
});

test("normalizes Sparkle private keys without leaking copied prompt markers", () => {
  const key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  assert.equal(normalizeSparklePrivateKey(`${key}%`), key);
  assert.throws(
    () => normalizeSparklePrivateKey("not a valid key"),
    /base64 EdDSA private key/
  );
});

test("validates release env names without leaking values", () => {
  const env = mergeEnv({ TCPVIEWER_DEVELOPMENT_TEAM: "ABCDE12345" }, {});
  const missing = missingRequiredEnv(env, requiredEnvNames("production"));

  assert.ok(missing.includes("TCPVIEWER_EXPECTED_BUNDLE_ID"));
  assert.ok(missing.includes("TCPVIEWER_R2_SECRET_ACCESS_KEY"));
  assert.ok(missing.includes("TCPVIEWER_NOTARIZATION_USERNAME"));
  assert.ok(missing.includes("SENTRY_AUTH_TOKEN"));
  assert.ok(!missing.includes("TCPVIEWER_NOTARY_KEYCHAIN_PROFILE"));
});

test("validates optional release backend publishing env", () => {
  assert.equal(publishReleaseToBackendEnabled({}), false);
  assert.equal(publishReleaseToBackendEnabled({ TCPVIEWER_PUBLISH_RELEASE_TO_BACKEND: "yes" }), true);
  assert.equal(publishReleaseToBackendEnabled({ TCPVIEWER_PUBLISH_RELEASE_TO_BACKEND: "off" }), false);
  assert.throws(
    () => publishReleaseToBackendEnabled({ TCPVIEWER_PUBLISH_RELEASE_TO_BACKEND: "maybe" }),
    /TCPVIEWER_PUBLISH_RELEASE_TO_BACKEND/
  );

  assert.equal(normalizeReleaseBackendURL("http://localhost:3000/"), "http://localhost:3000");
  assert.equal(normalizeReleaseBackendURL("https://api.example.com/releases"), "https://api.example.com/releases");
  assert.throws(() => normalizeReleaseBackendURL("file:///tmp/releases"), /http or https/);

  const missing = missingRequiredEnv(
    { TCPVIEWER_RELEASE_BACKEND_URL: "http://localhost:3000" },
    releaseBackendRequiredEnvNames
  );
  assert.deepEqual(missing, ["TCPVIEWER_RELEASE_BACKEND_SCRIPT_SECRET"]);
});

test("parses Sparkle signing output", () => {
  assert.deepEqual(
    parseSparkleSignatureOutput('sparkle:edSignature="sig" length="99"'),
    { edSignature: "sig", length: "99" }
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
