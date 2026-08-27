import { pool } from "../db.js";

/**
 * Discovery weight.
 *
 *     weight = (1 + resonated)^0.5 / (1 + discoveries)^0.15
 *
 * The exponents are the whole design, so they are worth defending.
 *
 * **0.5 on resonance.** Linear weighting produces a rich-get-richer collapse:
 * an early message that catches a few readers accumulates resonance, surfaces
 * more, accumulates faster, and within weeks a handful of messages own the
 * beach. Everything written afterwards is buried. The square root keeps
 * well-received messages genuinely advantaged - 100 resonances still beats 4
 * by 5x - without letting the advantage compound away.
 *
 * **0.15 on discoveries.** A gentle rotation so newly written bottles get seen
 * at all. Deliberately weak: a message should not be punished for being good,
 * only nudged aside so the pool keeps breathing.
 *
 * **Reports are absent on purpose.** A message being reported is a moderation
 * question, not a popularity one. Down-weighting on reports would let a small
 * group bury a message they disagree with by reporting it. Reports route to
 * the review queue and either flip status to 'rejected' or they do not.
 */
export function computeWeight(resonatedCount: number, discoveryCount: number): number {
    const lift = Math.pow(1 + Math.max(0, resonatedCount), 0.5);
    const rotation = Math.pow(1 + Math.max(0, discoveryCount), 0.15);
    return lift / rotation;
}

/** Recompute and persist the weight for one message from its current stats. */
export async function recomputeWeight(messageId: string): Promise<number | null> {
    const { rows } = await pool.query<{
        resonated_count: number;
        discovery_count: number;
    }>(
        `select resonated_count, discovery_count
           from message_stats
          where message_id = $1`,
        [messageId],
    );

    const stats = rows[0];
    if (!stats) return null;

    const weight = computeWeight(stats.resonated_count, stats.discovery_count);

    await pool.query(
        `update message_stats
            set weight = $2,
                updated_at = now()
          where message_id = $1`,
        [messageId, weight],
    );

    return weight;
}
