#!/usr/bin/env node

import { createReadStream } from "node:fs";
import { createHash } from "node:crypto";
import {
  access,
  chmod,
  mkdtemp,
  mkdir,
  readFile,
  rm,
  stat,
  writeFile
} from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import prompts from "prompts";
import {
  defaultDMGFileName,
  emptyPayloadSHA256,
  findReleaseNote,
  generateAppcastXML,
  makeBetaDMGFileName,
  makeR2ObjectURL,
  makeR2ObjectKey,
  makeR2StorageObjectKey,
  mergeEnv,
  missingRequiredEnv,
  normalizeReleaseBackendURL,
  normalizeSparklePrivateKey,
  parseBuildSettings,
  parseEnvFile,
  parseReleaseNotes,
  parseSparkleSignatureOutput,
  publicR2URL,
  publishReleaseToBackendEnabled,
  redactEnvValue,
  releaseBackendRequiredEnvNames,
  requiredEnvNames,
  signR2Request
} from "./release-lib.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");
const releaseBackendPlatform = "macos";

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const releaseType = args.type ?? await askReleaseType();
  if (!["beta", "production"].includes(releaseType)) {
    throw new Error("Release type must be beta or production.");
  }

  const { env, envFileExists } = await loadReleaseEnv();
  const settings = await readXcodeBuildSettings(env);
  validateRequiredBuildSettings(settings);
  const currentVersion = settings.MARKETING_VERSION;
  const currentBuildNumber = settings.CURRENT_PROJECT_VERSION;
  const timestamp = makeTimestamp();
  const version = currentVersion;
  const buildNumber = currentBuildNumber;
  const dmgFileName = releaseType === "beta"
    ? makeBetaDMGFileName({
        version,
        customName: args.betaName ?? await askBetaDMGCustomName(version)
      })
    : defaultDMGFileName;
  const releaseObjectKey = makeR2ObjectKey({
    releaseType,
    version,
    buildNumber,
    timestamp,
    fileName: dmgFileName
  });
  const objectKey = makeR2StorageObjectKey(env.TCPVIEWER_R2_PUBLIC_BASE_URL, releaseObjectKey);
  const downloadURL = publicR2URL(env.TCPVIEWER_R2_PUBLIC_BASE_URL, releaseObjectKey);
  const outputDir = releaseOutputDir({ releaseType, version, buildNumber, timestamp });
  const releaseBackend = resolveReleaseBackend({ env, releaseType });

  console.log(`Preparing ${releaseType} release ${version} (${buildNumber})`);
  if (!envFileExists) {
    console.warn("No .env found; using shell environment values only.");
  }

  let releaseNote = null;
  if (releaseType === "production") {
    releaseNote = await loadReleaseNote(version);
  }

  await preflight({ env, releaseType, objectKey, settings, releaseBackend, version, buildNumber });

  printReleaseSummary({
    releaseType,
    version,
    buildNumber,
    dmgFileName,
    outputDir,
    objectKey,
    downloadURL,
    envFileExists,
    releaseNote,
    releaseBackend
  });
  if (!await askReleaseConfirmation()) {
    console.log("Release cancelled.");
    return;
  }

  await runFastlaneBuild({ env, releaseType, version, buildNumber, outputDir, dmgFileName });
  const dmgPath = path.join(outputDir, dmgFileName);
  await verifyFinalDMG({ dmgPath });
  const signature = await signDMG({ env, dmgPath, settings });
  await uploadDMGToR2({ env, objectKey, dmgPath });

  if (releaseType === "production") {
    const appcastXML = generateAppcastXML({
      version,
      buildNumber,
      downloadURL,
      signature,
      releaseNote,
      bundleId: env.TCPVIEWER_EXPECTED_BUNDLE_ID
    });
    await writeAppcastXML({ outputDir, version, appcastXML });
    if (releaseBackend) {
      await createBackendRelease({
        releaseBackend,
        title: releaseNote.title,
        version,
        buildNumber,
        downloadURL,
        appcastXML
      });
    }
  }

  console.log(`${releaseType === "production" ? "Production" : "BETA"} release is ready: ${downloadURL}`);
}

