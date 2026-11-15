/**
 * Process entrypoint.
 *
 * Owns the HTTP listener and the shutdown lifecycle:
 *   1. stop accepting new connections
 *   2. mark the task as draining so /health reports 503
 *   3. close idle keep-alive sockets
 *   4. let in-flight requests finish
 *   5. exit 0, or force exit if the drain timeout is exceeded
 */

import { createApp } from "./app.js";
import { config } from "./config.js";
import { logger } from "./logger.js";

const app = createApp();

const sockets = new Set();

const server = app.listen(config.port, config.host, () => {
  const address = server.address();

  logger.info("server started", {
    host: config.host,
    port:
      typeof address === "object" && address !== null
        ? address.port
        : config.port,
    version: config.version,
    commitSha: config.commitSha,
  });
});

// Node keeps idle keep-alive sockets open, which would otherwise delay
// `server.close()` until the client or the ALB closes them. Node's default
// keep-alive timeout is 5s; the ALB idle timeout is 60s, so the server must
// outlast the ALB to avoid spurious 502s on reused connections.
server.keepAliveTimeout = 65_000;
server.headersTimeout = 66_000;

server.on("connection", (socket) => {
  sockets.add(socket);
  socket.once("close", () => sockets.delete(socket));
});

server.on("error", (error) => {
  logger.error("server error", {
    errorName: error?.name,
    errorMessage: error?.message,
    code: error?.code,
  });
  process.exit(1);
});

let shuttingDown = false;

function shutdown(signal) {
  if (shuttingDown) {
    logger.warn("shutdown already in progress", { signal });
    return;
  }

  shuttingDown = true;
  logger.info("shutdown initiated", {
    signal,
    openConnections: sockets.size,
    timeoutMs: config.shutdownTimeoutMs,
  });

  // Report 503 from /health while draining so the load balancer stops sending
  // new requests here before the listener disappears.
  app.beginShutdown();

  const forceExitTimer = setTimeout(() => {
    logger.error("shutdown timed out; destroying remaining connections", {
      timeoutMs: config.shutdownTimeoutMs,
      openConnections: sockets.size,
    });

    for (const socket of sockets) {
      socket.destroy();
    }

    process.exit(1);
  }, config.shutdownTimeoutMs);

  forceExitTimer.unref();

  server.close((error) => {
    if (error) {
      logger.error("server close failed", {
        errorName: error?.name,
        errorMessage: error?.message,
      });
      process.exit(1);
    }

    clearTimeout(forceExitTimer);
    logger.info("shutdown complete");
    process.exit(0);
  });

  // Release sockets that are idle and will never receive another request.
  server.closeIdleConnections();
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

process.on("unhandledRejection", (reason) => {
  logger.error("unhandled promise rejection", {
    errorName: reason instanceof Error ? reason.name : typeof reason,
    errorMessage: reason instanceof Error ? reason.message : String(reason),
  });

  shutdown("unhandledRejection");
});

process.on("uncaughtException", (error) => {
  logger.error("uncaught exception", {
    errorName: error?.name,
    errorMessage: error?.message,
    stack: error?.stack,
  });

  // An uncaught exception leaves the process in an undefined state; drain and
  // exit rather than continue serving possibly corrupted responses.
  shutdown("uncaughtException");
});
