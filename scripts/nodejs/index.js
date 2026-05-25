const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");
const prompts = require("prompts");

const repoRoot = path.resolve(__dirname, "../..");
const releaseScriptPath = path.join(repoRoot, "scripts", "release.mjs");

const RELEASE_TYPE = {
  BETA: "beta",
  PRODUCTION: "production",
};

function parseArgs(argv) {
  const args = {};
  for (const arg of argv) {
    if (arg.startsWith("--type=")) {
      args.type = arg.slice("--type=".length).trim().toLowerCase();
    } else if (arg.startsWith("--version=")) {
      args.version = arg.slice("--version=".length).trim();
    } else if (arg.startsWith("--beta-name=")) {
      args.betaName = arg.slice("--beta-name=".length).trim();
    }
  }
  return args;
}

function parseEnvFile(content) {
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

    const name = line.slice(0, separatorIndex).trim();
    const rawValue = line.slice(separatorIndex + 1).trim();
    if (!name) {
      continue;
    }

    env[name] = stripOptionalQuotes(rawValue).replaceAll(":/$()/", "://");
  }
  return env;
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

function loadEnv() {
  const envPath = path.join(repoRoot, ".env");
  if (!fs.existsSync(envPath)) {
    return {};
  }

  // Keep secrets local by loading ignored .env values into child processes only.
  return parseEnvFile(fs.readFileSync(envPath, "utf8"));
}

async function resolveReleaseType(type) {
  if (type) {
    if (Object.values(RELEASE_TYPE).includes(type)) {
      return type;
    }
    throw new Error("Release type must be beta or production.");
  }

  const response = await prompts({
    type: "select",
    name: "type",
    message: "What would you like to build?",
    choices: [
      { title: "BETA Build", value: RELEASE_TYPE.BETA },
      { title: "Production Build", value: RELEASE_TYPE.PRODUCTION },
    ],
    initial: 0,
  });

  if (!response.type) {
    throw new Error("Release cancelled.");
  }
  return response.type;
}

function buildReleaseArgs(type, args) {
  const releaseArgs = [releaseScriptPath, `--type=${type}`];
  if (args.version) {
    releaseArgs.push(`--version=${args.version}`);
  }
  if (args.betaName) {
    releaseArgs.push(`--beta-name=${args.betaName}`);
  }
  return releaseArgs;
}

function runRelease(type, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, buildReleaseArgs(type, args), {
      cwd: repoRoot,
      env: { ...loadEnv(), ...process.env },
      stdio: "inherit",
    });

    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`Release script exited with code ${code}.`));
      }
    });
  });
}

async function main() {
  console.log("-------------------------------");
  console.log("Welcome to TCPViewer Utility");
  console.log("-------------------------------");

  const args = parseArgs(process.argv.slice(2));
  const type = await resolveReleaseType(args.type);
  await runRelease(type, args);
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
