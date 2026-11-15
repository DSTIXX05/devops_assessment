import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";

import { config } from "../src/config.js";
import { logger } from "../src/logger.js";

const originalStdoutWrite = process.stdout.write;
const originalStderrWrite = process.stderr.write;

function capture(stream) {
  const chunks = [];

  stream.write = (chunk) => {
    chunks.push(String(chunk));
    return true;
  };

  return chunks;
}

function restore() {
  process.stdout.write = originalStdoutWrite;
  process.stderr.write = originalStderrWrite;
}

describe("logger", () => {
  afterEach(restore);

  it("emits one JSON object per line on stdout for info", () => {
    const stdout = capture(process.stdout);
    const stderr = capture(process.stderr);

    logger.info("unit test message", { requestId: "abc-123" });

    assert.equal(stderr.length, 0);
    assert.equal(stdout.length, 1);

    const record = JSON.parse(stdout[0]);

    assert.equal(record.level, "info");
    assert.equal(record.message, "unit test message");
    assert.equal(record.requestId, "abc-123");
    assert.equal(record.service, config.serviceName);
    assert.equal(record.environment, config.environment);
    assert.ok(!Number.isNaN(Date.parse(record.timestamp)));
  });

  it("routes warnings and errors to stderr", () => {
    const stdout = capture(process.stdout);
    const stderr = capture(process.stderr);

    logger.warn("a warning");
    logger.error("an error");

    assert.equal(stdout.length, 0);
    assert.equal(stderr.length, 2);
    assert.equal(JSON.parse(stderr[0]).level, "warn");
    assert.equal(JSON.parse(stderr[1]).level, "error");
  });

  it("survives non-serialisable fields without throwing", () => {
    const stdout = capture(process.stdout);
    const circular = {};
    circular.self = circular;

    assert.doesNotThrow(() => logger.info("circular payload", { circular }));

    const record = JSON.parse(stdout[0]);

    assert.equal(record.logError, "fields_not_serialisable");
  });
});
