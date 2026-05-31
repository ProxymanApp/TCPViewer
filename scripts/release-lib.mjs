import { createHash, createHmac } from "node:crypto";

export const minimumSystemVersion = "15.6";
export const releaseDMGAppName = "tcpviewer";
export const defaultDMGFileName = `${releaseDMGAppName}.dmg`;
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

export function makeBetaDMGFileName({ version, customName, appName = releaseDMGAppName }) {
  const fileAppName = normalizeFileNameSegment(appName, "App name");
  const fileVersion = normalizeFileNameSegment(version, "Version");
  const fileCustomName = normalizeBetaDMGCustomName(customName);
  return `${fileAppName}_${fileVersion}_${fileCustomName}.dmg`;
}

export function normalizeBetaDMGCustomName(value) {
  const normalized = String(value ?? "").trim().replace(/\s+/g, "_");
  return normalizeFileNameSegment(normalized, "Beta DMG custom name");
}

export function makeR2ObjectKey({ releaseType, version, buildNumber, timestamp, fileName = defaultDMGFileName }) {
  const safeFileName = validateDMGFileName(fileName);

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
