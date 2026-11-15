import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";

const appRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);

function safeParse(line) {
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

/**
 * Runs the real entrypoint as a child process so signal handling is tested
 * end to end rather than by calling the shutdown function directly.
 */
function spawnServer(env = {}) {
  const child = spawn(process.execPath, ["src/server.js"], {
    cwd: appRoot,
    env: {
      ...process.env,
      PORT: "0",
      APP_ENV: "test",
      LOG_LEVEL: "info",
      ...env,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  let stdoutBuffer = "";
  let stderrBuffer = "";

  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk;
  });
  child.stderr.on("data", (chunk) => {
    stderrBuffer += chunk;
  });

  return {
    child,
    getStdout: () =>
      stdoutBuffer.split("\n").filter((line) => line.trim() !== ""),
    getStderr: () =>
      stderrBuffer.split("\n").filter((line) => line.trim() !== ""),
  };
}

async function waitFor(
  predicate,
  { timeoutMs = 10_000, label = "condition" } = {},
) {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const result = predicate();

    if (result) {
      return result;
    }

    await delay(25);
  }

  throw new Error(`Timed out waiting for ${label}`);
}

function waitForExit(child) {
  return new Promise((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });
}

describe("graceful shutdown", () => {
  for (const signal of ["SIGTERM", "SIGINT"]) {
    it(
      `${signal} drains and exits with code 0`,
      { timeout: 20_000 },
      async () => {
        const { child, getStdout, getStderr } = spawnServer();
        const exit = waitForExit(child);

        const startedRecord = await waitFor(
          () =>
            getStdout()
              .map(safeParse)
              .find((record) => record?.message === "server started"),
          { label: "server started log" },
        );

        // The container must listen on all interfaces, on the configured port.
        assert.equal(startedRecord.host, "0.0.0.0");
        assert.ok(startedRecord.port > 0, "expected a bound ephemeral port");

        child.kill(signal);

        const { code, signal: exitSignal } = await exit;
        const records = getStdout().map(safeParse);
        const messages = records.map((record) => record?.message);

        assert.equal(
          exitSignal,
          null,
          "process should exit on its own, not be killed",
        );
        assert.equal(
          code,
          0,
          `expected exit code 0, stderr was:\n${getStderr().join("\n")}`,
        );
        assert.ok(
          messages.includes("shutdown initiated"),
          "expected a shutdown initiated log",
        );
        assert.ok(
          messages.includes("shutdown complete"),
          "expected a shutdown complete log",
        );

        const initiated = records.find(
          (record) => record?.message === "shutdown initiated",
        );

        assert.equal(initiated.signal, signal);
      },
    );
  }

  it("serves on the configured PORT and shuts down cleanly", async () => {
    const { child, getStdout } = spawnServer({ PORT: "31000" });
    const exit = waitForExit(child);

    const startedRecord = await waitFor(
      () =>
        getStdout()
          .map(safeParse)
          .find((record) => record?.message === "server started"),
      { label: "server started log" },
    );

    assert.equal(startedRecord.port, 31000);

    // Confirm the documented container port is actually serving.
    const response = await fetch("http://127.0.0.1:31000/health");
    assert.equal(response.status, 200);

    child.kill("SIGTERM");
    await exit;
  });

  it("closes connections it opened so the process is not left hanging", async () => {
    const { child, getStdout } = spawnServer();
    const exit = waitForExit(child);

    const startedRecord = await waitFor(
      () =>
        getStdout()
          .map(safeParse)
          .find((record) => record?.message === "server started"),
      { label: "server started log" },
    );

    const port = startedRecord.port;

    // Hold an idle keep-alive connection open, then request shutdown. Node
    // must release the idle socket instead of waiting for the timeout.
    const socket = net.connect({ host: "127.0.0.1", port });
    await new Promise((resolve, reject) => {
      socket.once("connect", resolve);
      socket.once("error", reject);
    });

    child.kill("SIGTERM");
    socket.destroy();

    const { code } = await exit;

    assert.equal(code, 0);
  });
});