async function loadReleaseEnv() {
  const envPath = path.join(repoRoot, ".env");
  let fileEnv = {};
  let envFileExists = true;
  try {
    fileEnv = parseEnvFile(await readFile(envPath, "utf8"));
  } catch (error) {
    if (error.code !== "ENOENT") {
      throw error;
    }
    envFileExists = false;
  }

  return {
    env: mergeEnv(fileEnv, process.env),
    envFileExists
  };
}

async function preflight({ env, releaseType, objectKey, settings, releaseBackend, version, buildNumber }) {
  // Keep preflight strict because it runs before long signing and notarization work.
  const missing = missingRequiredEnv(env, requiredEnvNames(releaseType));
  if (missing.length) {
    throw new Error(`Missing required env values: ${missing.join(", ")}`);
  }

  await requireTool("node", ["--version"]);
  await requireTool("npm", ["--version"]);
  await ensureCreateDMGTool();
  await requireTool("bundle", ["exec", "fastlane", "--version"]);
  await requireTool("xcodebuild", ["-version"]);
  await requireTool("xcrun", ["notarytool", "--version"]);
  await access(path.join(repoRoot, "Vendor/.install/wireshark/lib"));

  if (settings.ENABLE_HARDENED_RUNTIME !== "YES") {
    throw new Error("TCPViewer Release build must enable hardened runtime.");
  }

  const expectedBundleId = env.TCPVIEWER_EXPECTED_BUNDLE_ID;
  if (settings.PRODUCT_BUNDLE_IDENTIFIER !== expectedBundleId) {
    throw new Error(`Unexpected bundle id ${settings.PRODUCT_BUNDLE_IDENTIFIER}; expected ${expectedBundleId}.`);
  }

  await verifyDeveloperID(env.TCPVIEWER_DEVELOPER_ID_APPLICATION);
  await findSparkleSignUpdate(env, settings);
  await ensureR2ObjectDoesNotExist(env, objectKey);
  if (releaseBackend) {
    await ensureBackendCanCreateRelease({ releaseBackend, version, buildNumber });
  }
  console.log("Pre-flight check passed.");
}

async function readXcodeBuildSettings(env) {
  const result = await runCommand("xcodebuild", [
    "-project", "TCPViewer.xcodeproj",
    "-scheme", "TCPViewer",
    "-configuration", "Release",
    "-showBuildSettings"
  ], { env, capture: true });

  return parseBuildSettings(result.stdout);
}

async function loadReleaseNote(version) {
  const releaseNotes = parseReleaseNotes(await readFile(path.join(repoRoot, "ReleaseNote.json"), "utf8"));
  return findReleaseNote(releaseNotes, version);
}

async function runFastlaneBuild({ env, releaseType, version, buildNumber, outputDir, dmgFileName }) {
  const lane = releaseType === "production" ? "build_production" : "build_beta";
  await mkdir(outputDir, { recursive: true });
  await runCommand("bundle", [
    "exec",
    "fastlane",
    "mac",
    lane,
    `version:${version}`,
    `build_number:${buildNumber}`,
    `output_dir:${outputDir}`,
    `dmg_name:${dmgFileName}`
  ], { env });
}

async function verifyFinalDMG({ dmgPath }) {
  await runCommand("codesign", ["--verify", "--strict", dmgPath]);
  await runCommand("xcrun", ["stapler", "validate", dmgPath]);
  await runCommand("spctl", [
    "-a",
    "-vv",
    "-t",
    "open",
    "--context",
    "context:primary-signature",
    dmgPath
  ]);
  console.log("Final DMG code signing and notarization checks passed.");
}

async function writeAppcastXML({ outputDir, version, appcastXML }) {
  const appcastPath = path.join(outputDir, `appcast-${version}.xml`);
  await writeFile(appcastPath, appcastXML, { mode: 0o600 });
  console.log(`Appcast XML written to: ${appcastPath}`);
}

async function signDMG({ env, dmgPath, settings }) {
  const signUpdatePath = await findSparkleSignUpdate(env, settings);
  const keyDir = await mkdtemp(path.join(tmpdir(), "tcpviewer-sparkle-"));
  const keyPath = path.join(keyDir, "ed-key");

  try {
    const privateKey = normalizeSparklePrivateKey(env.TCPVIEWER_SPARKLE_PRIVATE_ED_KEY);
    await writeFile(keyPath, `${privateKey}\n`, { mode: 0o600 });
    await chmod(keyPath, 0o600);

    let result;
    try {
      result = await runCommand(signUpdatePath, [dmgPath, "--ed-key-file", keyPath], { capture: true });
    } catch {
      result = await runCommand(signUpdatePath, [dmgPath, "-f", keyPath], { capture: true });
    }

    return parseSparkleSignatureOutput(`${result.stdout}\n${result.stderr}`);
  } finally {
    await rm(keyDir, { recursive: true, force: true });
  }
}

