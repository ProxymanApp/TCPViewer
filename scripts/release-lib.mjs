import { createHash, createHmac } from "node:crypto";

export const minimumSystemVersion = "15.0";
export const releaseDMGAppName = "tcpviewer";
export const emptyPayloadSHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

const fileNameSegmentPattern = /^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$/;

const commonRequiredEnv = [
  "TCPVIEWER_DEVELOPMENT_TEAM",
  "TCPVIEWER_BUILD_KEY",
  "TCPVIEWER_APPCAST_URL",
  "TCPVIEWER_EXPECTED_BUNDLE_ID",
  "TCPVIEWER_SPARKLE_PUBLIC_ED_KEY",
  "TCPVIEWER_SPARKLE_PRIVATE_ED_KEY",
  "TCPVIEWER_DEVELOPER_ID_APPLICATION",
  "TCPVIEWER_NOTARIZATION_USERNAME",
  "TCPVIEWER_NOTARIZATION_ASC_PROVIDER",
  "FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD",
  "SENTRY_AUTH_TOKEN",
  "SENTRY_ORG_SLUG",
  "SENTRY_PROJECT_SLUG",
  "TCPVIEWER_R2_ACCOUNT_ID",
  "TCPVIEWER_R2_ACCESS_KEY_ID",
  "TCPVIEWER_R2_SECRET_ACCESS_KEY",
  "TCPVIEWER_R2_BUCKET",
  "TCPVIEWER_R2_PUBLIC_BASE_URL"
];

export const releaseBackendRequiredEnvNames = [
  "TCPVIEWER_RELEASE_BACKEND_URL",
  "TCPVIEWER_RELEASE_BACKEND_SCRIPT_SECRET"
];

export function normalizeXcconfigValue(value) {
  if (typeof value !== "string") {
    return value;
  }

  return value.replaceAll(":/$()/", "://");
}

export function parseEnvFile(content) {
  const env = {};
  for (const rawLine of content.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#") || line.startsWith("//")) {
      continue;
    }

    const separatorIndex = line.indexOf("=");
    if (separatorIndex === -1) {
      continue;
    }

    const key = line.slice(0, separatorIndex).trim();
    const rawValue = line.slice(separatorIndex + 1).trim();
    if (!key) {
      continue;
    }

    env[key] = normalizeXcconfigValue(stripOptionalQuotes(rawValue));
  }

  return env;
}

export function mergeEnv(fileEnv, processEnv) {
  const merged = { ...fileEnv, ...processEnv };
  for (const [key, value] of Object.entries(merged)) {
    merged[key] = normalizeXcconfigValue(value);
  }

  return merged;
}

export function requiredEnvNames(releaseType) {
  if (!["beta", "production"].includes(releaseType)) {
    throw new Error(`Unsupported release type: ${releaseType}`);
  }

  return commonRequiredEnv;
}

export function missingRequiredEnv(env, names) {
  return names.filter((name) => !String(env[name] ?? "").trim());
}

export function publishReleaseToBackendEnabled(env) {
  const value = String(env.TCPVIEWER_PUBLISH_RELEASE_TO_BACKEND ?? "").trim().toLowerCase();
  if (!value || ["0", "false", "no", "off"].includes(value)) {
    return false;
  }

  if (["1", "true", "yes", "on"].includes(value)) {
    return true;
  }

  throw new Error("TCPVIEWER_PUBLISH_RELEASE_TO_BACKEND must be one of: 1, true, yes, on, 0, false, no, off.");
}

export function isRetryableHTTPStatus(status) {
  return status === 408 || status === 425 || status === 429 || status >= 500;
}

export function describeFetchError(error) {
  const descriptions = [];
  let current = error;
  for (let depth = 0; current && depth < 4; depth += 1) {
    const code = typeof current.code === "string" && current.code ? `${current.code}: ` : "";
    const message = typeof current.message === "string" && current.message
      ? current.message
      : String(current);
    const description = `${code}${message}`.trim();
    if (description && !descriptions.includes(description)) {
      descriptions.push(description);
    }
    current = current.cause;
  }

  return descriptions.join(" | ") || "Unknown fetch failure.";
}

