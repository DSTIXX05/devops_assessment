/**
 * API documentation.
 *
 * The OpenAPI document is a plain object in the source tree, and the viewer is
 * loaded from a pinned CDN build.
 *
 * Deliberately dependency-free: `swagger-ui-express` would add a package tree to
 * the runtime image, which the Trivy gate would then scan and could block a
 * deployment on. Documentation should not be able to fail a release.
 */

export const openapiDocument = {
  openapi: "3.0.3",

  info: {
    title: "DevOps Assessment API",
    version: "1.0.0",
    description:
      "Small stateless Node.js/Express service deployed to Amazon ECS on Fargate " +
      "behind an Application Load Balancer. It exists to provide a realistic " +
      "container workload for demonstrating infrastructure as code, CI/CD, " +
      "container hardening and observability.",
  },

  servers: [
    {
      url: "/",
      description:
        "Same origin as this page - the ALB in front of the current environment",
    },
  ],

  tags: [
    { name: "Operations", description: "Health and runtime information" },
    { name: "API", description: "Application endpoints" },
  ],

  paths: {
    "/": {
      get: {
        tags: ["API"],
        summary: "Service information",
        description:
          "Returns the service name, a short message and the environment.",
        responses: {
          200: {
            description: "Service is running",
            content: {
              "application/json": {
                schema: { $ref: "#/components/schemas/ServiceInfo" },
                example: {
                  service: "devops-assessment-dev-app",
                  message: "DevOps assessment API is running.",
                  environment: "dev",
                  version: "1.0.0",
                },
              },
            },
          },
        },
      },
    },

    "/health": {
      get: {
        tags: ["Operations"],
        summary: "Load balancer and container health check",
        description:
          "Returns 200 while the process is ready to receive traffic. Returns 503 " +
          "once shutdown has begun, so the load balancer stops routing here before " +
          "the listener closes.",
        responses: {
          200: {
            description: "Ready",
            content: {
              "application/json": {
                schema: { $ref: "#/components/schemas/Health" },
                example: { status: "ok" },
              },
            },
          },
          503: {
            description: "Draining - the task is shutting down",
            content: {
              "application/json": {
                schema: { $ref: "#/components/schemas/Health" },
                example: { status: "draining" },
              },
            },
          },
        },
      },
    },

    "/api/status": {
      get: {
        tags: ["Operations"],
        summary: "Runtime status",
        description:
          "Reports the commit SHA the process was built from. This is how a " +
          "deployment is proven to be running the revision that was intended, " +
          "rather than merely a revision.",
        responses: {
          200: {
            description: "Status payload",
            content: {
              "application/json": {
                schema: { $ref: "#/components/schemas/Status" },
                example: {
                  status: "ok",
                  service: "devops-assessment-dev-app",
                  environment: "dev",
                  version: "1.0.0",
                  commitSha: "31db5e5a1b08158befa18b53a21022fb03c8630f",
                  nodeVersion: "v24.14.1",
                  uptimeSeconds: 291.77,
                  timestamp: "2026-11-16T05:02:09.363Z",
                },
              },
            },
          },
        },
      },
    },

    "/api/echo": {
      post: {
        tags: ["API"],
        summary: "Echo a message",
        description:
          "Validates and returns the supplied message. Exists to exercise request " +
          "parsing, validation and error mapping rather than only returning static " +
          "data.",
        requestBody: {
          required: true,
          content: {
            "application/json": {
              schema: { $ref: "#/components/schemas/EchoRequest" },
              example: { message: "hello" },
            },
          },
        },
        responses: {
          200: {
            description: "Message accepted",
            content: {
              "application/json": {
                schema: { $ref: "#/components/schemas/EchoResponse" },
                example: {
                  status: "ok",
                  message: "hello",
                  length: 5,
                  receivedAt: "2026-11-16T05:02:09.363Z",
                },
              },
            },
          },
          400: {
            description:
              "validation_failed when message is missing, not a string, blank or " +
              "longer than 500 characters; invalid_json when the body is not " +
              "parseable JSON",
            content: {
              "application/json": {
                schema: { $ref: "#/components/schemas/Error" },
                examples: {
                  validationFailed: {
                    value: {
                      error: "validation_failed",
                      message:
                        '"message" is required and must be a non-empty string.',
                      requestId: "dabdac7f-e21e-4340-a294-ae160215529f",
                    },
                  },
                  invalidJson: {
                    value: {
                      error: "invalid_json",
                      message: "Request body must be valid JSON.",
                      requestId: "268168b8-2180-4814-ad64-a1e9c5826e21",
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
  },

  components: {
    schemas: {
      Health: {
        type: "object",
        required: ["status"],
        properties: {
          status: { type: "string", enum: ["ok", "draining"] },
        },
      },

      ServiceInfo: {
        type: "object",
        properties: {
          service: { type: "string" },
          message: { type: "string" },
          environment: { type: "string", example: "dev" },
          version: { type: "string" },
        },
      },

      Status: {
        type: "object",
        properties: {
          status: { type: "string", example: "ok" },
          service: { type: "string" },
          environment: { type: "string" },
          version: { type: "string" },
          commitSha: {
            type: "string",
            description: "Git commit the image was built from",
          },
          nodeVersion: { type: "string", example: "v24.14.1" },
          uptimeSeconds: { type: "number" },
          timestamp: { type: "string", format: "date-time" },
        },
      },

      EchoRequest: {
        type: "object",
        required: ["message"],
        properties: {
          message: {
            type: "string",
            minLength: 1,
            maxLength: 500,
            description:
              "Non-empty message. Surrounding whitespace is trimmed.",
          },
        },
      },

      EchoResponse: {
        type: "object",
        properties: {
          status: { type: "string", example: "ok" },
          message: { type: "string" },
          length: { type: "integer", description: "Length after trimming" },
          receivedAt: { type: "string", format: "date-time" },
        },
      },

      Error: {
        type: "object",
        properties: {
          error: { type: "string" },
          message: { type: "string" },
          requestId: {
            type: "string",
            description:
              "Correlation id, also echoed in the x-request-id header",
          },
        },
      },
    },
  },
};

// Pinned versions matter here: the viewer is loaded by the browser, so a
// floating tag would mean an unannounced third-party script executing against
// the API in a reviewer's browser.
const SWAGGER_UI_VERSION = "5.17.14";

export const swaggerUiPage = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>DevOps Assessment API - reference</title>
    <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@${SWAGGER_UI_VERSION}/swagger-ui.css" />
    <style>
      body { margin: 0; font-family: system-ui, sans-serif; }
      .banner {
        padding: 0.75rem 1.25rem;
        background: #1f2937;
        color: #f9fafb;
        font-size: 0.875rem;
      }
      .banner a { color: #93c5fd; }
    </style>
  </head>
  <body>
    <div class="banner">
      Interactive reference for the assessment API.
      The raw specification is at <a href="/openapi.json">/openapi.json</a>.
    </div>
    <div id="swagger-ui"></div>
    <script src="https://unpkg.com/swagger-ui-dist@${SWAGGER_UI_VERSION}/swagger-ui-bundle.js"></script>
    <script>
      window.ui = SwaggerUIBundle({
        url: "/openapi.json",
        dom_id: "#swagger-ui",
        deepLinking: true,
        displayRequestDuration: true,
        tryItOutEnabled: true,
      });
    </script>
  </body>
</html>
`;
