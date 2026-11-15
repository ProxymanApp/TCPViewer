#!/usr/bin/env node

import { createReadStream, createWriteStream } from "node:fs";
import { createHash } from "node:crypto";
import {
  access,
  chmod,
  copyFile,
  mkdtemp,
  mkdir,
  readFile,
  rm,
  stat,
  statfs,
  writeFile
} from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import prompts from "prompts";
import {
  describeFetchError,
  emptyPayloadSHA256,
  findDeveloperIDIdentity,
  generateAppcastXML,
  githubRepoFromRemoteURL,
  homebrewCaskToken,
  isRetryableHTTPStatus,
  makeHomebrewCaskAuditArgs,
  makeHomebrewCaskBranchName,
  makeHomebrewCaskPullRequestBody,
  makeGitHubReleaseTagName,
  makeBetaDMGFileName,
  makeDMGFileName,
  makeR2ObjectURL,
  makeR2ObjectKey,
  makeR2StorageObjectKey,
  mergeEnv,
  minimumSystemVersion,
  missingRequiredEnv,
  nextBuildNumberProblem,
  nextReleaseDefaults,
  nextVersionProblem,
  normalizeReleaseBackendURL,
  normalizeSparklePrivateKey,
  parseBuildSettings,
  parseEnvFile,
  parseReleaseNotes,
  parseSparkleSignatureOutput,
  publicR2URL,
  publishReleaseToBackendEnabled,
  releaseBackendRequiredEnvNames,
  releaseNotesToMarkdown,
  resolvePublishedGitHubReleaseArtifact,
  resolveSentryURL,
  requiredEnvNames,
  setAppVersionInProject,
  signR2Request,
  sparklePublicKeyFromPrivateKey,
  updateHomebrewCaskContent,
  validateHomebrewCaskContent,
  validateHomebrewLivecheckOutput
} from "./release-lib.mjs";
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
} from "./release-notes.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");
const releaseRootDir = path.join(homedir(), "Desktop", "tcpviewer-production");
const projectFileRelativePath = "TCPViewer.xcodeproj/project.pbxproj";
const releaseNotesFileName = "ReleaseNote.json";
const releaseNotesPromptPath = path.join(__dirname, "release-notes-prompt.md");
const releaseNotesWriterTimeoutMs = 180_000;
const vsCodeAppCLIPath = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code";
const minimumFreeDiskGB = 10;
const useColor = process.stdout.isTTY;
const releaseBackendPlatform = "macos";
const r2UploadMaxAttempts = 3;
const r2UploadConfirmationAttempts = 3;
const r2UploadAttemptTimeoutMs = 300_000;
const r2UploadConfirmationTimeoutMs = 30_000;
const homebrewCaskForkRepo = "ProxymanApp/homebrew-cask";
const homebrewCaskUpstreamRepo = "Homebrew/homebrew-cask";
const homebrewCaskUpstreamRemote = "origin";
const homebrewCaskForkRemote = "proxyman";
const homebrewCaskDefaultBranch = "main";
const homebrewCaskRelativePath = `Casks/t/${homebrewCaskToken}.rb`;
const homebrewPullRequestTemplateRelativePath = ".github/PULL_REQUEST_TEMPLATE.md";
const homebrewCaskTemplatePath = path.join(repoRoot, `scripts/homebrew/${homebrewCaskToken}.rb`);
const githubReleaseRepo = "ProxymanApp/TCPViewer";

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.homebrewOnly) {
    await createHomebrewPullRequestForExistingRelease(args);
    return;
  }

  const releaseType = args.type ?? await askReleaseType();
  if (!["beta", "production"].includes(releaseType)) {
    throw new Error("Release type must be beta or production.");
  }
  if (releaseType === "production") {
    assertInteractiveProductionRelease(args);
  }

  const { env, envFileExists } = await loadReleaseEnv();
  if (!envFileExists) {
    console.warn("No .env found; using shell environment values only.");
  }
  // Pin sentry-cli to the self-hosted server before fastlane inherits this env.
  env.SENTRY_URL = resolveSentryURL(env);
  const settings = await readXcodeBuildSettings(env);
  validateRequiredBuildSettings(settings);
  const releaseBackend = resolveReleaseBackend({ env, releaseType });
  const { githubRepo, latestRelease } = await preflight({ env, settings, releaseType });

  const target = releaseType === "production"
    ? await prepareProductionRelease({ env, githubRepo, latestRelease, releaseBackend, settings })
    : await prepareBetaRelease({ env, settings, args });
  if (!target) {
    return;
  }

  const { version, buildNumber, outputDir, dmgFileName, objectKey, downloadURL } = target;
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
      releaseNote: target.releaseNote,
      bundleId: env.TCPVIEWER_EXPECTED_BUNDLE_ID
    });
    await writeAppcastXML({ outputDir, version, appcastXML });
    if (releaseBackend) {
      await createBackendRelease({
        releaseBackend,
        title: target.releaseNote.title,
        version,
        buildNumber,
        downloadURL,
        appcastXML
      });
    }
    await createGitHubRelease({
      githubRelease: target.githubRelease,
      releaseNote: target.releaseNote,
      dmgPath,
      outputDir
    });
    console.log("Homebrew Cask: run make homebrew to open its pull request for this release.");
  }

  console.log(`${releaseType === "production" ? "Production" : "BETA"} release is ready: ${downloadURL}`);
}

// A production release asks its version and notes at the keyboard, so it never runs unattended.
function assertInteractiveProductionRelease(args) {
  if (args.yes) {
    throw new Error("A production release asks for its version and release notes: run it without --yes.");
  }
  if (!process.stdin.isTTY) {
    throw new Error("A production release asks for its version and release notes: run make production in a terminal.");
  }
}

// Name the beta DMG, check nothing is on R2 under it yet, and confirm before building the project's version.
async function prepareBetaRelease({ env, settings, args }) {
  const version = settings.MARKETING_VERSION;
  const buildNumber = settings.CURRENT_PROJECT_VERSION;
  const betaName = args.betaName ?? await askBetaDMGCustomName(version, buildNumber);
  const target = makeReleaseTarget({ env, releaseType: "beta", version, buildNumber, betaName });

  printStep(`BETA ${version} (${buildNumber})`);
  const checklist = await checkReleaseTarget({ env, target });
  checklist.stopOnFailures("Release check", "Nothing was built.");
  printReleaseSummary({ env, target, releaseBackend: null });
  if (!args.yes && !await askReleaseConfirmation()) {
    console.log("Release cancelled.");
    return null;
  }
  return target;
}

// Ask the version, draft and review the notes, then commit and push them; YES on the notes is the last question.
async function prepareProductionRelease({ env, githubRepo, latestRelease, releaseBackend, settings }) {
  const target = await askNextRelease({ env, settings, latestRelease, githubRepo, releaseBackend });
  printReleaseSummary({ env, target, releaseBackend });

  const releaseNote = await prepareReleaseNotes({ target, sinceTag: latestRelease.tagName });
  target.releaseNote = releaseNote;
  target.githubRelease.title = releaseNote.title;
  await commitAndPushNextVersion({ env, target, githubRepo });

  // Minutes can pass while the notes are edited, so check again right before the long build.
  printStep("Before building: check again");
  const checklist = await checkReleaseTarget({ env, target, githubRepo, releaseBackend });
  await checklist.check(`${githubRepo.defaultBranch} is pushed and matches origin`, async () => {
    await ensureGitReadyForProductionRelease(githubRepo.defaultBranch);
  });
  checklist.stopOnFailures(
    "Before building",
    `${githubRepo.defaultBranch} has Bump ${target.version}: fix the checks marked ✗, then run make production again with the same version.`
  );
  return target;
}

