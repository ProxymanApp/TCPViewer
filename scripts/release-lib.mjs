export const macOSPlatform = "macos";
export const productionBundleId = "com.proxyman.tcpviewer";
export const minimumSystemVersion = "15.6";
export const releaseDMGAppName = "tcpviewer";
export const defaultDMGFileName = `${releaseDMGAppName}.dmg`;

const fileNameSegmentPattern = /^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$/;

const commonRequiredEnv = [
  "TCPVIEWER_DEVELOPMENT_TEAM",
  "TCPVIEWER_BUILD_KEY",
  "TCPVIEWER_APPCAST_URL",
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

const productionRequiredEnv = [
  "TCPVIEWER_BACKEND_URL",
  "TCPVIEWER_SCRIPT_SECRET"
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
  return releaseType === "production"
    ? [...commonRequiredEnv, ...productionRequiredEnv]
    : commonRequiredEnv;
}

export function missingRequiredEnv(env, names) {
  return names.filter((name) => !String(env[name] ?? "").trim());
}

export function redactEnvValue(name, value) {
  if (/SECRET|PRIVATE|PASSWORD|TOKEN|KEY/i.test(name)) {
    return "<redacted>";
  }

  return String(value ?? "");
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

export function nextBuildNumber(currentBuildNumber) {
  const parsed = Number.parseInt(String(currentBuildNumber), 10);
  if (!Number.isSafeInteger(parsed) || parsed < 0 || String(parsed) !== String(currentBuildNumber).trim()) {
    throw new Error(`Build number must be a non-negative integer: ${currentBuildNumber}`);
  }

  return String(parsed + 1);
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

  return `<h1>TCP Viewer ${escapeHTML(release.version)}</h1>${body}`;
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
  bundleId = productionBundleId,
  minimumOSVersion = minimumSystemVersion
}) {
  validateReleaseNote(releaseNote);

  const releaseNotesHTML = releaseNotesToHTML(releaseNote);
  return [
    '<?xml version="1.0" encoding="utf-8"?>',
    '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">',
    "  <channel>",
    "    <title>TCP Viewer Updates</title>",
    "    <description>TCP Viewer macOS app updates</description>",
    "    <language>en</language>",
    "    <item>",
    `      <title>TCP Viewer ${escapeXML(version)}</title>`,
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

export function backendCheckURL(baseURL, { version, buildNumber, platform = macOSPlatform }) {
  const url = new URL("/api/releases/check-can-script-release-new-build", normalizeBackendBaseURL(baseURL));
  url.searchParams.set("platform", platform);
  url.searchParams.set("build_number", buildNumber);
  url.searchParams.set("build_version", version);
  return url.toString();
}

export function backendCreateURL(baseURL, { version, buildNumber, platform = macOSPlatform }) {
  const url = new URL("/api/releases/create-new-release", normalizeBackendBaseURL(baseURL));
  url.searchParams.set("platform", platform);
  url.searchParams.set("build_number", buildNumber);
  url.searchParams.set("build_version", version);
  return url.toString();
}

export function updateProjectVersions(projectText, { version, buildNumber }) {
  return projectText
    .replace(/MARKETING_VERSION = [^;]+;/g, `MARKETING_VERSION = ${version};`)
    .replace(/CURRENT_PROJECT_VERSION = [^;]+;/g, `CURRENT_PROJECT_VERSION = ${buildNumber};`);
}

function validateReleaseNote(release) {
  if (!release || typeof release.version !== "string" || !release.version.trim()) {
    throw new Error("Each release note must include a version string.");
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

function stripOptionalQuotes(value) {
  if (
    (value.startsWith('"') && value.endsWith('"')) ||
    (value.startsWith("'") && value.endsWith("'"))
  ) {
    return value.slice(1, -1);
  }

  return value;
}

function normalizeBackendBaseURL(baseURL) {
  const normalized = normalizeXcconfigValue(baseURL);
  return normalized.endsWith("/") ? normalized : `${normalized}/`;
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
