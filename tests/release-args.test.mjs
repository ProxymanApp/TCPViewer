import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const repoRoot = fileURLToPath(new URL("../", import.meta.url));
const releaseEntrypoints = [
  "scripts/release.mjs",
  "scripts/nodejs/index.js"
];

test("release entrypoints reject unknown arguments", async (t) => {
  for (const entrypoint of releaseEntrypoints) {
    await t.test(entrypoint, () => {
      const result = spawnSync(
        process.execPath,
        [entrypoint, "--definitely-unsupported=private-value", "--type=invalid"],
        {
          cwd: repoRoot,
          encoding: "utf8"
        }
      );

      assert.equal(result.status, 1);
      assert.match(result.stderr, /Unknown release argument: --definitely-unsupported/);
      assert.doesNotMatch(result.stderr, /private-value/);
      assert.doesNotMatch(result.stderr, /Release type must be/);
    });
  }
});