// Name the DMG, its R2 object, download URL, output folder and GitHub release for one build.
function makeReleaseTarget({ env, releaseType, version, buildNumber, betaName = null, githubRepo = null }) {
  const timestamp = makeTimestamp();
  const dmgFileName = releaseType === "beta"
    ? makeBetaDMGFileName({ version, buildNumber, customName: betaName })
    : makeDMGFileName({ version, buildNumber });
  const releaseObjectKey = makeR2ObjectKey({ releaseType, version, buildNumber, timestamp, fileName: dmgFileName });
  return {
    releaseType,
    version,
    buildNumber,
    dmgFileName,
    objectKey: makeR2StorageObjectKey(env.TCPVIEWER_R2_PUBLIC_BASE_URL, releaseObjectKey),
    downloadURL: publicR2URL(env.TCPVIEWER_R2_PUBLIC_BASE_URL, releaseObjectKey),
    outputDir: releaseOutputDir({ releaseType, version, buildNumber, timestamp }),
    releaseNote: null,
    githubRelease: releaseType === "production"
      ? { tagName: makeGitHubReleaseTagName(version), title: null, repo: githubRepo?.nameWithOwner ?? githubReleaseRepo }
      : null
  };
}

// Ask the version and build number, defaulting to the next release, until nothing is published under them yet.
async function askNextRelease({ env, settings, latestRelease, githubRepo, releaseBackend }) {
  let defaults = nextReleaseDefaults({
    projectVersion: settings.MARKETING_VERSION,
    projectBuild: settings.CURRENT_PROJECT_VERSION,
    latestVersion: latestRelease.version,
    latestBuild: latestRelease.buildNumber
  });
  printStep(
    `Next release (published: ${latestRelease.version} (${latestRelease.buildNumber}); `
    + `project: ${settings.MARKETING_VERSION} (${settings.CURRENT_PROJECT_VERSION}))`
  );

  for (;;) {
    const version = await askText("Version", defaults.version, (value) => {
      return nextVersionProblem(value, latestRelease.version);
    });
    const buildNumber = await askText("Build number", defaults.buildNumber, (value) => {
      return nextBuildNumberProblem(value, latestRelease.buildNumber);
    });
    const target = makeReleaseTarget({ env, releaseType: "production", version, buildNumber, githubRepo });
    const checklist = await checkReleaseTarget({ env, target, githubRepo, releaseBackend });
    if (checklist.failures === 0) {
      return target;
    }

    console.log("  Choose another version or build number.");
    defaults = { version, buildNumber };
  }
}

// Check nothing is published under this release yet, so a release never replaces an existing one.
async function checkReleaseTarget({ env, target, githubRepo = null, releaseBackend = null }) {
  const checklist = createChecklist();
  const { githubRelease, version, buildNumber } = target;
  if (githubRelease) {
    await checklist.check(`Tag ${githubRelease.tagName} is free here and on origin`, async () => {
      await ensureGitHubTagDoesNotExist(githubRelease.tagName);
    });
    await checklist.check(`No GitHub release ${githubRelease.tagName} yet`, async () => {
      await ensureGitHubReleaseDoesNotExist({ tagName: githubRelease.tagName, repo: githubRepo.nameWithOwner });
    });
  }
  await checklist.check(`Nothing on R2 at ${target.objectKey} yet`, async () => {
    await ensureR2ObjectDoesNotExist(env, target.objectKey);
  });
  if (releaseBackend) {
    await checklist.check(`Release backend accepts ${version} (${buildNumber})`, async () => {
      await ensureBackendCanCreateRelease({ releaseBackend, version, buildNumber });
    });
  }
  return checklist;
}

// Draft the notes (or reuse an earlier draft), then show them until the answer is YES, an edit, or a cancel.
async function prepareReleaseNotes({ target, sinceTag }) {
  const { version } = target;
  const draftPath = path.join(releaseRootDir, "release-notes", `${version}.md`);
  await mkdir(path.dirname(draftPath), { recursive: true });
  if (await fileExists(draftPath)) {
    printStep(`Release notes: ${draftPath} (kept from an earlier run; delete it to draft them again)`);
  } else {
    await writeFile(draftPath, await draftReleaseNotes({ version, sinceTag }), { mode: 0o600 });
  }

  for (;;) {
    const text = await readFile(draftPath, "utf8");
    console.log("");
    console.log(text.trimEnd().split("\n").map((line) => `  │ ${line}`).join("\n"));
    console.log("");

    let releaseNote = null;
    try {
      releaseNote = parseReleaseNotesMarkdown(text, version);
    } catch (error) {
      console.log(`  ${paint("31", `✗ ${error.message}`)}`);
    }
    if (releaseNote) {
      console.log(`  ${paint("1", "YES")}  release with these notes: commit "Bump ${version}" (version, build number and`);
      console.log(`       ${releaseNotesFileName}), push it, then build, notarize, upload and publish ${version} (${target.buildNumber})`);
      console.log("       without asking again");
    }
    console.log(`  ${paint("1", "c")}    edit them in VS Code (save, then close the tab to come back here)`);
    console.log(`  ${paint("1", "n")}    cancel (nothing is changed; the draft stays at ${draftPath})`);

    const answer = (await askText(releaseNote ? "YES, c or n" : "c or n", "", () => null)).toLowerCase();
    if (answer === "yes" && releaseNote) {
      return releaseNote;
    }
    if (answer === "c") {
      await editInVSCode(draftPath);
    } else if (answer === "n") {
      throw new Error("Release cancelled: nothing was committed or built.");
    }
  }
}

// Seed the draft from ReleaseNote.json when the version already has an entry, else write it from main's history.
async function draftReleaseNotes({ version, sinceTag }) {
  const releaseNotes = parseReleaseNotes(await readFile(path.join(repoRoot, releaseNotesFileName), "utf8"));
  const existing = releaseNotes.releases.find((release) => release.version === version);
  if (existing) {
    printStep(`Release notes: from ${releaseNotesFileName}'s ${version} entry`);
    return releaseNoteToDraftMarkdown(existing);
  }

  const log = await runCommand("git", [
    "log",
    "--first-parent",
    "--name-only",
    `--format=${gitChangesLogFormat}`,
    `${sinceTag}..HEAD`
  ], { capture: true });
  const changes = shippedChanges(parseGitChanges(log.stdout));
  printStep(`Release notes: ${changes.length} app change(s) on main since ${sinceTag}`);
  for (const change of changes) {
    console.log(`  · ${change.title}`);
  }
  if (!changes.length) {
    return emptyReleaseNotesDraft(version);
  }

  console.log("  Claude Code is writing them in plain words…");
  try {
    const request = makeReleaseNotesRequest({
      prompt: await readFile(releaseNotesPromptPath, "utf8"),
      version,
      changes
    });
    // No tools, no MCP servers, and outside the repo: only the commit text above reaches the writer.
    const answer = await runCommand("claude", [
      "-p",
      "--tools",
      "",
      "--strict-mcp-config",
      "--no-session-persistence"
    ], {
      cwd: tmpdir(),
      baseEnv: await toolEnvWithoutReleaseSecrets(),
      input: request,
      capture: true,
      timeoutMs: releaseNotesWriterTimeoutMs
    });
    const markdown = extractReleaseNotesAnswer(answer.stdout);
    if (markdown) {
      return markdown;
    }
    console.warn("  Claude Code's answer had no notes: the draft lists the commit titles to rewrite.");
  } catch (error) {
    console.warn(`  Claude Code didn't write them (${firstLine(error.message)}): the draft lists the commit titles to rewrite.`);
  }
  return fallbackReleaseNotesDraft(version, changes);
}

// Open a file in VS Code and wait until its tab is closed.
async function editInVSCode(filePath) {
  const baseEnv = await toolEnvWithoutReleaseSecrets();
  for (const command of ["code", vsCodeAppCLIPath]) {
    try {
      await runCommand(command, ["--wait", filePath], { baseEnv });
      return;
    } catch (error) {
      if (error.code !== "ENOENT") {
        console.log(`  ${paint("31", `✗ ${firstLine(error.message)}`)}`);
        return;
      }
    }
  }
  console.log(`  ${paint("31", "✗ VS Code's code command was not found: in VS Code, run Shell Command: Install 'code' command in PATH.")}`);
}

