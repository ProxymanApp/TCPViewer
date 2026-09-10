import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const validatorPath = fileURLToPath(new URL("../scripts/validate-local-build-env.sh", import.meta.url));

function runValidator(configuration, usesLocalLicenseServer) {
  return spawnSync("/bin/sh", [validatorPath], {
    encoding: "utf8",
    env: {
      PATH: process.env.PATH,
      CONFIGURATION: configuration,
      TCPVIEWER_DEVELOPMENT_TEAM: "ABCDE12345",
      DEVELOPMENT_TEAM: "ABCDE12345",
      TCPVIEWER_BUILD_KEY: "test-only",
      TCPVIEWER_USES_LOCAL_LICENSE_SERVER: usesLocalLicenseServer
    }
  });
}

test("allows the local license server only for Debug builds", () => {
  assert.equal(runValidator("Debug", "true").status, 0);
  assert.equal(runValidator("Release", "false").status, 0);

  const unsafeRelease = runValidator("Release", "true");
  assert.equal(unsafeRelease.status, 1);
  assert.match(unsafeRelease.stdout, /Beta and production builds must set TCPVIEWER_USES_LOCAL_LICENSE_SERVER to false/);
});
