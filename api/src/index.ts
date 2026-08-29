import Fastify from "fastify";
import cookie from "@fastify/cookie";
import fastifyStatic from "@fastify/static";
import { config } from "./config.js";
import { pool } from "./db.js";
import { loadUser } from "./auth.js";
import { healthRoutes } from "./routes/health.js";
import { authRoutes } from "./routes/auth.js";
import { messageRoutes } from "./routes/messages.js";
import { beachRoutes } from "./routes/beach.js";
import { chestRoutes } from "./routes/chest.js";
import { reportRoutes } from "./routes/reports.js";
import { adminRoutes } from "./routes/admin.js";

export async function build() {
    const app = Fastify({
        logger: {
            level: config.NODE_ENV === "production" ? "info" : "debug",
            // JSON lines in production so the CloudWatch agent can ship these
            // without a parsing rule.
            ...(config.NODE_ENV === "development"
                ? { transport: { target: "pino-pretty" } }
                : {}),
        },
        // The ALB sets X-Forwarded-For and X-Forwarded-Proto. Without this,
        // every request appears to come from the load balancer's private IP
        // and `request.protocol` reads http even on an HTTPS listener.
        trustProxy: true,
        disableRequestLogging: false,
    });

    await app.register(cookie);

    // Resolve the session on every request. Routes that require a user add
    // `requireUser` as a preHandler.
    app.addHook("preHandler", loadUser);

    await app.register(healthRoutes);
    await app.register(authRoutes);
    await app.register(messageRoutes);
    await app.register(beachRoutes);
    await app.register(chestRoutes);
    await app.register(reportRoutes);
    await app.register(adminRoutes);

    /**
     * Serve the built frontend from the same origin as the API.
     *
     * One origin means one target group, no CORS preflights, and no separate
     * CloudFront distribution to keep in sync. Registered last so it never
     * shadows an API route.
     */
    if (config.STATIC_DIR) {
        await app.register(fastifyStatic, { root: config.STATIC_DIR });

        // Single-page app: anything that is not an API route or a real file
        // returns index.html and lets the client router decide. Without this a
        // refresh on any path other than / returns 404.
        app.setNotFoundHandler((req, reply) => {
            if (req.method !== "GET" || req.url.startsWith("/api")) {
                return reply.code(404).send({ error: "not found" });
            }
            return reply.sendFile("index.html");
        });
    }

    return app;
}

async function main() {
    const app = await build();

    /**
     * Graceful shutdown matters here specifically because of the Auto Scaling
     * group. When an instance is terminated during a scale-in or an instance
     * refresh, the ALB stops sending new requests but in-flight ones must
     * finish. Exiting immediately on SIGTERM returns 502s to real users during
     * every deploy.
     */
    const close = async (signal: string) => {
        app.log.info({ signal }, "shutting down");
        try {
            await app.close();
            await pool.end();
            process.exit(0);
        } catch (err) {
            app.log.error({ err }, "error during shutdown");
            process.exit(1);
        }
    };

    process.on("SIGTERM", () => void close("SIGTERM"));
    process.on("SIGINT", () => void close("SIGINT"));

    await app.listen({ port: config.PORT, host: config.HOST });
}

// Only start a server when run directly, so tests can import `build()`.
if (import.meta.url === `file://${process.argv[1]}`) {
    main().catch((err) => {
        console.error(err);
        process.exit(1);
    });
}
