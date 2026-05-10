#!/usr/bin/env node

import { createReadStream } from "node:fs";
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
import readline from "node:readline/promises";
import {
  backendCheckURL,
  backendCreateURL,
  findReleaseNote,
  generateAppcastXML,
  makeR2ObjectKey,
  mergeEnv,
  missingRequiredEnv,
  nextBuildNumber,
  parseBuildSettings,
  parseEnvFile,
  parseReleaseNotes,
  parseSparkleSignatureOutput,
  productionBundleId,
  publicR2URL,
  redactEnvValue,
  requiredEnvNames,
  updateProjectVersions
} from "./release-lib.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const releaseType = args.type ?? await askReleaseType();
  if (!["beta", "production"].includes(releaseType)) {
    throw new Error("Release type must be beta or production.");
  }

  const { env, envFileExists } = await loadReleaseEnv();
  const settings = await readXcodeBuildSettings(env);
  const currentVersion = settings.MARKETING_VERSION;
  const currentBuildNumber = settings.CURRENT_PROJECT_VERSION;
  const timestamp = makeTimestamp();
  const version = releaseType === "production"
    ? args.version ?? await askText("Next production version: ")
    : currentVersion;
  const buildNumber = releaseType === "production"
    ? nextBuildNumber(currentBuildNumber)
    : currentBuildNumber;
  const objectKey = makeR2ObjectKey({ releaseType, version, buildNumber, timestamp });
  const downloadURL = publicR2URL(env.TCPVIEWER_R2_PUBLIC_BASE_URL, objectKey);
  const outputDir = releaseOutputDir({ releaseType, version, buildNumber, timestamp });

  console.log(`Preparing ${releaseType} release ${version} (${buildNumber})`);
  if (!envFileExists) {
    console.warn("No .env found; using shell environment values only.");
  }
  await preflight({ env, releaseType, objectKey, settings });

  let releaseNote = null;
  if (releaseType === "production") {
    releaseNote = await loadReleaseNote(version);
    await updateXcodeProjectVersion({ version, buildNumber });
    await checkBackendReleaseEligibility(env, { version, buildNumber });
  }

  await runFastlaneBuild({ env, version, buildNumber, outputDir });
  const dmgPath = path.join(outputDir, "tcpviewer.dmg");
  const signature = await signDMG({ env, dmgPath, settings });
  await uploadDMGToR2({ env, objectKey, dmgPath });

  if (releaseType === "production") {
    const appcastXML = generateAppcastXML({
      version,
      buildNumber,
      downloadURL,
      signature,
      releaseNote,
      bundleId: env.TCPVIEWER_EXPECTED_BUNDLE_ID || productionBundleId
    });
    await createBackendRelease(env, { version, buildNumber, downloadURL, appcastXML });
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

async function preflight({ env, releaseType, objectKey, settings }) {
  // Keep preflight strict because it runs before long signing and notarization work.
  const missing = missingRequiredEnv(env, requiredEnvNames(releaseType));
  if (missing.length) {
    throw new Error(`Missing required env values: ${missing.join(", ")}`);
  }

  await requireTool("node", ["--version"]);
  await requireTool("npm", ["--version"]);
  await requireTool("bundle", ["exec", "fastlane", "--version"]);
  await requireTool("xcodebuild", ["-version"]);
  await requireTool("xcrun", ["notarytool", "--version"]);
  await access(path.join(repoRoot, "Vendor/.install/wireshark/lib"));

  if (settings.ENABLE_HARDENED_RUNTIME !== "YES") {
    throw new Error("TCPViewer Release build must enable hardened runtime.");
  }

  const expectedBundleId = env.TCPVIEWER_EXPECTED_BUNDLE_ID || productionBundleId;
  if (settings.PRODUCT_BUNDLE_IDENTIFIER !== expectedBundleId) {
    throw new Error(`Unexpected bundle id ${settings.PRODUCT_BUNDLE_IDENTIFIER}; expected ${expectedBundleId}.`);
  }

  await verifyDeveloperID(env.TCPVIEWER_DEVELOPER_ID_APPLICATION);
  await findSparkleSignUpdate(env, settings);
  await ensureR2ObjectDoesNotExist(env, objectKey);
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

async function updateXcodeProjectVersion({ version, buildNumber }) {
  const projectPath = path.join(repoRoot, "TCPViewer.xcodeproj/project.pbxproj");
  const current = await readFile(projectPath, "utf8");
  const updated = updateProjectVersions(current, { version, buildNumber });
  if (updated !== current) {
    await writeFile(projectPath, updated);
  }
}

async function loadReleaseNote(version) {
  const releaseNotes = parseReleaseNotes(await readFile(path.join(repoRoot, "ReleaseNote.json"), "utf8"));
  return findReleaseNote(releaseNotes, version);
}

async function checkBackendReleaseEligibility(env, { version, buildNumber }) {
  const response = await fetch(backendCheckURL(env.TCPVIEWER_BACKEND_URL, { version, buildNumber }), {
    headers: {
      "x-script-secret": env.TCPVIEWER_SCRIPT_SECRET
    }
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Backend rejected release ${version} (${buildNumber}): ${body}`);
  }
}

async function createBackendRelease(env, { version, buildNumber, downloadURL, appcastXML }) {
  const response = await fetch(backendCreateURL(env.TCPVIEWER_BACKEND_URL, { version, buildNumber }), {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-script-secret": env.TCPVIEWER_SCRIPT_SECRET
    },
    body: JSON.stringify({
      link: downloadURL,
      note: appcastXML
    })
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Backend failed to create release ${version} (${buildNumber}): ${body}`);
  }
}

async function runFastlaneBuild({ env, version, buildNumber, outputDir }) {
  await mkdir(outputDir, { recursive: true });
  await runCommand("bundle", [
    "exec",
    "fastlane",
    "mac",
    "build_release",
    `version:${version}`,
    `build_number:${buildNumber}`,
    `output_dir:${outputDir}`
  ], { env });
}

async function signDMG({ env, dmgPath, settings }) {
  const signUpdatePath = await findSparkleSignUpdate(env, settings);
  const keyDir = await mkdtemp(path.join(tmpdir(), "tcpviewer-sparkle-"));
  const keyPath = path.join(keyDir, "ed-key");

  try {
    await writeFile(keyPath, `${env.TCPVIEWER_SPARKLE_PRIVATE_ED_KEY.trim()}\n`, { mode: 0o600 });
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
  const { S3Client, PutObjectCommand } = await import("@aws-sdk/client-s3");
  const client = makeR2Client(S3Client, env);
  const fileStat = await stat(dmgPath);

  await client.send(new PutObjectCommand({
    Bucket: env.TCPVIEWER_R2_BUCKET,
    Key: objectKey,
    Body: createReadStream(dmgPath),
    ContentLength: fileStat.size,
    ContentType: "application/x-apple-diskimage"
  }));
}

async function ensureR2ObjectDoesNotExist(env, objectKey) {
  const { S3Client, HeadObjectCommand } = await import("@aws-sdk/client-s3");
  const client = makeR2Client(S3Client, env);

  try {
    await client.send(new HeadObjectCommand({
      Bucket: env.TCPVIEWER_R2_BUCKET,
      Key: objectKey
    }));
  } catch (error) {
    const statusCode = error?.$metadata?.httpStatusCode;
    if (statusCode === 404 || error?.name === "NotFound") {
      return;
    }
    throw error;
  }

  throw new Error(`R2 object already exists: ${objectKey}`);
}

function makeR2Client(S3Client, env) {
  return new S3Client({
    region: "auto",
    endpoint: `https://${env.TCPVIEWER_R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
    credentials: {
      accessKeyId: env.TCPVIEWER_R2_ACCESS_KEY_ID,
      secretAccessKey: env.TCPVIEWER_R2_SECRET_ACCESS_KEY
    }
  });
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
  const answer = (await askText("Release type (beta/production): ")).trim().toLowerCase();
  if (answer === "b" || answer === "beta") {
    return "beta";
  }
  if (answer === "p" || answer === "production") {
    return "production";
  }

  throw new Error("Please choose beta or production.");
}

async function askText(prompt) {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
  });

  try {
    return await rl.question(prompt);
  } finally {
    rl.close();
  }
}

function parseArgs(argv) {
  const args = {};
  for (const arg of argv) {
    if (arg.startsWith("--type=")) {
      args.type = arg.slice("--type=".length).toLowerCase();
    } else if (arg.startsWith("--version=")) {
      args.version = arg.slice("--version=".length);
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