export function normalizeReleaseBackendURL(value) {
  const rawURL = String(value ?? "").trim();
  if (!rawURL) {
    throw new Error("TCPVIEWER_RELEASE_BACKEND_URL is required when backend release publishing is enabled.");
  }

  let url;
  try {
    url = new URL(rawURL);
  } catch {
    throw new Error("TCPVIEWER_RELEASE_BACKEND_URL must be a valid HTTP or HTTPS URL.");
  }

  if (!["http:", "https:"].includes(url.protocol)) {
    throw new Error("TCPVIEWER_RELEASE_BACKEND_URL must use http or https.");
  }

  return url.href.replace(/\/+$/, "");
}

export function redactEnvValue(name, value) {
  if (/SECRET|PRIVATE|PASSWORD|TOKEN|KEY/i.test(name)) {
    return "<redacted>";
  }

  return String(value ?? "");
}

export function normalizeSparklePrivateKey(value) {
  let key = String(value ?? "").trim();
  // zsh can display a trailing "%" when copied output has no newline; keep it out of the key file.
  key = key.replace(/%+$/g, "").trim();

  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(key)) {
    throw new Error("TCPVIEWER_SPARKLE_PRIVATE_ED_KEY must be a base64 EdDSA private key.");
  }

  const decoded = Buffer.from(key, "base64");
  if (decoded.length !== 32 || decoded.toString("base64") !== key) {
    throw new Error("TCPVIEWER_SPARKLE_PRIVATE_ED_KEY must decode to a 32-byte EdDSA private key.");
  }

  return key;
}

export function parseBuildSettings(text) {
  const settings = {};
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (match) {
      settings[match[1]] = match[2];
    }
  }

  return settings;
}

export function parseReleaseNotes(content) {
  let parsed;
  try {
    parsed = JSON.parse(content);
  } catch (error) {
    throw new Error(`ReleaseNote.json is invalid JSON: ${error.message}`);
  }

  if (!parsed || !Array.isArray(parsed.releases)) {
    throw new Error("ReleaseNote.json must contain a releases array.");
  }

  for (const release of parsed.releases) {
    validateReleaseNote(release);
  }

  return parsed;
}

export function findReleaseNote(releaseNotes, version) {
  const release = releaseNotes.releases.find((candidate) => candidate.version === version);
  if (!release) {
    throw new Error(`ReleaseNote.json does not contain release version ${version}.`);
  }

  return release;
}

export function assertReleaseTitleReflectsChanges(release) {
  validateReleaseNote(release);

  if (!isGenericReleaseTitle(release)) {
    return;
  }

  throw new Error(
    `Release ${release.version} title "${release.title}" is too generic. ` +
    `Use a title that names the headline changes, for example: "${makeReleaseTitleSuggestion(release)}".`
  );
}

export function makeGitHubReleaseTagName(version) {
  const safeVersion = normalizeFileNameSegment(version, "GitHub release version");
  return `v${safeVersion}`;
}

export function releaseNotesToHTML(release) {
  validateReleaseNote(release);

  const sections = [
    ["Features", release.features],
    ["Improvements", release.improvements],
    ["Bug Fixes", release.bugs]
  ];

  const body = sections
    .map(([title, entries]) => {
      const items = entries.length
        ? entries.map((entry) => `<li>${escapeHTML(entry)}</li>`).join("")
        : "<li>None</li>";
      return `<h2>${title}</h2><ul>${items}</ul>`;
    })
    .join("");

  return `<h1>${escapeHTML(release.title)}</h1>${body}`;
}

export function releaseNotesToMarkdown(release) {
  validateReleaseNote(release);

  return [
    markdownReleaseNoteSection("Features", release.features),
    markdownReleaseNoteSection("Improvements", release.improvements),
    markdownReleaseNoteSection("Bug Fixes", release.bugs)
  ].join("\n\n") + "\n";
}

