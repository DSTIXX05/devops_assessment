import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";

import { createApp } from "../src/app.js";
import { config } from "../src/config.js";

/**
 * Starts the app on an ephemeral port for integration-style assertions.
 * Using a real listener (rather than a mocked request object) exercises the
 * same code path the ALB will hit.
 */
function startServer(app) {
  return new Promise((resolve, reject) => {
    const server = app.listen(0, "127.0.0.1", () => resolve(server));
    server.once("error", reject);
  });
}

describe("HTTP API", () => {
  let app;
  let server;
  let baseUrl;

  before(async () => {
    app = createApp();
    server = await startServer(app);
    baseUrl = `http://127.0.0.1:${server.address().port}`;
  });

  after(async () => {
    await new Promise((resolve) => server.close(resolve));
  });

  it("GET / returns service information", async () => {
    const response = await fetch(`${baseUrl}/`);
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.equal(body.service, config.serviceName);
    assert.match(body.message, /running/i);
    assert.equal(body.environment, config.environment);
  });

  it("GET /health returns 200 and status ok", async () => {
    const response = await fetch(`${baseUrl}/health`);
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.deepEqual(body, { status: "ok" });
  });

  it("GET /api/status returns a complete status payload", async () => {
    const response = await fetch(`${baseUrl}/api/status`);
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.equal(body.status, "ok");
    assert.equal(body.service, config.serviceName);
    assert.equal(body.environment, config.environment);
    assert.equal(body.version, config.version);
    assert.equal(body.commitSha, config.commitSha);
    assert.equal(body.nodeVersion, process.version);
    assert.equal(typeof body.uptimeSeconds, "number");
    assert.ok(body.uptimeSeconds >= 0);
    assert.ok(!Number.isNaN(Date.parse(body.timestamp)));
  });

  it("responses are JSON with the correct content type", async () => {
    for (const path of ["/", "/health", "/api/status"]) {
      const response = await fetch(`${baseUrl}${path}`);

      assert.match(
        response.headers.get("content-type") ?? "",
        /application\/json/,
      );
    }
  });

  it("unknown routes return a JSON 404", async () => {
    const response = await fetch(`${baseUrl}/does-not-exist`);
    const body = await response.json();

    assert.equal(response.status, 404);
    assert.equal(body.error, "not_found");
    assert.ok(body.requestId);
  });

  it("unsupported methods on a known path return 404 rather than 500", async () => {
    const response = await fetch(`${baseUrl}/health`, { method: "POST" });

    assert.equal(response.status, 404);
  });

  it("echoes a safe inbound request id", async () => {
    const response = await fetch(`${baseUrl}/health`, {
      headers: { "x-request-id": "assessment-test-123" },
    });

    assert.equal(response.headers.get("x-request-id"), "assessment-test-123");
  });

  it("generates a request id when none is supplied", async () => {
    const response = await fetch(`${baseUrl}/health`);
    const requestId = response.headers.get("x-request-id");

    assert.match(
      requestId ?? "",
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
    );
  });

  it("ignores an unsafe inbound request id", async () => {
    const response = await fetch(`${baseUrl}/health`, {
      headers: { "x-request-id": "<script>alert(1)</script>" },
    });

    assert.notEqual(
      response.headers.get("x-request-id"),
      "<script>alert(1)</script>",
    );
  });

  it("does not advertise the framework via x-powered-by", async () => {
    const response = await fetch(`${baseUrl}/health`);

    assert.equal(response.headers.get("x-powered-by"), null);
  });

  it("reports 503 on /health while draining", async () => {
    const drainingApp = createApp();
    const drainingServer = await startServer(drainingApp);
    const drainingUrl = `http://127.0.0.1:${drainingServer.address().port}`;

    try {
      drainingApp.beginShutdown();

      const response = await fetch(`${drainingUrl}/health`);
      const body = await response.json();

      assert.equal(response.status, 503);
      assert.deepEqual(body, { status: "draining" });
    } finally {
      await new Promise((resolve) => drainingServer.close(resolve));
    }
  });
});