// Write the version and notes, commit them as "Bump <version>" and push, so the release tag points at them.
async function commitAndPushNextVersion({ env, target, githubRepo }) {
  const { version, buildNumber, releaseNote } = target;
  const branch = githubRepo.defaultBranch;
  const files = [projectFileRelativePath, releaseNotesFileName];
  const projectPath = path.join(repoRoot, projectFileRelativePath);
  const releaseNotesPath = path.join(repoRoot, releaseNotesFileName);
  printStep(`Commit Bump ${version} and push ${branch}`);

  await writeFile(projectPath, setAppVersionInProject(await readFile(projectPath, "utf8"), {
    bundleId: env.TCPVIEWER_EXPECTED_BUNDLE_ID,
    version,
    buildNumber
  }));
  await writeFile(releaseNotesPath, upsertReleaseNote(await readFile(releaseNotesPath, "utf8"), releaseNote));
  try {
    const settings = await readXcodeBuildSettings(env);
    if (settings.MARKETING_VERSION !== version || settings.CURRENT_PROJECT_VERSION !== buildNumber) {
      throw new Error(
        `Xcode reads ${settings.MARKETING_VERSION} (${settings.CURRENT_PROJECT_VERSION}) after the update, `
        + `not ${version} (${buildNumber}).`
      );
    }
  } catch (error) {
    await runCommand("git", ["checkout", "HEAD", "--", ...files], { capture: true });
    throw new Error(`${error.message}\nThe project and ${releaseNotesFileName} are back as committed.`);
  }

  if (await gitHasChanges(files)) {
    await runCommand("git", ["commit", "--quiet", "-m", `Bump ${version}`, "--", ...files]);
    console.log(`  ${paint("32", "✓")} Committed Bump ${version}`);
  } else {
    console.log(`  ${paint("32", "✓")} ${branch} already has ${version} (${buildNumber}) and its notes`);
  }

  try {
    await runCommand("git", ["push", "--quiet", "origin", `HEAD:refs/heads/${branch}`]);
  } catch (error) {
    throw new Error(
      `Pushing ${branch} failed: ${firstLine(error.message)}\nThe commit is kept here: push it `
      + `(git pull --rebase first if ${branch} moved), then run make production again with the same version.`
    );
  }
  console.log(`  ${paint("32", "✓")} Pushed ${branch}`);
}

async function gitHasChanges(files) {
  try {
    await runCommand("git", ["diff", "--quiet", "HEAD", "--", ...files], { capture: true });
    return false;
  } catch {
    return true;
  }
}

