/**
 * Minimal structured logger.
 *
 * Emits one JSON object per line so the ECS `awslogs` driver ships
 * machine-parseable records to CloudWatch. Deliberately dependency-free: the
 * assessment does not need a logging framework, and fewer dependencies means a
 * smaller image and a smaller vulnerability surface for the Trivy gate.
 */

import { config } from "./config.js";

const LEVELS = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
};

const threshold = LEVELS[config.logLevel] ?? LEVELS.info;

function emit(level, message, fields = {}) {
  if (LEVELS[level] < threshold) {
    return;
  }

  const record = {
    timestamp: new Date().toISOString(),
    level,
    message,
    service: config.serviceName,
    environment: config.environment,
    ...fields,
  };

  let line;

  try {
    line = JSON.stringify(record);
  } catch {
    // Circular or otherwise unserialisable fields must never crash the app.
    line = JSON.stringify({
      timestamp: record.timestamp,
      level,
      message,
      service: record.service,
      environment: record.environment,
      logError: "fields_not_serialisable",
    });
  }

  // Warnings and errors go to stderr, everything else to stdout. Both streams
  // are captured by the awslogs driver.
  const stream = LEVELS[level] >= LEVELS.warn ? process.stderr : process.stdout;
  stream.write(`${line}\n`);
}

export const logger = {
  debug: (message, fields) => emit("debug", message, fields),
  info: (message, fields) => emit("info", message, fields),
  warn: (message, fields) => emit("warn", message, fields),
  error: (message, fields) => emit("error", message, fields),
};
