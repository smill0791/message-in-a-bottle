import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { pool, transaction } from "../db.js";
import { config } from "../config.js";
import { requireUser } from "../auth.js";
import { recomputeWeight } from "../lib/weight.js";

const openParams = z.object({ id: z.string().uuid() });

export async function beachRoutes(app: FastifyInstance): Promise<void> {
    /**
     * GET /beach - what is lying in the sand right now.
     *
     * Returns bottle *ids and positions only*, never the message body. The
     * letter is revealed by opening the bottle, which is both the point of the
     * interaction and the moment we record a discovery.
     *
     * The beach is re-sampled on every load. Bottles wash in and out with the
     * tide, so refreshing gives you a different beach - which is the intended
     * feel, not a bug to design around.
     */
    app.get("/beach", { preHandler: requireUser }, async (req) => {
        const user = req.user!;

        // Weighted sampling without replacement. See db/queries/discover.sql
        // for why the ordering key is -ln(random())/weight and what the cost
        // ceiling is.
        const { rows } = await pool.query<{ id: string }>(
            `select m.id
               from messages m
               join message_stats s on s.message_id = m.id
               left join discoveries d
                      on d.message_id = m.id
                     and d.user_id = $1
              where m.status = 'approved'
                and m.author_id <> $1
                and d.id is null
              order by -ln(random()) / s.weight
              limit $2`,
            [user.id, config.BEACH_SIZE],
        );

        return {
            bottles: rows.map((row, index) => ({
                id: row.id,
                // Deterministic-ish scatter so bottles do not overlap. The
                // client owns the actual layout; this is a hint, not a
                // coordinate system.
                slot: index,
            })),
            // An empty beach is a real state, not an error. The client should
            // say something gentle rather than rendering nothing.
            empty: rows.length === 0,
        };
    });

    /**
     * POST /beach/:id/open - uncork it.
     *
     * This is where a discovery is recorded, not at beach load. A user who
     * never opens a bottle has not found it, and it stays in their pool.
     */
    app.post("/beach/:id/open", { preHandler: requireUser }, async (req, reply) => {
        const user = req.user!;
        const params = openParams.safeParse(req.params);
        if (!params.success) {
            return reply.code(400).send({ error: "bad bottle id" });
        }
        const messageId = params.data.id;

        const result = await transaction(async (tx) => {
            // Re-check eligibility inside the transaction. The beach listing
            // is a moment old and the message may have been pulled by
            // moderation since.
            const { rows: msgRows } = await tx.query<{ body: string; created_at: Date }>(
                `select body, created_at
                   from messages
                  where id = $1
                    and status = 'approved'
                    and author_id <> $2`,
                [messageId, user.id],
            );
            const message = msgRows[0];
            if (!message) return null;

            // The unique constraint makes this idempotent: opening a bottle
            // twice records one discovery. Re-opening from the chest is a
            // legitimate action, so this is not an error case.
            const { rowCount } = await tx.query(
                `insert into discoveries (user_id, message_id)
                 values ($1, $2)
                 on conflict (user_id, message_id) do nothing`,
                [user.id, messageId],
            );

            const firstTime = rowCount === 1;

            if (firstTime) {
                await tx.query(
                    `update message_stats
                        set discovery_count = discovery_count + 1,
                            updated_at = now()
                      where message_id = $1`,
                    [messageId],
                );
            }

            return { body: message.body, writtenAt: message.created_at, firstTime };
        });

        if (!result) {
            // Either it never existed or moderation pulled it between the
            // beach render and the click. Same response either way - we do not
            // confirm the existence of unapproved messages.
            return reply.code(404).send({ error: "that bottle is gone" });
        }

        // Discovery count feeds the weight, so recompute outside the
        // transaction. A slightly stale weight is harmless; a slow open is not.
        if (result.firstTime) {
            // `unknown`, not the implicit `any`: a rejection is not guaranteed
            // to be an Error, and reading .message off a thrown string logs
            // undefined - losing the one detail this line exists to capture.
            void recomputeWeight(messageId).catch((err: unknown) => {
                req.log.warn(
                    {
                        err: err instanceof Error ? err.message : String(err),
                        messageId,
                    },
                    "weight recompute failed",
                );
            });
        }

        return {
            id: messageId,
            body: result.body,
            writtenAt: result.writtenAt,
            firstTime: result.firstTime,
        };
    });
}
