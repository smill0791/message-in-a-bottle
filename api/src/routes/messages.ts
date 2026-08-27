import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { transaction } from "../db.js";
import { requireUser } from "../auth.js";
import { screen } from "../lib/screen.js";

export const MAX_BODY = 500;

const newMessage = z.object({
    body: z
        .string()
        .trim()
        .min(1, "write something first")
        .max(MAX_BODY, `${MAX_BODY} characters at most`),
});

export async function messageRoutes(app: FastifyInstance): Promise<void> {
    /**
     * POST /messages - write a message and cork it into a bottle.
     *
     * Messages land as 'pending' and are not discoverable until approved. In
     * Phase 4 this becomes an SQS publish feeding a Lambda classifier; for now
     * the denylist screens the obvious cases and everything else queues for
     * review.
     */
    app.post("/messages", { preHandler: requireUser }, async (req, reply) => {
        const user = req.user!;
        const parsed = newMessage.safeParse(req.body);
        if (!parsed.success) {
            return reply.code(400).send({ error: parsed.error.issues[0]?.message ?? "invalid" });
        }
        const body = parsed.data.body;

        const verdict = screen(body);
        if (verdict.decision === "reject") {
            return reply.code(422).send({
                error: "that one cannot go in a bottle",
                reason: verdict.reason,
            });
        }

        const id = await transaction(async (tx) => {
            const { rows } = await tx.query<{ id: string }>(
                `insert into messages (author_id, body, status)
                 values ($1, $2, 'pending')
                 returning id`,
                [user.id, body],
            );
            const messageId = rows[0]!.id;

            // Stats row is created alongside the message so the discovery
            // query's inner join never has to worry about a missing row.
            await tx.query(
                "insert into message_stats (message_id) values ($1)",
                [messageId],
            );

            return messageId;
        });

        return reply.code(201).send({
            id,
            status: "pending",
            // Set expectations. A bottle that vanishes with no explanation
            // reads as the app being broken.
            message: "Your bottle is sealed. It goes out with the next tide, once reviewed.",
        });
    });

    /** GET /messages/mine - what this user has written, and where it stands. */
    app.get("/messages/mine", { preHandler: requireUser }, async (req) => {
        const user = req.user!;
        const { rows } = await transaction(async (tx) =>
            tx.query<{
                id: string;
                body: string;
                status: string;
                created_at: Date;
                discovery_count: number;
                resonated_count: number;
            }>(
                `select m.id, m.body, m.status, m.created_at,
                        coalesce(s.discovery_count, 0) as discovery_count,
                        coalesce(s.resonated_count, 0) as resonated_count
                   from messages m
                   left join message_stats s on s.message_id = m.id
                  where m.author_id = $1
                  order by m.created_at desc`,
                [user.id],
            ),
        );

        return { messages: rows };
    });
}