async function uploadDMGToR2({ env, objectKey, dmgPath }) {
  const fileStat = await stat(dmgPath);
  // R2 validates the signed payload hash, so compute it before streaming the file.
  const payloadHash = await sha256File(dmgPath);
  const url = makeR2ObjectURL({
    accountId: env.TCPVIEWER_R2_ACCOUNT_ID,
    bucket: env.TCPVIEWER_R2_BUCKET,
    objectKey
  });
  const signedHeaders = signR2Request({
    method: "PUT",
    url,
    accessKeyId: env.TCPVIEWER_R2_ACCESS_KEY_ID,
    secretAccessKey: env.TCPVIEWER_R2_SECRET_ACCESS_KEY,
    payloadHash,
    headers: {
      "content-length": String(fileStat.size),
      "content-type": "application/x-apple-diskimage"
    }
  });

  const response = await fetch(url, {
    method: "PUT",
    headers: signedHeaders,
    body: createReadStream(dmgPath),
    duplex: "half"
  });

  if (!response.ok) {
    throw new Error(`R2 upload failed for ${objectKey}: ${response.status} ${await response.text()}`);
  }
}

function resolveReleaseBackend({ env, releaseType }) {
  if (!publishReleaseToBackendEnabled(env)) {
    return null;
  }

  if (releaseType !== "production") {
    console.warn("TCPVIEWER_PUBLISH_RELEASE_TO_BACKEND is set, but backend publishing only runs for production releases.");
    return null;
  }

  const missing = missingRequiredEnv(env, releaseBackendRequiredEnvNames);
  if (missing.length) {
    throw new Error(`Missing required backend release env values: ${missing.join(", ")}`);
  }

  return {
    baseURL: normalizeReleaseBackendURL(env.TCPVIEWER_RELEASE_BACKEND_URL),
    scriptSecret: env.TCPVIEWER_RELEASE_BACKEND_SCRIPT_SECRET
  };
}

async function ensureBackendCanCreateRelease({ releaseBackend, version, buildNumber }) {
  const url = makeReleaseBackendEndpointURL({
    releaseBackend,
    pathName: "api/releases/check-can-script-release-new-build",
    query: {
      platform: releaseBackendPlatform,
      build_number: buildNumber,
      build_version: version
    }
  });

  const response = await fetch(url, {
    method: "GET",
    headers: backendReleaseHeaders(releaseBackend)
  });
  const payload = await readBackendReleaseResponse(response);

  if (!response.ok || payload?.can_release !== true) {
    throw new Error(`Backend release check failed: ${response.status} ${backendReleaseErrorMessage(payload)}`);
  }

  console.log("Backend release check passed.");
}

async function createBackendRelease({ releaseBackend, title, version, buildNumber, downloadURL, appcastXML }) {
  const url = makeReleaseBackendEndpointURL({
    releaseBackend,
    pathName: "api/releases/create-new-release",
    query: {
      platform: releaseBackendPlatform,
      build_number: buildNumber,
      build_version: version
    }
  });

  const response = await fetch(url, {
    method: "POST",
    headers: {
      ...backendReleaseHeaders(releaseBackend),
      "content-type": "application/json"
    },
    body: JSON.stringify({
      title,
      link: downloadURL,
      note: appcastXML
    })
  });
  const payload = await readBackendReleaseResponse(response);

  if (!response.ok) {
    throw new Error(`Backend release creation failed: ${response.status} ${backendReleaseErrorMessage(payload)}`);
  }

  console.log(`Backend release created for ${version} (${buildNumber}).`);
}

function makeReleaseBackendEndpointURL({ releaseBackend, pathName, query }) {
  const url = new URL(pathName, `${releaseBackend.baseURL}/`);
  for (const [name, value] of Object.entries(query)) {
    url.searchParams.set(name, value);
  }
  return url;
}

function backendReleaseHeaders(releaseBackend) {
  return {
    "x-script-secret": releaseBackend.scriptSecret
  };
}