// Submit an already published production DMG without recreating any release records.
async function createHomebrewPullRequestForExistingRelease(args) {
  if (args.type && args.type !== "production") {
    throw new Error("--homebrew-only supports production releases only.");
  }

  const { env, envFileExists } = await loadReleaseEnv();
  const missing = missingRequiredEnv(env, ["TCPVIEWER_R2_PUBLIC_BASE_URL"]);
  if (missing.length) {
    throw new Error(`Missing required env values: ${missing.join(", ")}`);
  }

  const githubRelease = await loadLatestPublishedGitHubRelease();
  const { version, buildNumber, dmgFileName } = githubRelease.asset;
  const objectKey = makeR2ObjectKey({
    releaseType: "production",
    version,
    buildNumber,
    fileName: dmgFileName
  });
  const downloadURL = publicR2URL(env.TCPVIEWER_R2_PUBLIC_BASE_URL, objectKey);
  const homebrewRelease = resolveHomebrewRelease({ env, version, buildNumber });

  console.log("");
  console.log("Homebrew release summary:");
  console.log(`- App version: ${version}`);
  console.log(`- Build number: ${buildNumber}`);
  console.log(`- Existing GitHub release: ${githubRelease.repo} ${githubRelease.tagName}`);
  console.log(`- Existing DMG: ${downloadURL}`);
  console.log(`- Environment source: ${envFileExists ? ".env + shell environment" : "shell environment only"}`);
  console.log(`- Fork branch: ${homebrewCaskForkRepo}:${homebrewRelease.branchName}`);
  console.log(`- Pull request target: ${homebrewCaskUpstreamRepo}:${homebrewCaskDefaultBranch}`);
  if (!args.yes && !await askHomebrewReleaseConfirmation()) {
    console.log("Homebrew release cancelled.");
    return;
  }

  await preflightHomebrewRelease(homebrewRelease);
  if (
    homebrewRelease.isInitialCask
    && args.yes
    && args.homebrewInstallTested !== true
  ) {
    throw new Error(
      "Non-interactive initial Homebrew Cask publishing requires --homebrew-install-tested. "
      + "Use an interactive release to pause and run the required install and uninstall checks."
    );
  }

  const temporaryDirectory = await mkdtemp(path.join(tmpdir(), "tcpviewer-homebrew-"));
  const dmgPath = path.join(temporaryDirectory, dmgFileName);
  try {
    await downloadPublishedDMG({ downloadURL, dmgPath, expectedAsset: githubRelease.asset });
    await verifyFinalDMG({ dmgPath });
    await createHomebrewCaskPullRequest({
      homebrewRelease,
      dmgPath,
      installTested: args.homebrewInstallTested === true,
      nonInteractive: args.yes === true
    });
  } finally {
    await rm(temporaryDirectory, { recursive: true, force: true });
  }

  console.log(`Homebrew Cask pull request is ready for ${version} (${buildNumber}).`);
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

// Check every tool, credential and service a release needs before it asks anything or builds, and report every
// problem at once. Labels and messages never include .env values: release logs may be shared publicly.
async function preflight({ env, settings, releaseType }) {
  const checklist = createChecklist();
  const result = { githubRepo: null, latestRelease: null };

  printStep("Pre-flight: .env and app settings");
  const envReady = await checklist.check("Release values in .env", async () => {
    const missing = missingRequiredEnv(env, requiredEnvNames(releaseType));
    if (missing.length) {
      throw new Error(`Missing: ${missing.join(", ")}`);
    }
  });
  await checklist.check("Release build enables the hardened runtime", async () => {
    if (settings.ENABLE_HARDENED_RUNTIME !== "YES") {
      throw new Error("Set ENABLE_HARDENED_RUNTIME = YES for the TCPViewer Release configuration.");
    }
  });
  await checklist.check(`Bundle id ${settings.PRODUCT_BUNDLE_IDENTIFIER} matches TCPVIEWER_EXPECTED_BUNDLE_ID`, async () => {
    if (settings.PRODUCT_BUNDLE_IDENTIFIER !== env.TCPVIEWER_EXPECTED_BUNDLE_ID) {
      throw new Error("The Release build's PRODUCT_BUNDLE_IDENTIFIER differs from TCPVIEWER_EXPECTED_BUNDLE_ID.");
    }
  });
  await checklist.check("Release build uses the remote license server", async () => {
    if (settings.TCPVIEWER_USES_LOCAL_LICENSE_SERVER !== "false") {
      throw new Error("TCPVIEWER_USES_LOCAL_LICENSE_SERVER must be false for Release builds.");
    }
  });
  await checklist.check(`Wireshark runtime in Vendor/.install runs on macOS ${minimumSystemVersion}`, async () => {
    await access(path.join(repoRoot, "Vendor/.install/wireshark/lib"));
    await access(path.join(repoRoot, "Vendor/.install/wireshark-deps/lib"));
    await requireTool(path.join(repoRoot, "scripts/verify-bundled-runtime-compatibility.sh"), [
      path.join(repoRoot, "Vendor/.install/wireshark-deps"),
      minimumSystemVersion,
      "--allow-prefix",
      path.join(repoRoot, "Vendor/.install/wireshark-deps")
    ]);
  });

  printStep("Pre-flight: tools");
  await checklist.check("Xcode", async () => {
    return firstLine((await runCommand("xcodebuild", ["-version"], { capture: true })).stdout);
  });
  await checklist.check("git, gh, curl, codesign, spctl and sentry-cli", async () => {
    await requireCommands(["git", "gh", "curl", "codesign", "spctl", "sentry-cli"]);
  });
  await checklist.check("notarytool and stapler", async () => {
    await requireTool("xcrun", ["--find", "notarytool"]);
    await requireTool("xcrun", ["--find", "stapler"]);
  });
  await checklist.check("fastlane (bundle exec)", async () => {
    try {
      await runCommand("bundle", ["exec", "fastlane", "--version"], { capture: true });
    } catch (error) {
      throw new Error(`Run bundle install in a shell with your Ruby manager loaded.\n${firstLine(error.message.split("\n")[1] ?? error.message)}`);
    }
  });
  await checklist.check("create-dmg", ensureCreateDMGTool);
  await checklist.check(`At least ${minimumFreeDiskGB} GB free for the build`, ensureFreeDiskSpace);
  if (!envReady) {
    checklist.stopOnFailures("Pre-flight", "Fill in .env from .env.example, then run it again. Nothing was changed or built.");
  }

  printStep("Pre-flight: signing and notarization");
  let identityHash = null;
  await checklist.check("One Developer ID Application identity for the team in the keychain", async () => {
    const output = await runCommand("security", ["find-identity", "-p", "codesigning", "-v"], { capture: true });
    identityHash = findDeveloperIDIdentity(output.stdout, {
      identity: env.TCPVIEWER_DEVELOPER_ID_APPLICATION,
      teamId: env.TCPVIEWER_DEVELOPMENT_TEAM
    });
  });
  if (identityHash) {
    await checklist.check("Test signature with a secure timestamp", () => testSignature(identityHash));
  }
  await checklist.check("Apple accepts the notarization credentials", () => checkNotarizationCredentials(env));

  printStep("Pre-flight: Sparkle updates");
  await checklist.check("Sparkle sign_update", async () => {
    await findSparkleSignUpdate(env, settings);
  });
  await checklist.check("Sparkle private key matches the app's SUPublicEDKey", async () => {
    const appKey = String(settings.TCPVIEWER_SPARKLE_PUBLIC_ED_KEY ?? "").trim();
    if (!appKey) {
      throw new Error("The Release build has no TCPVIEWER_SPARKLE_PUBLIC_ED_KEY (Config/TCPViewer.local.xcconfig).");
    }
    if (sparklePublicKeyFromPrivateKey(env.TCPVIEWER_SPARKLE_PRIVATE_ED_KEY) !== appKey) {
      throw new Error("TCPVIEWER_SPARKLE_PRIVATE_ED_KEY doesn't belong to the app's SUPublicEDKey: installed apps would reject the update.");
    }
  });

  printStep("Pre-flight: uploads");
  await checklist.check(`Sentry accepts the auth token (${env.SENTRY_URL})`, () => checkSentryAuth(env));
  await checklist.check("R2 accepts the upload credentials", async () => {
    // A HEAD on a key that never exists answers 404 with good credentials and 401/403 with bad ones.
    await ensureR2ObjectDoesNotExist(env, makeR2StorageObjectKey(env.TCPVIEWER_R2_PUBLIC_BASE_URL, "preflight/missing.dmg"));
  });

  if (releaseType === "production") {
    printStep("Pre-flight: GitHub");
    await checklist.check("gh is signed in", async () => {
      await requireTool("gh", ["auth", "status"]);
    });
    await checklist.check("On the default branch, clean and in sync with origin", async () => {
      const repo = await resolveGitHubRepo();
      await runCommand("git", ["fetch", "origin", "--tags", "--prune"], { capture: true });
      await ensureGitReadyForProductionRelease(repo.defaultBranch);
      result.githubRepo = repo;
      return `${repo.defaultBranch} at ${firstLine((await runCommand("git", ["log", "-1", "--format=%h %s"], { capture: true })).stdout)}`;
    });
    await checklist.check("Latest published release on GitHub", async () => {
      result.latestRelease = (await loadLatestPublishedGitHubRelease()).asset;
      return `${result.latestRelease.version} (${result.latestRelease.buildNumber})`;
    });
  }

  checklist.stopOnFailures("Pre-flight", "Nothing was changed or built.");
  console.log(paint("32", "\nPre-flight passed."));
  return result;
}

// Sign a scratch copy of /usr/bin/true: proves the signing key works (a keychain prompt shows up now, not mid-build)
// and Apple's timestamp server answers.
async function testSignature(identityHash) {
  const directory = await mkdtemp(path.join(tmpdir(), "tcpviewer-signing-"));
  try {
    const probePath = path.join(directory, "probe");
    await copyFile("/usr/bin/true", probePath);
    await runCommand("codesign", ["--force", "--sign", identityHash, "--timestamp", "--options", "runtime", probePath], {
      capture: true,
      timeoutMs: 120_000
    });
    await runCommand("codesign", ["--verify", "--strict", probePath], { capture: true });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

// Ask Apple for the team's notarization history: it fails fast on a wrong Apple ID, team or app-specific password.
// notarytool takes the password only as an argument (fastlane passes it the same way); it's never printed.
async function checkNotarizationCredentials(env) {
  try {
    await runCommand("xcrun", [
      "notarytool",
      "history",
      "--apple-id",
      env.TCPVIEWER_NOTARIZATION_USERNAME,
      "--team-id",
      env.TCPVIEWER_NOTARIZATION_ASC_PROVIDER,
      "--password",
      env.FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD,
      "--output-format",
      "json"
    ], { capture: true, timeoutMs: 120_000 });
  } catch {
    throw new Error(
      "notarytool couldn't sign in: check TCPVIEWER_NOTARIZATION_USERNAME, TCPVIEWER_NOTARIZATION_ASC_PROVIDER "
      + "and FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD (app-specific passwords stop working when revoked)."
    );
  }
}

// Ask Sentry's chunk-upload endpoint, the first call of the dSYM upload, so a bad token fails before the build.
async function checkSentryAuth(env) {
  const url = new URL(`api/0/organizations/${encodeURIComponent(env.SENTRY_ORG_SLUG)}/chunk-upload/`, `${env.SENTRY_URL}/`);
  let response;
  try {
    response = await fetch(url, {
      headers: { authorization: `Bearer ${env.SENTRY_AUTH_TOKEN}` },
      signal: AbortSignal.timeout(30_000)
    });
  } catch (error) {
    throw new Error(`Sentry didn't answer: ${describeFetchError(error)}`);
  }
  if (!response.ok) {
    throw new Error(`Sentry answered ${response.status}: check SENTRY_AUTH_TOKEN and SENTRY_ORG_SLUG.`);
  }
}

async function ensureFreeDiskSpace() {
  const stats = await statfs(homedir());
  const freeGB = Math.floor((stats.bavail * stats.bsize) / 1024 ** 3);
  if (freeGB < minimumFreeDiskGB) {
    throw new Error(`Only ${freeGB} GB free.`);
  }
  return `${freeGB} GB free`;
}

// Find each command on PATH without running it, and name every missing one.
async function requireCommands(names) {
  const missing = [];
  for (const name of names) {
    try {
      await runCommand("/usr/bin/which", [name], { capture: true });
    } catch {
      missing.push(name);
    }
  }
  if (missing.length) {
    throw new Error(`Not found on PATH: ${missing.join(", ")}`);
  }
}

// Environment for helper apps (Claude Code, VS Code): the shell's, without .env values or release credentials,
// which the release entrypoints load into process.env for fastlane.
async function toolEnvWithoutReleaseSecrets() {
  let fileEnvNames = [];
  try {
    fileEnvNames = Object.keys(parseEnvFile(await readFile(path.join(repoRoot, ".env"), "utf8")));
  } catch {
    // Without .env, only the prefixed release names below can hold credentials.
  }
  const env = { ...process.env };
  for (const name of Object.keys(env)) {
    if (fileEnvNames.includes(name) || /^(TCPVIEWER_|SENTRY_|FASTLANE_)/.test(name)) {
      delete env[name];
    }
  }
  return env;
}

// Collect check results so a pre-flight reports every problem at once instead of stopping at the first one.
function createChecklist() {
  const checklist = {
    failures: 0,
    async check(label, run) {
      try {
        const detail = await run();
        const suffix = typeof detail === "string" && detail ? ` ${paint("2", `(${detail})`)}` : "";
        console.log(`  ${paint("32", "✓")} ${label}${suffix}`);
        return true;
      } catch (error) {
        checklist.failures += 1;
        console.log(`  ${paint("31", `✗ ${label}`)}`);
        // The first lines name the problem (Ruby and notarytool put backtraces after it); long lines are cut.
        const lines = String(error?.message ?? error).trim().split("\n").slice(0, 8);
        console.log(lines.map((line) => `      ${line.length > 240 ? `${line.slice(0, 240)}…` : line}`).join("\n"));
        return false;
      }
    },
    stopOnFailures(stage, outcome) {
      if (checklist.failures) {
        throw new Error(`${stage}: ${checklist.failures} check(s) failed (✗ above). ${outcome}`);
      }
    }
  };
  return checklist;
}

function printStep(title) {
  console.log(`\n${paint("1", `▸ ${title}`)}`);
}

function paint(code, text) {
  return useColor ? `\u001b[${code}m${text}\u001b[0m` : text;
}

function firstLine(text) {
  return String(text ?? "").trim().split("\n")[0];
}

async function fileExists(filePath) {
  try {
    await access(filePath);
    return true;
  } catch {
    return false;
  }
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
  ], { env: { ...env, FASTLANE_SKIP_UPDATE_CHECK: "1" } });
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

async function createGitHubRelease({ githubRelease, releaseNote, dmgPath, outputDir }) {
  const releaseNotesPath = path.join(outputDir, `github-release-${githubRelease.tagName}.md`);
  const tagMessagePath = path.join(outputDir, `git-tag-${githubRelease.tagName}.txt`);
  const releaseNotesMarkdown = releaseNotesToMarkdown(releaseNote);

  await writeFile(releaseNotesPath, releaseNotesMarkdown, { mode: 0o600 });
  await writeFile(tagMessagePath, `${githubRelease.title}\n\n${releaseNotesMarkdown}`, { mode: 0o600 });

  // Publish GitHub only after the notarized DMG has already been verified and uploaded to R2.
  await runCommand("git", ["tag", "-a", githubRelease.tagName, "-F", tagMessagePath]);
  await runCommand("git", ["push", "origin", `refs/tags/${githubRelease.tagName}`]);

  const result = await runCommand("gh", [
    "release",
    "create",
    githubRelease.tagName,
    dmgPath,
    "--repo",
    githubRelease.repo,
    "--title",
    githubRelease.title,
    "--notes-file",
    releaseNotesPath,
    "--verify-tag"
  ], { capture: true });
  const releaseURL = result.stdout.trim() || `https://github.com/${githubRelease.repo}/releases/tag/${githubRelease.tagName}`;
  console.log(`GitHub release created: ${releaseURL}`);
}

// Resolve the fixed cask and branch locations before release preflight starts.
function resolveHomebrewRelease({ env, version, buildNumber }) {
  const configuredPath = String(env.TCPVIEWER_HOMEBREW_CASK_REPO ?? "").trim();
  if (!configuredPath) {
    throw new Error("TCPVIEWER_HOMEBREW_CASK_REPO is required when Homebrew Cask publishing is selected.");
  }

  const repoPath = configuredPath === "~"
    ? homedir()
    : configuredPath.startsWith("~/")
      ? path.join(homedir(), configuredPath.slice(2))
      : path.resolve(configuredPath);
  return {
    version,
    buildNumber,
    repoPath,
    caskPath: path.join(repoPath, homebrewCaskRelativePath),
    templatePath: homebrewCaskTemplatePath,
    branchName: makeHomebrewCaskBranchName({ version, buildNumber })
  };
}

// Validate the official tap checkout before any release side effects occur.
async function preflightHomebrewRelease(homebrewRelease) {
  await requireTool("brew", ["--version"]);
  await requireTool("gh", ["--version"]);
  await requireTool("gh", ["auth", "status"]);

  let repoStat;
  try {
    repoStat = await stat(homebrewRelease.repoPath);
  } catch {
    throw new Error(`Homebrew Cask repository was not found: ${homebrewRelease.repoPath}`);
  }
  if (!repoStat.isDirectory()) {
    throw new Error(`Homebrew Cask repository is not a directory: ${homebrewRelease.repoPath}`);
  }

  const repoRootResult = await runCommand("git", ["rev-parse", "--show-toplevel"], {
    cwd: homebrewRelease.repoPath,
    capture: true
  });
  if (path.resolve(repoRootResult.stdout.trim()) !== path.resolve(homebrewRelease.repoPath)) {
    throw new Error(`TCPVIEWER_HOMEBREW_CASK_REPO must point to the repository root: ${homebrewRelease.repoPath}`);
  }

  const tapRepoPath = (await runCommand("brew", ["--repository", "homebrew/cask"], {
    capture: true
  })).stdout.trim();
  if (path.resolve(tapRepoPath) !== path.resolve(homebrewRelease.repoPath)) {
    throw new Error(
      `TCPVIEWER_HOMEBREW_CASK_REPO must match brew --repository homebrew/cask: ${tapRepoPath}`
    );
  }

  const originURL = (await runCommand("git", ["remote", "get-url", homebrewCaskUpstreamRemote], {
    cwd: homebrewRelease.repoPath,
    capture: true
  })).stdout.trim();
  if (githubRepoFromRemoteURL(originURL) !== homebrewCaskUpstreamRepo.toLowerCase()) {
    throw new Error(`Homebrew Cask origin must be ${homebrewCaskUpstreamRepo}; found ${originURL}.`);
  }

  const forkURL = (await runCommand("git", ["remote", "get-url", homebrewCaskForkRemote], {
    cwd: homebrewRelease.repoPath,
    capture: true
  })).stdout.trim();
  if (githubRepoFromRemoteURL(forkURL) !== homebrewCaskForkRepo.toLowerCase()) {
    throw new Error(
      `Homebrew Cask ${homebrewCaskForkRemote} remote must be ${homebrewCaskForkRepo}; found ${forkURL}.`
    );
  }

  const parentRepo = (await runCommand("gh", [
    "api",
    `repos/${homebrewCaskForkRepo}`,
    "--jq",
    ".parent.full_name"
  ], { capture: true })).stdout.trim();
  if (parentRepo !== homebrewCaskUpstreamRepo) {
    throw new Error(`${homebrewCaskForkRepo} must be a fork of ${homebrewCaskUpstreamRepo}.`);
  }

  await runCommand("git", ["fetch", homebrewCaskUpstreamRemote, homebrewCaskDefaultBranch, "--prune"], {
    cwd: homebrewRelease.repoPath,
    capture: true
  });
  await runCommand("git", ["fetch", homebrewCaskForkRemote, "--prune"], {
    cwd: homebrewRelease.repoPath,
    capture: true
  });
  await ensureHomebrewGitReady(homebrewRelease);
  homebrewRelease.pullRequestTemplate = await readHomebrewPullRequestTemplate(homebrewRelease);

  const source = await readHomebrewCaskSource(homebrewRelease);
  const currentVersion = validateHomebrewCaskContent(source.content, {
    allowMissingCLI: !source.isInitialCask
  });
  if (
    !source.isInitialCask
    &&
    currentVersion.version === homebrewRelease.version
    && currentVersion.buildNumber === homebrewRelease.buildNumber
  ) {
    throw new Error(`Homebrew Cask already contains ${homebrewRelease.version},${homebrewRelease.buildNumber}.`);
  }

  homebrewRelease.isInitialCask = source.isInitialCask;
  if (source.isInitialCask) {
    await ensureHomebrewCaskWasNotRefused();
    homebrewRelease.githubMetrics = await loadTCPViewerGitHubMetrics();
    console.warn(
      `Review Homebrew's current notability policy before submitting. `
      + `TCPViewer currently has ${homebrewRelease.githubMetrics.stars} stars, `
      + `${homebrewRelease.githubMetrics.forks} forks, and ${homebrewRelease.githubMetrics.watchers} watchers.`
    );
  }

  await ensureHomebrewBranchDoesNotExist(homebrewRelease);
  console.log(
    `Homebrew Cask ${source.isInitialCask ? "initial submission" : "update"} preflight passed `
    + `for ${homebrewRelease.repoPath}.`
  );
}

// A clean named branch lets the release restore the maintainer's checkout after publishing.
async function ensureHomebrewGitReady(homebrewRelease) {
  const status = await runCommand("git", ["status", "--porcelain"], {
    cwd: homebrewRelease.repoPath,
    capture: true
  });
  if (status.stdout.trim()) {
    throw new Error("Homebrew Cask working tree must be clean before a production release.");
  }

  const branch = (await runCommand("git", ["branch", "--show-current"], {
    cwd: homebrewRelease.repoPath,
    capture: true
  })).stdout.trim();
  if (!branch) {
    throw new Error("Homebrew Cask repository must be on a named branch, not a detached HEAD.");
  }
  homebrewRelease.originalBranch = branch;
}

async function readHomebrewCaskSource(homebrewRelease) {
  const upstreamRef = `${homebrewCaskUpstreamRemote}/${homebrewCaskDefaultBranch}`;
  const listing = await runCommand("git", [
    "ls-tree",
    "--name-only",
    upstreamRef,
    "--",
    homebrewCaskRelativePath
  ], { cwd: homebrewRelease.repoPath, capture: true });
  if (listing.stdout.trim() === homebrewCaskRelativePath) {
    const upstreamObject = `${upstreamRef}:${homebrewCaskRelativePath}`;
    const result = await runCommand("git", ["show", upstreamObject], {
      cwd: homebrewRelease.repoPath,
      capture: true
    });
    return { content: result.stdout, isInitialCask: false };
  }

  const template = await readFile(homebrewRelease.templatePath, "utf8");
  return { content: template, isInitialCask: true };
}

async function readHomebrewPullRequestTemplate(homebrewRelease) {
  const upstreamObject = `${homebrewCaskUpstreamRemote}/${homebrewCaskDefaultBranch}:${homebrewPullRequestTemplateRelativePath}`;
  const result = await runCommand("git", ["show", upstreamObject], {
    cwd: homebrewRelease.repoPath,
    capture: true
  });
  if (!result.stdout.trim()) {
    throw new Error("The upstream Homebrew Cask pull request template is empty.");
  }
  return result.stdout;
}

async function ensureHomebrewCaskWasNotRefused() {
  const result = await runCommand("gh", [
    "pr",
    "list",
    "--repo",
    homebrewCaskUpstreamRepo,
    "--state",
    "closed",
    "--search",
    `${homebrewCaskToken} in:title`,
    "--limit",
    "100",
    "--json",
    "number,title,url,mergedAt"
  ], { capture: true });
  const refused = JSON.parse(result.stdout).filter((pullRequest) => !pullRequest.mergedAt);
  if (refused.length) {
    throw new Error(
      `A previous TCP Viewer Homebrew Cask pull request was closed without merging: ${refused[0].url}`
    );
  }
}

async function loadTCPViewerGitHubMetrics() {
  const result = await runCommand("gh", [
    "api",
    "repos/ProxymanApp/TCPViewer",
    "--jq",
    "{stars: .stargazers_count, forks: .forks_count, watchers: .subscribers_count}"
  ], { capture: true });
  return JSON.parse(result.stdout);
}

async function ensureHomebrewBranchDoesNotExist(homebrewRelease) {
  try {
    await runCommand("git", ["show-ref", "--verify", "--quiet", `refs/heads/${homebrewRelease.branchName}`], {
      cwd: homebrewRelease.repoPath,
      capture: true
    });
    throw new Error(`Homebrew Cask branch already exists locally: ${homebrewRelease.branchName}`);
  } catch (error) {
    if (String(error.message).startsWith("Homebrew Cask branch already exists")) {
      throw error;
    }
  }

  const remoteBranch = await runCommand("git", [
    "ls-remote",
    "--heads",
    homebrewCaskForkRemote,
    `refs/heads/${homebrewRelease.branchName}`
  ], { cwd: homebrewRelease.repoPath, capture: true });
  if (remoteBranch.stdout.trim()) {
    throw new Error(
      `Homebrew Cask branch already exists on ${homebrewCaskForkRemote}: ${homebrewRelease.branchName}`
    );
  }
}

// Create the cask change from current upstream main so stale fork branches cannot leak into the PR.
async function createHomebrewCaskPullRequest({ homebrewRelease, dmgPath, installTested, nonInteractive }) {
  const sha256 = await sha256File(dmgPath);
  const source = await readHomebrewCaskSource(homebrewRelease);
  const updatedContent = updateHomebrewCaskContent(source.content, {
    version: homebrewRelease.version,
    buildNumber: homebrewRelease.buildNumber,
    sha256
  });
  const pullRequestTitle = source.isInitialCask
    ? `${homebrewCaskToken} ${homebrewRelease.version} (new cask)`
    : `${homebrewCaskToken} ${homebrewRelease.version}`;

  await runCommand("git", [
    "switch",
    "-c",
    homebrewRelease.branchName,
    `${homebrewCaskUpstreamRemote}/${homebrewCaskDefaultBranch}`
  ], {
    cwd: homebrewRelease.repoPath
  });
  try {
    await mkdir(path.dirname(homebrewRelease.caskPath), { recursive: true });
    await writeFile(homebrewRelease.caskPath, updatedContent);
    await runCommand("git", ["add", homebrewCaskRelativePath], { cwd: homebrewRelease.repoPath });
    await validateHomebrewCaskChange(homebrewRelease);
    if (source.isInitialCask) {
      await confirmInitialHomebrewInstallTest({ installTested, nonInteractive });
    }

    await runCommand("git", ["add", homebrewCaskRelativePath], { cwd: homebrewRelease.repoPath });
    await runCommand("git", ["diff", "--cached", "--check"], { cwd: homebrewRelease.repoPath });
    await runCommand("git", ["commit", "--no-gpg-sign", "-m", pullRequestTitle], {
      cwd: homebrewRelease.repoPath
    });
    await runCommand("git", ["push", "--set-upstream", homebrewCaskForkRemote, homebrewRelease.branchName], {
      cwd: homebrewRelease.repoPath
    });

    const result = await runCommand("gh", [
      "pr",
      "create",
      "--repo",
      homebrewCaskUpstreamRepo,
      "--base",
      homebrewCaskDefaultBranch,
      "--head",
      `ProxymanApp:${homebrewRelease.branchName}`,
      "--title",
      pullRequestTitle,
      "--body",
      makeHomebrewCaskPullRequestBody({
        template: homebrewRelease.pullRequestTemplate,
        isInitialCask: source.isInitialCask,
        githubMetrics: homebrewRelease.githubMetrics
      })
    ], { capture: true });
    const pullRequestURL = result.stdout.trim();
    console.log(`Homebrew Cask pull request created: ${pullRequestURL}`);
  } catch (error) {
    throw new Error(
      `Homebrew Cask update failed. Branch ${homebrewRelease.branchName} was kept for recovery.\n${error.message}`
    );
  }

  await runCommand("git", ["switch", homebrewRelease.originalBranch], { cwd: homebrewRelease.repoPath });
}

async function validateHomebrewCaskChange(homebrewRelease) {
  const brewEnv = { HOMEBREW_DEVELOPER: "1", HOMEBREW_NO_AUTO_UPDATE: "1" };
  await runCommand("brew", ["style", "--fix", "--cask", homebrewCaskToken], {
    cwd: homebrewRelease.repoPath,
    env: brewEnv
  });
  const auditArgs = makeHomebrewCaskAuditArgs({
    isInitialCask: homebrewRelease.isInitialCask,
    token: homebrewCaskToken
  });
  await runCommand("brew", auditArgs, { cwd: homebrewRelease.repoPath, env: brewEnv });
  const livecheckResult = await runCommand("brew", [
    "livecheck",
    "--json",
    "--cask",
    "--autobump",
    homebrewCaskToken
  ], {
    cwd: homebrewRelease.repoPath,
    env: brewEnv,
    capture: true
  });
  validateHomebrewLivecheckOutput(
    livecheckResult.stdout,
    `${homebrewRelease.version},${homebrewRelease.buildNumber}`
  );

  validateHomebrewCaskContent(await readFile(homebrewRelease.caskPath, "utf8"));
}

async function confirmInitialHomebrewInstallTest({ installTested, nonInteractive }) {
  if (installTested) {
    return;
  }
  const commands = [
    `HOMEBREW_NO_INSTALL_FROM_API=1 brew install --cask ${homebrewCaskToken}`,
    `brew uninstall --cask ${homebrewCaskToken}`
  ];
  if (nonInteractive) {
    throw new Error(
      `Initial Homebrew Cask submissions require manual install and uninstall testing. `
      + `Run ${commands.join(" and ")}, then rerun with --homebrew-install-tested.`
    );
  }

  console.log("Run these commands in another terminal before continuing:");
  for (const command of commands) {
    console.log(`- ${command}`);
  }
  const response = await prompts({
    type: "confirm",
    name: "installTested",
    message: "Did the Homebrew Cask install and uninstall commands both succeed?",
    initial: false
  });
  if (response.installTested !== true) {
    throw new Error("Initial Homebrew Cask install validation was not confirmed.");
  }
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
  const verificationHeaders = signR2Request({
    method: "HEAD",
    url,
    accessKeyId: env.TCPVIEWER_R2_ACCESS_KEY_ID,
    secretAccessKey: env.TCPVIEWER_R2_SECRET_ACCESS_KEY,
    payloadHash: emptyPayloadSHA256
  });

  console.log(`Uploading DMG to R2: ${objectKey}`);
  await putR2ObjectWithRetry({
    url,
    signedHeaders,
    verificationHeaders,
    dmgPath,
    objectKey,
    expectedSize: fileStat.size
  });
  console.log(`Uploaded DMG to R2: ${objectKey}`);
}

async function putR2ObjectWithRetry({ url, signedHeaders, verificationHeaders, dmgPath, objectKey, expectedSize }) {
  for (let attempt = 1; attempt <= r2UploadMaxAttempts; attempt += 1) {
    let response;
    try {
      response = await curlR2Request({
        method: "PUT",
        url,
        headers: signedHeaders,
        uploadFile: dmgPath,
        timeoutMs: r2UploadAttemptTimeoutMs
      });
    } catch (error) {
      const message = describeFetchError(error);
      if (attempt === r2UploadMaxAttempts) {
        if (await r2ObjectHasExpectedSize({ url, headers: verificationHeaders, expectedSize })) {
          console.warn(`R2 upload response was lost, but ${objectKey} exists with the expected size. Continuing.`);
          return;
        }
        throw new Error(`R2 upload failed for ${objectKey}: ${message}`);
      }
      await retryR2Upload({ attempt, message, objectKey });
      continue;
    }

    if (isSuccessfulHTTPStatus(response.status)) {
      return;
    }

    const message = `${response.status} ${response.body}`.trim();
    if (!isRetryableHTTPStatus(response.status)) {
      throw new Error(`R2 upload failed for ${objectKey}: ${message}`);
    }

    if (attempt === r2UploadMaxAttempts) {
      if (await r2ObjectHasExpectedSize({ url, headers: verificationHeaders, expectedSize })) {
        console.warn(`R2 upload ended with ${response.status}, but ${objectKey} exists with the expected size. Continuing.`);
        return;
      }
      throw new Error(`R2 upload failed for ${objectKey}: ${message}`);
    }

    await retryR2Upload({ attempt, message, objectKey });
  }
}

async function retryR2Upload({ attempt, message, objectKey }) {
  console.warn(`R2 upload attempt ${attempt}/${r2UploadMaxAttempts} failed for ${objectKey}: ${message}. Retrying...`);
  await sleep(attempt * 1500);
}

async function r2ObjectHasExpectedSize({ url, headers, expectedSize }) {
  for (let attempt = 1; attempt <= r2UploadConfirmationAttempts; attempt += 1) {
    try {
      const response = await curlR2Request({
        method: "HEAD",
        url,
        headers,
        timeoutMs: r2UploadConfirmationTimeoutMs
      });
      if (response.status === 404) {
        return false;
      }
      if (isSuccessfulHTTPStatus(response.status)) {
        return Number(response.headers.get("content-length")) === expectedSize;
      }
    } catch {
      // A lost PUT response can race with transient network failures; retry the confirmation too.
    }

    if (attempt < r2UploadConfirmationAttempts) {
      await sleep(attempt * 1000);
    }
  }

  return false;
}

function sleep(milliseconds) {
  return new Promise((resolve) => {
    setTimeout(resolve, milliseconds);
  });
}

async function curlR2Request({ method, url, headers, uploadFile = null, timeoutMs }) {
  const args = [
    "-sS",
    "--max-time", String(Math.ceil(timeoutMs / 1000)),
    "--write-out", "\n%{http_code}",
    "--output", "-"
  ];

  if (method === "HEAD") {
    args.push("--head");
  } else {
    args.push("--request", method);
  }

  if (uploadFile) {
    args.push("--upload-file", uploadFile);
  }

  args.push(...curlHeaderArgs(headers, { skipHeaders: uploadFile ? ["content-length"] : [] }));
  args.push(url.href);

  const result = await runCommand("/usr/bin/curl", args, { capture: true });
  return parseCurlHTTPResponse(result.stdout);
}

function curlHeaderArgs(headers, { skipHeaders = [] } = {}) {
  const skipped = new Set(skipHeaders.map((name) => name.toLowerCase()));
  return Object.entries(headers).flatMap(([name, value]) => {
    if (skipped.has(name.toLowerCase())) {
      return [];
    }
    return ["--header", `${name}: ${value}`];
  });
}

function parseCurlHTTPResponse(stdout) {
  const markerIndex = stdout.lastIndexOf("\n");
  const status = Number(stdout.slice(markerIndex + 1).trim());
  const body = markerIndex === -1 ? "" : stdout.slice(0, markerIndex).trim();
  if (!Number.isInteger(status) || status < 100) {
    throw new Error("curl did not return an HTTP status code.");
  }

  return {
    status,
    body,
    headers: parseCurlHeaders(body)
  };
}

function parseCurlHeaders(rawHeaders) {
  const headers = new Map();
  for (const line of rawHeaders.split(/\r?\n/)) {
    const separatorIndex = line.indexOf(":");
    if (separatorIndex === -1) {
      continue;
    }
    headers.set(
      line.slice(0, separatorIndex).trim().toLowerCase(),
      line.slice(separatorIndex + 1).trim()
    );
  }

  return {
    get(name) {
      return headers.get(name.toLowerCase()) ?? null;
    }
  };
}

function isSuccessfulHTTPStatus(status) {
  return status >= 200 && status < 300;
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

// Read the latest public production release instead of trusting local project version settings.
async function loadLatestPublishedGitHubRelease() {
  await requireTool("gh", ["--version"]);
  let result;
  try {
    result = await runCommand("gh", [
      "release",
      "view",
      "--repo",
      githubReleaseRepo,
      "--json",
      "assets,isDraft,isPrerelease,tagName"
    ], { capture: true });
  } catch (error) {
    throw new Error(`The latest published GitHub release for ${githubReleaseRepo} was not found.\n${error.message}`);
  }

  let release;
  try {
    release = JSON.parse(result.stdout);
  } catch {
    throw new Error(`Could not parse the latest GitHub release for ${githubReleaseRepo}.`);
  }

  const asset = resolvePublishedGitHubReleaseArtifact(release);
  return {
    repo: githubReleaseRepo,
    tagName: asset.tagName,
    asset
  };
}

async function resolveGitHubRepo() {
  const result = await runCommand("gh", [
    "repo",
    "view",
    "--json",
    "nameWithOwner,defaultBranchRef"
  ], { capture: true });

  let payload;
  try {
    payload = JSON.parse(result.stdout);
  } catch {
    throw new Error("Could not parse GitHub repository information from gh.");
  }

  const nameWithOwner = String(payload?.nameWithOwner ?? "").trim();
  const defaultBranch = String(payload?.defaultBranchRef?.name ?? "").trim();
  if (!nameWithOwner || !defaultBranch) {
    throw new Error("Could not resolve GitHub repository name and default branch from gh.");
  }

  return { nameWithOwner, defaultBranch };
}

async function ensureGitReadyForProductionRelease(defaultBranch) {
  const status = await runCommand("git", ["status", "--porcelain"], { capture: true });
  if (status.stdout.trim()) {
    throw new Error("Working tree must be clean before creating a production release tag.");
  }

  const branch = (await runCommand("git", ["branch", "--show-current"], { capture: true })).stdout.trim();
  if (!branch) {
    throw new Error("Production release must run from a branch, not detached HEAD.");
  }

  if (branch !== defaultBranch) {
    throw new Error(`Production release must run from ${defaultBranch}; current branch is ${branch}.`);
  }

  // Keep the release tag pinned to the exact reviewed commit on the default branch.
  let upstream;
  try {
    upstream = (await runCommand("git", [
      "rev-parse",
      "--abbrev-ref",
      "--symbolic-full-name",
      "@{u}"
    ], { capture: true })).stdout.trim();
  } catch {
    throw new Error(`Production release branch ${branch} must have an upstream remote branch.`);
  }

  const counts = (await runCommand("git", [
    "rev-list",
    "--left-right",
    "--count",
    "HEAD...@{u}"
  ], { capture: true })).stdout.trim().split(/\s+/);
  if (counts[0] !== "0" || counts[1] !== "0") {
    throw new Error(`Production release branch ${branch} must be in sync with ${upstream}.`);
  }
}

async function ensureGitHubTagDoesNotExist(tagName) {
  const tagRef = `refs/tags/${tagName}`;
  if (await gitRefExists(tagRef)) {
    throw new Error(`Git tag already exists locally: ${tagName}`);
  }

  const remoteResult = await runCommand("git", [
    "ls-remote",
    "--tags",
    "origin",
    tagRef,
    `${tagRef}^{}`
  ], { capture: true });
  if (remoteResult.stdout.trim()) {
    throw new Error(`Git tag already exists on origin: ${tagName}`);
  }
}

async function ensureGitHubReleaseDoesNotExist({ tagName, repo }) {
  try {
    await runCommand("gh", [
      "release",
      "view",
      tagName,
      "--repo",
      repo,
      "--json",
      "id"
    ], { capture: true });
  } catch (error) {
    if (isGitHubReleaseNotFoundError(error)) {
      return;
    }
    throw new Error(`GitHub release lookup failed for ${repo} ${tagName}: ${error.message}`);
  }

  throw new Error(`GitHub release already exists: ${repo} ${tagName}`);
}

async function gitRefExists(ref) {
  try {
    await runCommand("git", ["rev-parse", "--verify", "--quiet", ref], { capture: true });
    return true;
  } catch {
    return false;
  }
}

function isGitHubReleaseNotFoundError(error) {
  return /release not found|not found/i.test(String(error?.message ?? ""));
}

async function sha256File(filePath) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(filePath)) {
    hash.update(chunk);
  }
  return hash.digest("hex");
}

async function downloadPublishedDMG({ downloadURL, dmgPath, expectedAsset }) {
  let requestedURL;
  try {
    requestedURL = new URL(downloadURL);
  } catch {
    throw new Error("The published DMG URL is invalid.");
  }
  if (requestedURL.protocol !== "https:") {
    throw new Error("The published DMG URL must use HTTPS.");
  }

  console.log(`Downloading published DMG: ${downloadURL}`);
  let response;
  try {
    response = await fetch(requestedURL, {
      redirect: "follow",
      signal: AbortSignal.timeout(r2UploadAttemptTimeoutMs)
    });
  } catch (error) {
    throw new Error(`Published DMG download failed: ${describeFetchError(error)}`);
  }
  if (!response.ok) {
    throw new Error(`Published DMG download failed: ${response.status} ${response.statusText}`);
  }
  if (!response.body) {
    throw new Error("Published DMG download returned an empty response body.");
  }
  if (new URL(response.url).protocol !== "https:") {
    throw new Error("The published DMG download redirected to a non-HTTPS URL.");
  }

  const contentLength = Number(response.headers.get("content-length"));
  if (Number.isSafeInteger(contentLength) && contentLength > 0 && contentLength !== expectedAsset.size) {
    throw new Error(
      `Published DMG size ${contentLength} does not match GitHub release asset size ${expectedAsset.size}.`
    );
  }

  await pipeline(
    Readable.fromWeb(response.body),
    createWriteStream(dmgPath, { mode: 0o600 })
  );
  const downloadedSize = (await stat(dmgPath)).size;
  if (downloadedSize !== expectedAsset.size) {
    throw new Error(
      `Downloaded DMG size ${downloadedSize} does not match GitHub release asset size ${expectedAsset.size}.`
    );
  }

  const downloadedSHA256 = await sha256File(dmgPath);
  if (downloadedSHA256 !== expectedAsset.sha256) {
    throw new Error("Downloaded DMG SHA-256 does not match the published GitHub release asset.");
  }
  console.log(`Published DMG verified: sha256 ${downloadedSHA256}`);
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

// Run a command; capture its output or share the terminal. Errors name the command and its stderr, never its arguments.
function runCommand(command, args, {
  env = {},
  baseEnv = process.env,
  capture = false,
  cwd = repoRoot,
  input = null,
  timeoutMs = 0
} = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: { ...baseEnv, ...env },
      stdio: capture ? [input === null ? "ignore" : "pipe", "pipe", "pipe"] : "inherit",
      timeout: timeoutMs || undefined
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
      if (input !== null) {
        child.stdin.end(input);
      }
    }

    child.on("error", reject);
    child.on("close", (code, signal) => {
      if (code === 0) {
        resolve({ stdout, stderr });
      } else if (signal && timeoutMs) {
        reject(new Error(`${command} timed out after ${Math.round(timeoutMs / 1000)}s`));
      } else {
        reject(new Error(`${command} exited with ${code ?? signal}${stderr ? `\n${stderr}` : ""}`));
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

async function askBetaDMGCustomName(version, buildNumber) {
  const response = await prompts({
    type: "text",
    name: "customName",
    message: `Beta DMG custom name (tcpviewer_${version}_${buildNumber}_{custom_name}.dmg)`,
    validate: (value) => {
      try {
        makeBetaDMGFileName({ version, buildNumber, customName: value });
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

async function askHomebrewReleaseConfirmation() {
  const response = await prompts({
    type: "confirm",
    name: "confirmed",
    message: "Create the Homebrew Cask pull request from this published release?",
    initial: false
  });

  if (typeof response.confirmed !== "boolean") {
    throw new Error("Homebrew release cancelled.");
  }
  return response.confirmed;
}

// Ask for a line of text; Enter keeps the default, and a validation problem shows under the input.
async function askText(message, initial, problem) {
  const response = await prompts({
    type: "text",
    name: "value",
    message,
    initial,
    validate: (value) => problem(String(value ?? "").trim()) ?? true,
    format: (value) => String(value ?? "").trim()
  });
  return requirePromptValue(response.value, message);
}

function requirePromptValue(value, label) {
  if (value === undefined) {
    throw new Error(`${label} was cancelled.`);
  }

  return value;
}

function printReleaseSummary({ env, target, releaseBackend }) {
  printStep("Release summary");
  console.log(`  Type:          ${target.releaseType}`);
  console.log(`  Version:       ${target.version} (${target.buildNumber})`);
  console.log(`  DMG:           ${target.dmgFileName}`);
  console.log(`  Output:        ${target.outputDir}`);
  console.log(`  Download URL:  ${target.downloadURL}`);
  console.log(`  Sentry dSYMs:  ${env.SENTRY_URL}`);
  console.log(`  Backend:       ${releaseBackend ? "publishes the release" : "disabled"}`);
  if (target.githubRelease) {
    console.log(`  GitHub:        ${target.githubRelease.repo} ${target.githubRelease.tagName}`);
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
    } else if (arg === "--yes" || arg === "-y") {
      args.yes = true;
    } else if (arg === "--homebrew-install-tested") {
      args.homebrewInstallTested = true;
    } else if (arg === "--homebrew-only") {
      args.homebrewOnly = true;
    } else {
      const argumentName = arg.split("=", 1)[0];
      throw new Error(`Unknown release argument: ${argumentName}`);
    }
  }
  return args;
}

function releaseOutputDir({ releaseType, version, buildNumber, timestamp }) {
  const folder = releaseType === "production"
    ? `production/${version}-${buildNumber}`
    : `beta/${version}-${buildNumber}-${timestamp}`;
  return path.join(releaseRootDir, folder);
}

function makeTimestamp(date = new Date()) {
  return date.toISOString().replaceAll(/[-:]/g, "").replace(/\..+$/, "Z");
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
