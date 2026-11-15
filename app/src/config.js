/**
 * Runtime configuration.
 *
 * Everything here is read from the environment at process start so the same
 * image can run locally, in dev, and in prod without being rebuilt.
 * No secrets or AWS resource identifiers belong in this file.
 */

function readInteger(name, fallback, { min, max }) {
  const raw = process.env[name];

  if (raw === undefined || raw === "") {
    return fallback;
  }

  const value = Number(raw);

  if (!Number.isInteger(value) || value < min || value > max) {
    throw new Error(
      `Invalid ${name}: expected an integer between ${min} and ${max}, received "${raw}".`,
    );
  }

  return value;
}

export const config = {
  serviceName: process.env.SERVICE_NAME ?? "devops-assessment-app",
  environment: process.env.APP_ENV ?? process.env.NODE_ENV ?? "development",
  version: process.env.APP_VERSION ?? "0.0.0-local",

  // "unknown" locally; injected at deploy time from the Git commit SHA so that
  // a running task can be traced back to a source revision.
  commitSha: process.env.COMMIT_SHA ?? "unknown",

  // Bind to all interfaces. Binding to localhost would make the container
  // unreachable from the ALB and is a classic container networking mistake.
  host: process.env.HOST ?? "0.0.0.0",

  // Port 0 is permitted so tests can bind an ephemeral port.
  port: readInteger("PORT", 3000, { min: 0, max: 65535 }),

  logLevel: (process.env.LOG_LEVEL ?? "info").toLowerCase(),

  // Time allowed for in-flight requests to drain after SIGTERM before the
  // process is force-terminated. Kept below the ALB deregistration delay so ECS
  // does not need to SIGKILL the container.
  shutdownTimeoutMs: readInteger("SHUTDOWN_TIMEOUT_MS", 10000, {
    min: 0,
    max: 120000,
  }),
};