export function parseSparkleSignatureOutput(output) {
  const signatureMatch = output.match(/sparkle:edSignature="([^"]+)"/);
  const lengthMatch = output.match(/length="([0-9]+)"/);
  if (!signatureMatch || !lengthMatch) {
    throw new Error("Sparkle sign_update output did not include edSignature and length.");
  }

  return {
    edSignature: signatureMatch[1],
    length: lengthMatch[1]
  };
}

export function generateAppcastXML({
  version,
  buildNumber,
  downloadURL,
  signature,
  releaseNote,
  pubDate = new Date(),
  bundleId,
  minimumOSVersion = minimumSystemVersion
}) {
  validateReleaseNote(releaseNote);
  if (!String(bundleId ?? "").trim()) {
    throw new Error("Appcast bundleId is required.");
  }

  const releaseNotesHTML = releaseNotesToHTML(releaseNote);
  return [
    '<?xml version="1.0" encoding="utf-8"?>',
    '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">',
    "  <channel>",
    "    <title>TCP Viewer Updates</title>",
    "    <description>TCP Viewer macOS app updates</description>",
    "    <language>en</language>",
    "    <item>",
    `      <title>${escapeXML(releaseNote.title)}</title>`,
    `      <sparkle:version>${escapeXML(buildNumber)}</sparkle:version>`,
    `      <sparkle:shortVersionString>${escapeXML(version)}</sparkle:shortVersionString>`,
    `      <sparkle:minimumSystemVersion>${escapeXML(minimumOSVersion)}</sparkle:minimumSystemVersion>`,
    `      <sparkle:bundleIdentifier>${escapeXML(bundleId)}</sparkle:bundleIdentifier>`,
    `      <pubDate>${pubDate.toUTCString()}</pubDate>`,
    `      <description>${wrapCDATA(releaseNotesHTML)}</description>`,
    `      <enclosure url="${escapeXML(downloadURL)}" sparkle:edSignature="${escapeXML(signature.edSignature)}" length="${escapeXML(signature.length)}" type="application/octet-stream" />`,
    "    </item>",
    "  </channel>",
    "</rss>",
    ""
  ].join("\n");
}

// Keep release artifacts self-describing across local output, R2, and GitHub uploads.
export function makeDMGFileName({ version, buildNumber, appName = releaseDMGAppName }) {
  const fileAppName = normalizeFileNameSegment(appName, "App name");
  const fileVersion = normalizeFileNameSegment(version, "Version");
  const fileBuildNumber = normalizeFileNameSegment(buildNumber, "Build number");
  return `${fileAppName}_${fileVersion}_${fileBuildNumber}.dmg`;
}

export function makeBetaDMGFileName({ version, buildNumber, customName, appName = releaseDMGAppName }) {
  const baseFileName = makeDMGFileName({ version, buildNumber, appName }).replace(/\.dmg$/, "");
  const fileCustomName = normalizeBetaDMGCustomName(customName);
  return `${baseFileName}_${fileCustomName}.dmg`;
}

export function normalizeBetaDMGCustomName(value) {
  const normalized = String(value ?? "").trim().replace(/\s+/g, "_");
  return normalizeFileNameSegment(normalized, "Beta DMG custom name");
}

export function makeHomebrewCaskBranchName({ version, buildNumber }) {
  const safeVersion = normalizeFileNameSegment(version, "Homebrew Cask version");
  const safeBuildNumber = normalizeFileNameSegment(buildNumber, "Homebrew Cask build number");
  return `tcpviewer-${safeVersion}-${safeBuildNumber}`;
}

export function makeHomebrewCaskAuditArgs({ isInitialCask, token = "tcpviewer" }) {
  const args = ["audit", "--cask", "--online"];
  if (isInitialCask) {
    args.push("--new");
  }
  args.push(token);
  return args;
}

