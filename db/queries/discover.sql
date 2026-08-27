-- Bottle discovery
--
-- Select N approved messages that this user has never seen, sampled with
-- probability proportional to each message's weight.
--
-- This is the hot path, the endpoint worth load testing, and the thing most
-- likely to be asked about in an interview. It deserves the commentary.

-- ===========================================================================
-- v1 - weighted reservoir sampling in a single pass
-- ===========================================================================
--
-- The ordering key is the Efraimidis-Spirakis weighted sampling key. For each
-- eligible row draw u ~ Uniform(0,1) and compute:
--
--     key = -ln(u) / weight
--
-- Taking the k smallest keys yields a correct weighted sample WITHOUT
-- replacement, in one pass, with no precomputation. A message with weight 4
-- is exactly four times as likely to surface as one with weight 1.
--
-- Why not the obvious alternatives:
--   * `ORDER BY random() LIMIT n` ignores weight entirely.
--   * `WHERE weight >= random() * max_weight` is rejection sampling - it
--     biases toward heavy messages and returns fewer than n rows at random.
--   * Picking one row n times means n round trips and allows duplicates.
--
-- Cost: O(eligible pool). Comfortable to roughly 100k approved messages,
-- which this app will not reach for a long time. The upgrade path is below,
-- and the point of writing it down is to know the ceiling before hitting it.

select m.id,
       m.body,
       m.created_at,
       s.weight
from messages m
    join message_stats s on s.message_id = m.id
    left join discoveries d
        on d.message_id = m.id
       and d.user_id = $1
where m.status = 'approved'
  and m.author_id <> $1     -- you do not find your own bottles
  and d.id is null          -- and never the same bottle twice
order by -ln(random()) / s.weight
limit $2;

-- ===========================================================================
-- Weight model
-- ===========================================================================
--
-- Recomputed when ratings or reports change, not at read time:
--
--     weight = 1.0
--            * (1 + resonated_count)^0.5      -- resonance lifts, sublinearly
--            / (1 + discovery_count)^0.15     -- gentle rotation of the pool
--
-- The square root matters. Linear weighting produces a rich-get-richer
-- collapse where a handful of early messages crowd out everything else. The
-- exponent keeps well-received messages advantaged without letting them own
-- the beach.
--
-- The discovery_count divisor is deliberately weak. It rotates the pool so new
-- messages get seen, without punishing a message for being good.
--
-- Reports drive weight toward zero and eventually flip status to 'rejected';
-- they are handled by the moderation pipeline, not this formula.

-- ===========================================================================
-- v2 upgrade path - only if the pool actually grows
-- ===========================================================================
--
-- The scan becomes the bottleneck long before the sampling maths does. In
-- order of how far each gets you:
--
-- 1. Partial index on the eligible pool. Already in place via
--    `messages_pool_idx`. Cheapest win.
--
-- 2. Materialized candidate pool. Refresh a table of the top ~10k messages by
--    weight on a schedule, sample from that. Discovery stops scanning the full
--    pool. Costs freshness, which does not matter here - a bottle written five
--    minutes ago need not be findable instantly.
--
-- 3. Cumulative-weight index. Store a running weight total per row, draw a
--    random point in [0, total), find it with a btree range scan. O(log n) per
--    sample, but the anti-join against `discoveries` no longer composes
--    cleanly and needs oversample-and-filter.
--
-- Do not build 2 or 3 until a load test shows 1 is not enough. Note in the
-- write-up where that threshold actually landed.
