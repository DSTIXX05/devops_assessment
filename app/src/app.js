/**
 * Express application factory.
 *
 * The app is created without binding a port so tests can drive it directly and
 * `server.js` stays responsible for the process lifecycle.
 */

import crypto from "node:crypto";

import express from "express";

import { config } from "./config.js";
import { logger } from "./logger.js";

const startedAt = Date.now();

// Upper bound for the echo endpoint. Keeps a single request from buffering an
// unbounded body into memory.
const MAX_ECHO_LENGTH = 500;

const REQUEST_ID_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/;

/**
 * Accept an upstream request id when it is safe to echo, otherwise generate
 * one. This keeps a single correlation id across the ALB, app logs, and client
 * reports without trusting arbitrary caller input.
 */
function correlationMiddleware(req, res, next) {
  const inbound = req.get("x-request-id");
  req.id =
    typeof inbound === "string" && REQUEST_ID_PATTERN.test(inbound)
      ? inbound
      : crypto.randomUUID();

  res.set("x-request-id", req.id);
  next();
}

/**
 * One structured access-log line per completed request. Request bodies and
 * headers are never logged, so tokens and credentials cannot leak into
 * CloudWatch.
 */
function accessLogMiddleware(req, res, next) {
  const start = process.hrtime.bigint();

  res.on("finish", () => {
    const durationMs = Number(process.hrtime.bigint() - start) / 1e6;

    logger.info("request completed", {
      requestId: req.id,
      method: req.method,
      path: req.originalUrl,
      status: res.statusCode,
      durationMs: Math.round(durationMs * 100) / 100,
    });
  });

  next();
}

export function createApp() {
  const app = express();

  // Do not advertise the framework version.
  app.disable("x-powered-by");

  // Flipped by the shutdown handler so the ALB and ECS can see that this task
  // is draining and should stop receiving new traffic.
  let draining = false;
  app.beginShutdown = () => {
    draining = true;
  };
  app.isDraining = () => draining;

  app.use(correlationMiddleware);
  app.use(accessLogMiddleware);

  // JSON bodies only, with a small limit. Nothing else is accepted because no
  // endpoint needs it.
  app.use(express.json({ limit: "16kb" }));

  // Basic service information.
  app.get("/", (req, res) => {
    res.status(200).json({
      service: config.serviceName,
      message: "DevOps assessment API is running.",
      environment: config.environment,
      version: config.version,
    });
  });

  // Load balancer target health and container health check.
  // Returns 503 once shutdown has begun so the target is removed from rotation
  // instead of accepting traffic that is about to disappear.
  app.get("/health", (req, res) => {
    if (draining) {
      res.status(503).json({ status: "draining" });
      return;
    }

    res.status(200).json({ status: "ok" });
  });

  // Runtime status payload for operational verification.
  app.get("/api/status", (req, res) => {
    res.status(200).json({
      status: "ok",
      service: config.serviceName,
      environment: config.environment,
      version: config.version,
      commitSha: config.commitSha,
      nodeVersion: process.version,
      uptimeSeconds: Math.round(((Date.now() - startedAt) / 1000) * 100) / 100,
      timestamp: new Date().toISOString(),
    });
  });

  // Echo endpoint: exercises request parsing, validation and error mapping end
  // to end, rather than only returning static data.
  //
  // Request:  { "message": "<non-empty string>" }
  // Response: 200 { status, message, length, receivedAt }
  //           400 { error: "validation_failed", message, requestId }
  app.post("/api/echo", (req, res) => {
    const raw = req.body?.message;

    if (typeof raw !== "string" || raw.trim() === "") {
      res.status(400).json({
        error: "validation_failed",
        message: '"message" is required and must be a non-empty string.',
        requestId: req.id,
      });
      return;
    }

    const message = raw.trim();

    if (message.length > MAX_ECHO_LENGTH) {
      res.status(400).json({
        error: "validation_failed",
        message: `"message" must be at most ${MAX_ECHO_LENGTH} characters.`,
        requestId: req.id,
      });
      return;
    }

    res.status(200).json({
      status: "ok",
      message,
      length: message.length,
      receivedAt: new Date().toISOString(),
    });
  });

  // Consistent JSON 404 rather than the Express HTML default.
  app.use((req, res) => {
    res.status(404).json({
      error: "not_found",
      message: `No route matches ${req.method} ${req.originalUrl}`,
      requestId: req.id,
    });
  });

  // Central error handler. Logs the failure and returns a generic message so
  // internal details are not exposed to callers.
  // eslint-disable-next-line no-unused-vars -- Express identifies error handlers by arity.
  app.use((err, req, res, next) => {
    // Malformed JSON is a client error, not a server error. The body parser
    // throws before any route handler runs, so it arrives here rather than
    // being caught per-route.
    if (err?.type === "entity.parse.failed") {
      logger.warn("invalid JSON request body", {
        requestId: req.id,
        method: req.method,
        path: req.originalUrl,
      });

      res.status(400).json({
        error: "invalid_json",
        message: "Request body must be valid JSON.",
        requestId: req.id,
      });
      return;
    }

    logger.error("unhandled request error", {
      requestId: req.id,
      method: req.method,
      path: req.originalUrl,
      errorName: err?.name,
      errorMessage: err?.message,
    });

    if (res.headersSent) {
      return;
    }

    res.status(500).json({
      error: "internal_error",
      message: "An unexpected error occurred.",
      requestId: req.id,
    });
  });

  return app;
}