export function validateHomebrewLivecheckOutput(output, expectedVersion) {
  let entries;
  try {
    entries = JSON.parse(String(output));
  } catch {
    throw new Error("Homebrew livecheck did not return valid JSON.");
  }
  const entry = Array.isArray(entries) ? entries[0] : null;
  if (!entry?.version) {
    throw new Error(`Homebrew livecheck did not return a version: ${entry?.status ?? "missing result"}.`);
  }
  if (entry.version.current !== expectedVersion || entry.version.latest !== expectedVersion) {
    throw new Error(
      `Homebrew livecheck must report ${expectedVersion} as current and latest; `
      + `found ${entry.version.current ?? "unknown"} and ${entry.version.latest ?? "unknown"}.`
    );
  }
}

export function validatePublishedGitHubReleaseAsset(release, { tagName, assetName }) {
  if (release?.tagName !== tagName) {
    throw new Error(`GitHub release must use tag ${tagName}.`);
  }
  if (release.isDraft || release.isPrerelease) {
    throw new Error(`GitHub release ${tagName} must be a published production release.`);
  }

  const matches = Array.isArray(release.assets)
    ? release.assets.filter((asset) => asset?.name === assetName)
    : [];
  if (matches.length !== 1) {
    throw new Error(`GitHub release ${tagName} must contain exactly one ${assetName} asset.`);
  }

  const asset = matches[0];
  const digest = String(asset.digest ?? "").trim().toLowerCase();
  if (!/^sha256:[a-f0-9]{64}$/.test(digest)) {
    throw new Error(`GitHub release asset ${assetName} must include a SHA-256 digest.`);
  }
  if (!Number.isSafeInteger(asset.size) || asset.size <= 0) {
    throw new Error(`GitHub release asset ${assetName} must include a positive file size.`);
  }

  return {
    name: assetName,
    sha256: digest.slice("sha256:".length),
    size: asset.size
  };
}

export function resolvePublishedGitHubReleaseArtifact(release) {
  const tagName = String(release?.tagName ?? "").trim();
  if (!tagName.startsWith("v")) {
    throw new Error("The latest GitHub release tag must start with v.");
  }

  const version = tagName.slice(1);
  if (makeGitHubReleaseTagName(version) !== tagName) {
    throw new Error(`The latest GitHub release tag is invalid: ${tagName}.`);
  }

  const prefix = `${releaseDMGAppName}_${version}_`;
  const suffix = ".dmg";
  const candidates = Array.isArray(release.assets)
    ? release.assets.flatMap((asset) => {
        const name = String(asset?.name ?? "");
        if (!name.startsWith(prefix) || !name.endsWith(suffix)) {
          return [];
        }

        const buildNumber = name.slice(prefix.length, -suffix.length);
        try {
          return makeDMGFileName({ version, buildNumber }) === name
            ? [{ asset, buildNumber }]
            : [];
        } catch {
          return [];
        }
      })
    : [];
  if (candidates.length !== 1) {
    throw new Error(`GitHub release ${tagName} must contain exactly one production DMG asset.`);
  }

  const candidate = candidates[0];
  const validated = validatePublishedGitHubReleaseAsset(release, {
    tagName,
    assetName: candidate.asset.name
  });
  return {
    tagName,
    version,
    buildNumber: candidate.buildNumber,
    dmgFileName: validated.name,
    sha256: validated.sha256,
    size: validated.size
  };
}