async function readBackendReleaseResponse(response) {
  const text = await response.text();
  if (!text.trim()) {
    return null;
  }

  try {
    return JSON.parse(text);
  } catch {
    return { message: text };
  }
}

function backendReleaseErrorMessage(payload) {
  return String(payload?.message ?? payload?.error ?? "Unexpected backend response.");
}

async function ensureR2ObjectDoesNotExist(env, objectKey) {
  const url = makeR2ObjectURL({
    accountId: env.TCPVIEWER_R2_ACCOUNT_ID,
    bucket: env.TCPVIEWER_R2_BUCKET,
    objectKey
  });
  const response = await fetch(url, {
    method: "HEAD",
    headers: signR2Request({
      method: "HEAD",
      url,
      accessKeyId: env.TCPVIEWER_R2_ACCESS_KEY_ID,
      secretAccessKey: env.TCPVIEWER_R2_SECRET_ACCESS_KEY,
      payloadHash: emptyPayloadSHA256
    })
  });

  if (response.status === 404) {
    return;
  }

  if (!response.ok) {
    throw new Error(`R2 lookup failed for ${objectKey}: ${response.status} ${await response.text()}`);
  }

  throw new Error(`R2 object already exists: ${objectKey}`);
}

async function sha256File(filePath) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(filePath)) {
    hash.update(chunk);
  }
  return hash.digest("hex");
}

async function findSparkleSignUpdate(env, settings) {
  if (env.TCPVIEWER_SPARKLE_SIGN_UPDATE_PATH) {
    await access(env.TCPVIEWER_SPARKLE_SIGN_UPDATE_PATH);
    return env.TCPVIEWER_SPARKLE_SIGN_UPDATE_PATH;
  }

  const derivedDataPath = derivedDataPathFromBuildSettings(settings);
  if (!derivedDataPath) {
    throw new Error("Could not resolve TCPViewer DerivedData path. Set TCPVIEWER_SPARKLE_SIGN_UPDATE_PATH.");
  }

  const artifactPath = path.join(derivedDataPath, "SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update");
  try {
    await access(artifactPath);
    return artifactPath;
  } catch {
    // Fall through to a scoped find for alternate artifact layouts.
  }

  const result = await runCommand("/usr/bin/find", [
    derivedDataPath,
    "-path",
    "*/Sparkle/bin/sign_update",
    "-type",
    "f",
    "-print",
    "-quit"
  ], { capture: true });

  const candidate = result.stdout.trim();
  if (!candidate) {
    throw new Error("Could not find Sparkle sign_update. Build once or set TCPVIEWER_SPARKLE_SIGN_UPDATE_PATH.");
  }

  return candidate;
}

function derivedDataPathFromBuildSettings(settings) {
  const buildDir = settings?.BUILD_DIR;
  if (!buildDir) {
    return null;
  }

  const marker = `${path.sep}Build${path.sep}`;
  const markerIndex = buildDir.indexOf(marker);
  if (markerIndex === -1) {
    return null;
  }

  return buildDir.slice(0, markerIndex);
}

async function verifyDeveloperID(identity) {
  const result = await runCommand("security", ["find-identity", "-p", "codesigning", "-v"], { capture: true });
  if (!result.stdout.includes(identity)) {
    throw new Error(`Developer ID signing identity was not found: ${redactEnvValue("TCPVIEWER_DEVELOPER_ID_APPLICATION", identity)}`);
  }
}

async function requireTool(command, args) {
  try {
    await runCommand(command, args, { capture: true });
  } catch (error) {
    throw new Error(`Required release tool failed: ${command} ${args.join(" ")}\n${error.message}`);
  }
}

async function ensureCreateDMGTool() {
  const args = ["--no-install", "create-dmg", "--help"];
  try {
    await runCommand("npx", args, { capture: true });
    return;
  } catch (error) {
    if (!isNativeModuleVersionMismatch(error)) {
      throw new Error(`Required release tool failed: npx ${args.join(" ")}\n${error.message}`);
    }
  }

  console.warn("create-dmg native modules were built with a different Node.js version. Rebuilding npm modules and retrying...");
  await runCommand("npm", ["rebuild"]);

  try {
    await runCommand("npx", args, { capture: true });
  } catch (error) {
    throw new Error(`Required release tool failed after npm rebuild: npx ${args.join(" ")}\n${error.message}`);
  }
}

