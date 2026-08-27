import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { pool, transaction } from "../db.js";
import { requireUser } from "../auth.js";
import { recomputeWeight } from "../lib/weight.js";

const idParam = z.object({ id: z.string().uuid() });

const THEMES = [
    "encouraging",
    "uplifting",
    "reflective",
    "grateful",
    "hopeful",
    "sad",
] as const;

const rating = z.object({
    theme: z.enum(THEMES),
    // Did this land for you? Distinct from theme. A sad message can absolutely
    // resonate - that is the entire premise - so this is not a quality score
    // and "sad" is not a downvote.
    resonated: z.boolean().default(false),
});

const keepBody = z.object({ saved: z.boolean() });
const favouriteBody = z.object({ favorited: z.boolean() });

export async function chestRoutes(app: FastifyInstance): Promise<void> {
    /** GET /chest - the messages this user has kept. */
    app.get("/chest", { preHandler: requireUser }, async (req) => {
        const user = req.user!;
        const { rows } = await pool.query(
            `select m.id, m.body, d.discovered_at, d.favorited, r.theme
               from discoveries d
               join messages m on m.id = d.message_id
               left join ratings r on r.message_id = d.message_id and r.user_id = d.user_id
              where d.user_id = $1
                and d.saved = true
              order by d.favorited desc, d.discovered_at desc`,
            [user.id],
        );
        return { messages: rows };
    });

    /**
     * PUT /chest/:id - keep a bottle, or put it back in the sea.
     *
     * Putting one back removes it from the chest but keeps the discovery row.
     * The bottle does not return to this user's beach - it was found, and that
     * does not un-happen.
     */
    app.put("/chest/:id", { preHandler: requireUser }, async (req, reply) => {
        const user = req.user!;
        const params = idParam.safeParse(req.params);
        const body = keepBody.safeParse(req.body);
        if (!params.success || !body.success) {
            return reply.code(400).send({ error: "invalid request" });
        }

        const { rowCount } = await pool.query(
            `update discoveries
                set saved = $3
              where user_id = $1
                and message_id = $2`,
            [user.id, params.data.id, body.data.saved],
        );

        if (rowCount === 0) {
            return reply.code(404).send({ error: "you have not found that bottle" });
        }
        return { id: params.data.id, saved: body.data.saved };
    });

    app.put("/chest/:id/favorite", { preHandler: requireUser }, async (req, reply) => {
        const user = req.user!;
        const params = idParam.safeParse(req.params);
        const body = favouriteBody.safeParse(req.body);
        if (!params.success || !body.success) {
            return reply.code(400).send({ error: "invalid request" });
        }

        // Favouriting implies keeping. Otherwise a favourite silently vanishes
        // from the chest, which reads as data loss.
        const { rowCount } = await pool.query(
            `update discoveries
                set favorited = $3,
                    saved = saved or $3
              where user_id = $1
                and message_id = $2`,
            [user.id, params.data.id, body.data.favorited],
        );

        if (rowCount === 0) {
            return reply.code(404).send({ error: "you have not found that bottle" });
        }
        return { id: params.data.id, favorited: body.data.favorited };
    });

    /**
     * PUT /chest/:id/rating - how did this land?
     *
     * Theme classification, not quality scoring. Only `resonated` feeds the
     * discovery weight; the theme is for the author and for future filtering.
     */
    app.put("/chest/:id/rating", { preHandler: requireUser }, async (req, reply) => {
        const user = req.user!;
        const params = idParam.safeParse(req.params);
        const body = rating.safeParse(req.body);
        if (!params.success || !body.success) {
            return reply.code(400).send({ error: "invalid rating" });
        }
        const messageId = params.data.id;

        const changed = await transaction(async (tx) => {
            const { rows: found } = await tx.query(
                "select 1 from discoveries where user_id = $1 and message_id = $2",
                [user.id, messageId],
            );
            if (found.length === 0) return null;

            // Was there a prior resonance? Needed to keep the counter correct
            // when a user changes their mind.
            const { rows: prior } = await tx.query<{ resonated: boolean }>(
                "select resonated from ratings where user_id = $1 and message_id = $2",
                [user.id, messageId],
            );
            const wasResonated = prior[0]?.resonated ?? false;

            await tx.query(
                `insert into ratings (user_id, message_id, theme, resonated)
                 values ($1, $2, $3, $4)
                 on conflict (user_id, message_id)
                 do update set theme = excluded.theme,
                               resonated = excluded.resonated,
                               created_at = now()`,
                [user.id, messageId, body.data.theme, body.data.resonated],
            );

            const delta = Number(body.data.resonated) - Number(wasResonated);
            await tx.query(
                `update message_stats
                    set resonated_count = greatest(0, resonated_count + $2),
                        rating_count = rating_count + $3,
                        updated_at = now()
                  where message_id = $1`,
                [messageId, delta, prior.length === 0 ? 1 : 0],
            );

            return true;
        });

        if (!changed) {
            return reply.code(404).send({ error: "you have not found that bottle" });
        }

        await recomputeWeight(messageId);
        return { id: messageId, theme: body.data.theme, resonated: body.data.resonated };
    });
}