export function makeHomebrewCaskPullRequestBody({ template, isInitialCask, githubMetrics }) {
  const templateLines = String(template ?? "").replaceAll("\r\n", "\n").trim().split("\n");
  const checkboxLines = templateLines.filter((line) => /^- \[ \] /.test(line));
  if (checkboxLines.length === 0 || !checkboxLines.some((line) => /\b(?:AI|LLM)\b/i.test(line))) {
    throw new Error("The Homebrew Cask pull request template is missing its checklist or AI disclosure.");
  }
  if (isInitialCask && !githubMetrics) {
    throw new Error("GitHub metrics are required for an initial Homebrew Cask pull request.");
  }

  let inNewCaskSection = false;
  const completedTemplate = templateLines.map((line) => {
    if (line.startsWith("Additionally, if adding a new cask:")) {
      inNewCaskSection = true;
      return line;
    }
    if (inNewCaskSection && /^-+$/.test(line.trim())) {
      inNewCaskSection = false;
      return line;
    }
    if (/^- \[ \] /.test(line) && (isInitialCask || !inNewCaskSection)) {
      return line.replace("- [ ] ", "- [x] ");
    }
    return line;
  });

  const finalSeparatorIndex = completedTemplate.findLastIndex((line) => /^-+$/.test(line.trim()));
  if (finalSeparatorIndex === -1) {
    throw new Error("The Homebrew Cask pull request template is missing its final separator.");
  }

  const details = [];
  if (isInitialCask) {
    details.push(
      "Canonical repository: https://github.com/ProxymanApp/TCPViewer",
      `Repository metrics: ${githubMetrics.stars} stars, ${githubMetrics.forks} forks, `
      + `${githubMetrics.watchers} watchers when this PR was created.`,
      ""
    );
  }
  details.push(
    "AI/LLM disclosure: OpenAI Codex assisted with the release automation that updated this cask. The maintainer "
    + "reviewed the cask, verified the release artifact, and ran the checked Homebrew validation commands.",
    ""
  );

  completedTemplate.splice(finalSeparatorIndex, 0, ...details);
  return completedTemplate.join("\n");
}

export function parseHomebrewCaskVersion(content) {
  const match = String(content).match(/^  version "([^"]+),([^"]+)"$/m);
  if (!match) {
    throw new Error("TCP Viewer Homebrew Cask must contain one version with a version and build number.");
  }

  return { version: match[1], buildNumber: match[2] };
}

export function githubRepoFromRemoteURL(remoteURL) {
  const match = String(remoteURL).trim().match(
    /^(?:git@github\.com:|ssh:\/\/git@github\.com\/|https:\/\/github\.com\/)([^/]+\/[^/]+?)(?:\.git)?$/i
  );
  return match ? match[1].toLowerCase() : null;
}

export function validateHomebrewCaskContent(content) {
  const current = String(content);
  const parsedVersion = parseHomebrewCaskVersion(current);
  const versionMatches = current.match(/^  version ".*"$/gm) ?? [];
  const shaMatches = current.match(/^  sha256 ".*"$/gm) ?? [];
  if (versionMatches.length !== 1 || shaMatches.length !== 1) {
    throw new Error("TCP Viewer Homebrew Cask must contain exactly one version and one SHA-256 stanza.");
  }
  if (!/^  depends_on arch: :arm64$/m.test(current)) {
    throw new Error("TCP Viewer Homebrew Cask must require Apple Silicon.");
  }
  if (!/^  app "TCP Viewer\.app"$/m.test(current)) {
    throw new Error("TCP Viewer Homebrew Cask must install TCP Viewer.app.");
  }

  return parsedVersion;
}

export function updateHomebrewCaskContent(content, { version, buildNumber, sha256 }) {
  const current = String(content);
  validateHomebrewCaskContent(current);
  const safeVersion = normalizeFileNameSegment(version, "Homebrew Cask version");
  const safeBuildNumber = normalizeFileNameSegment(buildNumber, "Homebrew Cask build number");
  const safeSHA256 = String(sha256 ?? "").trim().toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(safeSHA256)) {
    throw new Error("Homebrew Cask SHA-256 must contain 64 hexadecimal characters.");
  }

  const versionMatch = current.match(/^  version ".*"$/m)[0];
  const shaMatch = current.match(/^  sha256 ".*"$/m)[0];

  const updated = current
    .replace(versionMatch, `  version "${safeVersion},${safeBuildNumber}"`)
    .replace(shaMatch, `  sha256 "${safeSHA256}"`);
  validateHomebrewCaskContent(updated);
  return updated;
}

export function makeR2ObjectKey({ releaseType, version, buildNumber, timestamp, fileName }) {
  const safeFileName = validateDMGFileName(fileName ?? makeDMGFileName({ version, buildNumber }));

  if (releaseType === "beta") {
    return `beta/${safeFileName}`;
  }

  return `production/${version}/${buildNumber}/${safeFileName}`;
}

