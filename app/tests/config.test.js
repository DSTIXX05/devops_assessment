import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";

import { config } from "../src/config.js";

const appRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);

/**
 * Config is read at import time, so invalid values are tested in a throwaway
 * process instead of mutating the test runner's own environment.
 */
function loadConfigWith(env) {
  return spawnSync(
    process.execPath,
    [
      "--input-type=module",
      "-e",
      "import('./src/config.js').then((m) => process.stdout.write(JSON.stringify(m.config))).catch((e) => { process.stderr.write(e.message); process.exit(1); });",
    ],
    {
      cwd: appRoot,
      encoding: "utf8",
      env: { ...process.env, PORT: "", HOST: "", ...env },
    },
  );
}

describe("config", () => {
  it("binds all interfaces by default so the ALB can reach the container", () => {
    assert.equal(config.host, "0.0.0.0");
  });

  it("defaults to the documented container port 3000", () => {
    const result = loadConfigWith({});
    const parsed = JSON.parse(result.stdout);

    assert.equal(result.status, 0);
    assert.equal(parsed.port, 3000);
  });

  it("rejects a non-numeric PORT instead of silently falling back", () => {
    const result = loadConfigWith({ PORT: "not-a-port" });

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Invalid PORT/);
  });

  it("rejects an out-of-range PORT", () => {
    const result = loadConfigWith({ PORT: "70000" });

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Invalid PORT/);
  });

  it("uses a drain timeout shorter than the ALB deregistration delay", () => {
    // The ALB deregistration delay is set to 30s in infrastructure; the app
    // must finish draining before ECS stops waiting.
    assert.ok(config.shutdownTimeoutMs > 0);
    assert.ok(config.shutdownTimeoutMs < 30_000);
  });
});
