import type { FastifyInstance } from "fastify";
import { pool } from "../db.js";

export async function healthRoutes(app: FastifyInstance): Promise<void> {
    /**
     * GET /healthz - shallow liveness. **This is the ALB target group check.**
     *
     * It deliberately does not touch the database. If the health check queried
     * Postgres, a brief RDS hiccup would fail every target at once, the ALB
     * would have nothing healthy to route to, and the Auto Scaling group would
     * start terminating and replacing perfectly good instances - turning a
     * ten-second database blip into a full outage with a cold fleet.
     *
     * The question this endpoint answers is "can this process serve traffic",
     * not "is the whole system well".
     */
    app.get("/healthz", async () => ({ status: "ok" }));

    /**
     * GET /readyz - deep check, including the database.
     *
     * For humans, dashboards and CloudWatch alarms. Never wire this to the
     * target group.
     */
    app.get("/readyz", async (_req, reply) => {
        try {
            const started = Date.now();
            await pool.query("select 1");
            return { status: "ok", database: { ok: true, latencyMs: Date.now() - started } };
        } catch (err) {
            return reply.code(503).send({
                status: "degraded",
                database: { ok: false, error: (err as Error).message },
            });
        }
    });
}