export function publicR2URL(baseURL, objectKey) {
  const normalizedBase = String(baseURL).replace(/\/+$/, "");
  return `${normalizedBase}/${objectKey.split("/").map(encodeURIComponent).join("/")}`;
}

export function makeR2StorageObjectKey(publicBaseURL, objectKey) {
  const publicPathPrefix = new URL(String(publicBaseURL)).pathname
    .split("/")
    .filter(Boolean)
    .join("/");
  return [publicPathPrefix, objectKey].filter(Boolean).join("/");
}

// Build the path-style R2 object URL used by Cloudflare's S3-compatible API.
export function makeR2ObjectURL({ accountId, bucket, objectKey }) {
  const encodedBucket = encodePathSegment(bucket);
  const encodedKey = String(objectKey).split("/").map(encodePathSegment).join("/");
  return new URL(`/${encodedBucket}/${encodedKey}`, `https://${accountId}.r2.cloudflarestorage.com`);
}

// Sign direct R2 requests with AWS Signature V4 without depending on AWS SDK.
export function signR2Request({
  method,
  url,
  accessKeyId,
  secretAccessKey,
  payloadHash,
  headers = {},
  now = new Date()
}) {
  const amzDate = toAmzDate(now);
  const dateStamp = amzDate.slice(0, 8);
  const requestHeaders = normalizeHeaders({
    ...headers,
    host: url.host,
    "x-amz-content-sha256": payloadHash,
    "x-amz-date": amzDate
  });

  const signedHeaderNames = Object.keys(requestHeaders)
    .filter((name) => name === "host" || name.startsWith("x-amz-"))
    .sort();
  const canonicalHeaders = signedHeaderNames
    .map((name) => `${name}:${requestHeaders[name]}\n`)
    .join("");
  const signedHeaders = signedHeaderNames.join(";");
  const credentialScope = `${dateStamp}/auto/s3/aws4_request`;
  const canonicalRequest = [
    method.toUpperCase(),
    url.pathname,
    canonicalQueryString(url),
    canonicalHeaders,
    signedHeaders,
    payloadHash
  ].join("\n");
  const stringToSign = [
    "AWS4-HMAC-SHA256",
    amzDate,
    credentialScope,
    sha256Hex(canonicalRequest)
  ].join("\n");
  const signingKey = hmac(`AWS4${secretAccessKey}`, dateStamp);
  const regionKey = hmac(signingKey, "auto");
  const serviceKey = hmac(regionKey, "s3");
  const requestKey = hmac(serviceKey, "aws4_request");
  const signature = hmacHex(requestKey, stringToSign);

  return {
    ...requestHeaders,
    authorization: `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`
  };
}

function validateReleaseNote(release) {
  if (!release || typeof release.version !== "string" || !release.version.trim()) {
    throw new Error("Each release note must include a version string.");
  }

  if (typeof release.title !== "string" || !release.title.trim()) {
    throw new Error(`Release ${release.version} must include a title string.`);
  }

  for (const field of ["features", "improvements", "bugs"]) {
    if (!Array.isArray(release[field]) || !release[field].every((entry) => typeof entry === "string")) {
      throw new Error(`Release ${release.version} must include a ${field} string array.`);
    }
  }
}

function isGenericReleaseTitle(release) {
  const title = normalizeTitleText(release.title).toLowerCase();
  const versionPrefix = new RegExp(`^(?:tcp viewer\\s+)?v?${escapeRegExp(release.version.toLowerCase())}\\s+`);
  const suffix = title.replace(versionPrefix, "").trim();
  const genericSuffixes = new Set([
    "release",
    "production release",
    "stable release",
    "maintenance release",
    "maintenance build",
    "build",
    "new build",
    "update"
  ]);

  return genericSuffixes.has(suffix);
}

function makeReleaseTitleSuggestion(release) {
  const topics = [...release.features, ...release.improvements, ...release.bugs]
    .map(releaseTitleTopic)
    .filter(Boolean)
    .slice(0, 3);

  if (!topics.length) {
    return `TCP Viewer ${release.version} Release Highlights`;
  }

  return `TCP Viewer ${release.version} ${joinTitleTopics(topics)}`;
}

