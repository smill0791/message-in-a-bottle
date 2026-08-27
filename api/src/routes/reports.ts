import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { transaction } from "../db.js";
import { requireUser } from "../auth.js";

const idParam = z.object({ id: z.string().uuid() });

const report = z.object({
    reason: z.enum(["hateful", "spam", "harassment", "off_vibe", "other"]),
    note: z.string().trim().max(300).optional(),
});

/**
 * How many distinct reports pull a message from the pool automatically.
 *
 * Three is a compromise. Lower, and a small group can bury a message they
 * merely dislike. Higher, and something genuinely hateful stays discoverable
 * for too long. Auto-pull sets status back to 'pending' - it hides the message
 * pending review rather than deleting it, so a wrong call is reversible.
 */
const AUTO_PULL_THRESHOLD = 3;

export async function reportRoutes(app: FastifyInstance): Promise<void> {
    app.post("/messages/:id/report", { preHandler: requireUser }, async (req, reply) => {
        const user = req.user!;
        const params = idParam.safeParse(req.params);
        const body = report.safeParse(req.body);
        if (!params.success || !body.success) {
            return reply.code(400).send({ error: "invalid report" });
        }
        const messageId = params.data.id;

        const outcome = await transaction(async (tx) => {
            // You can only report something you actually found. Otherwise the
            // endpoint is a way to attack messages you have never seen.
            const { rows: found } = await tx.query(
                "select 1 from discoveries where user_id = $1 and message_id = $2",
                [user.id, messageId],
            );
            if (found.length === 0) return null;

            const { rowCount } = await tx.query(
                `insert into reports (reporter_id, message_id, reason, note)
                 values ($1, $2, $3, $4)
                 on conflict (reporter_id, message_id) do nothing`,
                [user.id, messageId, body.data.reason, body.data.note ?? null],
            );

            // Already reported by this user. Report once, count once.
            if (rowCount === 0) return { pulled: false, duplicate: true };

            // Lifetime counter. Useful signal about a message's history, but
            // deliberately not what the threshold reads.
            await tx.query(
                `update message_stats
                    set report_count = report_count + 1,
                        updated_at = now()
                  where message_id = $1`,
                [messageId],
            );

            // The threshold counts *unresolved* reports only.
            //
            // Reading the lifetime counter meant a moderator's decision never
            // stuck: approve a message that had been reported three times, and
            // the very next report re-pulled it instantly, because the counter
            // still said four. Approving clears the reports, so a re-pull needs
            // genuinely new complaints.
            const { rows: counted } = await tx.query<{ open_reports: string }>(
                `select count(*) as open_reports
                   from reports
                  where message_id = $1
                    and resolved = false`,
                [messageId],
            );

            const total = Number(counted[0]?.open_reports ?? 0);

            if (total >= AUTO_PULL_THRESHOLD) {
                await tx.query(
                    `update messages
                        set status = 'pending'
                      where id = $1
                        and status = 'approved'`,
                    [messageId],
                );
                return { pulled: true, duplicate: false };
            }

            return { pulled: false, duplicate: false };
        });

        if (!outcome) {
            return reply.code(404).send({ error: "you have not found that bottle" });
        }

        // Same response whether or not the report tipped the threshold. A
        // reporter learning they triggered a pull would tell a coordinated
        // group exactly how many accounts they need.
        return reply.code(202).send({
            ok: true,
            message: "Thank you. Someone will take a look at this.",
        });
    });
}
