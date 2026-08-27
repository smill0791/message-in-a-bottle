import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { pool, transaction } from "../db.js";

const idParam = z.object({ id: z.string().uuid() });

/**
 * Moderator guard.
 *
 * Returns 404 rather than 403 for a signed-in non-moderator. There is no
 * reason to confirm to a curious user that a moderation surface exists.
 */
async function requireModerator(req: FastifyRequest, reply: FastifyReply): Promise<void> {
    if (!req.user) {
        await reply.code(404).send({ error: "not found" });
        return;
    }
    const { rows } = await pool.query<{ is_moderator: boolean }>(
        "select is_moderator from users where id = $1",
        [req.user.id],
    );
    if (!rows[0]?.is_moderator) {
        await reply.code(404).send({ error: "not found" });
    }
}

/**
 * `requireModerator` alone, deliberately not chained behind `requireUser`.
 *
 * With `[requireUser, requireModerator]` an anonymous request got 401 "not
 * signed in" - which confirms the endpoint exists to anyone probing for it,
 * defeating the point of answering 404 below. `requireModerator` handles the
 * missing-user case itself, so both anonymous and signed-in non-moderators get
 * an identical 404.
 */
const guard = { preHandler: requireModerator };

export async function adminRoutes(app: FastifyInstance): Promise<void> {
    /**
     * GET /admin/queue - everything awaiting a decision.
     *
     * The queue holds two different things and they need telling apart:
     *
     *   1. New submissions that have never been seen.
     *   2. Messages that were live and got pulled by reports.
     *
     * The second kind is more urgent - it was visible to real people - and it
     * needs the report reasons attached, so a moderator is not guessing what
     * the complaint was. Reported items sort first.
     */
    app.get("/admin/queue", guard, async () => {
        const { rows } = await pool.query(
            `select m.id,
                    m.body,
                    m.created_at,
                    u.handle as author,
                    coalesce(r.open_reports, 0)::int as open_reports,
                    coalesce(r.reasons, '{}') as reasons,
                    coalesce(s.discovery_count, 0) as discovery_count,
                    (m.moderated_at is not null) as previously_reviewed
               from messages m
               join users u on u.id = m.author_id
               left join message_stats s on s.message_id = m.id
               left join (
                    select message_id,
                           count(*) as open_reports,
                           array_agg(distinct reason::text) as reasons
                      from reports
                     where resolved = false
                     group by message_id
               ) r on r.message_id = m.id
              where m.status = 'pending'
              order by coalesce(r.open_reports, 0) desc, m.created_at asc
              limit 100`,
        );

        return { queue: rows };
    });

    /** Counts for the badge, so the UI need not fetch the whole queue. */
    app.get("/admin/summary", guard, async () => {
        const { rows } = await pool.query<{ pending: string; reported: string }>(
            `select count(*) filter (where m.status = 'pending') as pending,
                    count(*) filter (
                        where m.status = 'pending'
                          and exists (select 1 from reports r
                                       where r.message_id = m.id and r.resolved = false)
                    ) as reported
               from messages m`,
        );
        return {
            pending: Number(rows[0]?.pending ?? 0),
            reported: Number(rows[0]?.reported ?? 0),
        };
    });

    /**
     * POST /admin/messages/:id/approve
     *
     * Approving also resolves any outstanding reports. Without that the
     * message sits above the auto-pull threshold and the next single report
     * yanks it straight back off the beach, silently overriding the decision
     * that was just made.
     */
    app.post("/admin/messages/:id/approve", guard, async (req, reply) => {
        const params = idParam.safeParse(req.params);
        if (!params.success) return reply.code(400).send({ error: "bad id" });

        const ok = await transaction(async (tx) => {
            const { rowCount } = await tx.query(
                `update messages
                    set status = 'approved',
                        moderated_at = now(),
                        moderated_by = $2
                  where id = $1
                    and status = 'pending'`,
                [params.data.id, req.user!.id],
            );
            if (rowCount === 0) return false;

            await tx.query(
                "update reports set resolved = true where message_id = $1 and resolved = false",
                [params.data.id],
            );
            return true;
        });

        if (!ok) return reply.code(409).send({ error: "already decided" });
        return { id: params.data.id, status: "approved" };
    });

    /**
     * POST /admin/messages/:id/reject
     *
     * Rejection is reversible - the row stays, the status changes - so a wrong
     * call can be undone. Deleting would also destroy the reports that
     * justified it.
     */
    app.post("/admin/messages/:id/reject", guard, async (req, reply) => {
        const params = idParam.safeParse(req.params);
        if (!params.success) return reply.code(400).send({ error: "bad id" });

        const ok = await transaction(async (tx) => {
            const { rowCount } = await tx.query(
                `update messages
                    set status = 'rejected',
                        moderated_at = now(),
                        moderated_by = $2
                  where id = $1
                    and status = 'pending'`,
                [params.data.id, req.user!.id],
            );
            if (rowCount === 0) return false;

            await tx.query(
                "update reports set resolved = true where message_id = $1 and resolved = false",
                [params.data.id],
            );
            return true;
        });

        if (!ok) return reply.code(409).send({ error: "already decided" });
        return { id: params.data.id, status: "rejected" };
    });
}