function releaseTitleTopic(entry) {
  const topic = normalizeTitleText(entry)
    .replace(/\.$/, "")
    .replace(/^(add|added|new|implement|implemented|improve|improved|fix|fixed|preserve|preserved|show|removed|remove)\s+/i, "")
    .replace(/\s+(for|to|during|when|with|in|on)\s+.*$/i, "")
    .split(/\s+/)
    .slice(0, 5)
    .join(" ");

  return titleCase(topic);
}

function joinTitleTopics(topics) {
  if (topics.length <= 2) {
    return topics.join(" and ");
  }

  return `${topics.slice(0, -1).join(", ")}, and ${topics[topics.length - 1]}`;
}

function titleCase(value) {
  const lowerCaseWords = new Set(["and", "or", "the", "a", "an", "to", "for", "in", "on", "with", "of"]);
  return value
    .split(/\s+/)
    .map((word, index) => {
      const lowerWord = word.toLowerCase();
      if (index > 0 && lowerCaseWords.has(lowerWord)) {
        return lowerWord;
      }

      return `${lowerWord.slice(0, 1).toUpperCase()}${lowerWord.slice(1)}`;
    })
    .join(" ");
}

function normalizeTitleText(value) {
  return String(value ?? "").trim().replace(/\s+/g, " ");
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function normalizeFileNameSegment(value, label) {
  const segment = String(value ?? "").trim();
  if (!segment) {
    throw new Error(`${label} is required.`);
  }

  if (!fileNameSegmentPattern.test(segment)) {
    throw new Error(`${label} must use only letters, numbers, dots, underscores, or hyphens, and must start and end with a letter or number.`);
  }

  return segment;
}

function validateDMGFileName(fileName) {
  const value = String(fileName ?? "").trim();
  if (!value.endsWith(".dmg") || value.includes("/") || value.includes("\\") || value === ".dmg") {
    throw new Error("DMG file name must be a plain .dmg file name.");
  }

  return value;
}

function markdownReleaseNoteSection(title, entries) {
  const items = entries.length
    ? entries.map((entry) => `- ${normalizeMarkdownListText(entry)}`).join("\n")
    : "- None";
  return `## ${title}\n${items}`;
}

function normalizeMarkdownListText(value) {
  return String(value).trim().replace(/\s+/g, " ");
}

function toAmzDate(date) {
  return date.toISOString().replace(/[:-]|\.\d{3}/g, "");
}

function normalizeHeaders(headers) {
  const normalized = {};
  for (const [name, value] of Object.entries(headers)) {
    normalized[name.toLowerCase()] = String(value).trim().replace(/\s+/g, " ");
  }
  return normalized;
}

function canonicalQueryString(url) {
  return [...url.searchParams.entries()]
    .sort(([leftName, leftValue], [rightName, rightValue]) => {
      const nameSort = leftName.localeCompare(rightName);
      return nameSort === 0 ? leftValue.localeCompare(rightValue) : nameSort;
    })
    .map(([name, value]) => `${encodePathSegment(name)}=${encodePathSegment(value)}`)
    .join("&");
}

function encodePathSegment(value) {
  return encodeURIComponent(String(value)).replace(/[!'()*]/g, (character) => {
    return `%${character.charCodeAt(0).toString(16).toUpperCase()}`;
  });
}

function sha256Hex(value) {
  return createHash("sha256").update(value).digest("hex");
}

function hmac(key, value) {
  return createHmac("sha256", key).update(value).digest();
}

function hmacHex(key, value) {
  return createHmac("sha256", key).update(value).digest("hex");
}

function stripOptionalQuotes(value) {
  if (
    (value.startsWith('"') && value.endsWith('"')) ||
    (value.startsWith("'") && value.endsWith("'"))
  ) {
    return value.slice(1, -1);
  }

  return value;
}

function escapeHTML(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function escapeXML(value) {
  return escapeHTML(value);
}

function wrapCDATA(value) {
  return `<![CDATA[${String(value).replaceAll("]]>", "]]]]><![CDATA[>")}]]>`;
}