function isNativeModuleVersionMismatch(error) {
  const message = String(error?.message ?? "");
  return message.includes("NODE_MODULE_VERSION") || message.includes("ERR_DLOPEN_FAILED");
}

function runCommand(command, args, { env = {}, capture = false } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: repoRoot,
      env: { ...process.env, ...env },
      stdio: capture ? ["ignore", "pipe", "pipe"] : "inherit"
    });

    let stdout = "";
    let stderr = "";
    if (capture) {
      child.stdout.on("data", (chunk) => {
        stdout += chunk;
      });
      child.stderr.on("data", (chunk) => {
        stderr += chunk;
      });
    }

    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolve({ stdout, stderr });
      } else {
        reject(new Error(`${command} exited with ${code}${stderr ? `\n${stderr}` : ""}`));
      }
    });
  });
}

async function askReleaseType() {
  const response = await prompts({
    type: "select",
    name: "releaseType",
    message: "Release type",
    choices: [
      { title: "Beta", value: "beta" },
      { title: "Production", value: "production" }
    ],
    initial: 0
  });

  return requirePromptValue(response.releaseType, "Release type");
}

async function askBetaDMGCustomName(version) {
  const response = await prompts({
    type: "text",
    name: "customName",
    message: `Beta DMG custom name (tcpviewer_${version}_{custom_name}.dmg)`,
    validate: (value) => {
      try {
        makeBetaDMGFileName({ version, customName: value });
        return true;
      } catch (error) {
        return error.message;
      }
    }
  });

  return requirePromptValue(response.customName, "Beta DMG custom name");
}

async function askReleaseConfirmation() {
  const response = await prompts({
    type: "confirm",
    name: "confirmed",
    message: "Start this release now?",
    initial: false
  });

  if (typeof response.confirmed !== "boolean") {
    throw new Error("Release cancelled.");
  }
  return response.confirmed;
}

function requirePromptValue(value, label) {
  if (value === undefined) {
    throw new Error(`${label} was cancelled.`);
  }

  return value;
}

function printReleaseSummary({
  releaseType,
  version,
  buildNumber,
  dmgFileName,
  outputDir,
  objectKey,
  downloadURL,
  envFileExists,
  releaseNote,
  releaseBackend
}) {
  console.log("");
  console.log("Release summary:");
  console.log(`- Type: ${releaseType}`);
  console.log(`- App version: ${version}`);
  console.log(`- Build number: ${buildNumber}`);
  console.log(`- DMG: ${dmgFileName}`);
  console.log(`- Output directory: ${outputDir}`);
  console.log(`- R2 object: ${objectKey}`);
  console.log(`- Download URL: ${downloadURL}`);
  console.log(`- Backend publishing: ${releaseBackend ? `enabled (${releaseBackend.baseURL})` : "disabled"}`);
  console.log(`- Environment source: ${envFileExists ? ".env + shell environment" : "shell environment only"}`);
  if (releaseNote) {
    console.log(`- Release notes: ReleaseNote.json entry ${releaseNote.version}`);
    console.log(`- Release title: ${releaseNote.title}`);
  }
}

function validateRequiredBuildSettings(settings) {
  const requiredSettings = ["MARKETING_VERSION", "CURRENT_PROJECT_VERSION"];
  const missing = requiredSettings.filter((name) => !String(settings[name] ?? "").trim());
  if (missing.length) {
    throw new Error(`Missing required Xcode build settings: ${missing.join(", ")}`);
  }
}

function parseArgs(argv) {
  const args = {};
  for (const arg of argv) {
    if (arg.startsWith("--type=")) {
      args.type = arg.slice("--type=".length).toLowerCase();
    } else if (arg.startsWith("--beta-name=")) {
      args.betaName = arg.slice("--beta-name=".length);
    }
  }
  return args;
}

function releaseOutputDir({ releaseType, version, buildNumber, timestamp }) {
  const folder = releaseType === "production"
    ? `production/${version}-${buildNumber}`
    : `beta/${version}-${buildNumber}-${timestamp}`;
  return path.join(homedir(), "Desktop", "tcpviewer-production", folder);
}

function makeTimestamp(date = new Date()) {
  return date.toISOString().replaceAll(/[-:]/g, "").replace(/\..+$/, "Z");
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
