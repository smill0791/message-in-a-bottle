import { test, describe } from "node:test";
import assert from "node:assert/strict";

/**
 * weight.ts imports the database module, which builds a connection pool at
 * import time and reads DATABASE_URL from config. Constructing a pool does not
 * open a socket, so a placeholder is enough - but it has to be set before the
 * import is evaluated, hence the dynamic import.
 *
 * This keeps `npm test` runnable with no database and no environment, which is
 * the difference between a suite that runs on every push and one that gets
 * skipped.
 */
process.env["DATABASE_URL"] ??= "postgres://unused:unused@127.0.0.1:5432/unused";
const { computeWeight } = await import("./weight.js");

/**
 * These tests exist to defend the *shape* of the curve, not specific numbers.
 *
 * The exponents in computeWeight are the core of how the beach feels over
 * time, and they are the kind of thing a later change tunes casually. Each
 * test below corresponds to a design claim documented on the function itself;
 * if one fails, either the curve regressed or the documented intent changed.
 */
describe("computeWeight", () => {
    test("more resonance means more weight", () => {
        assert.ok(computeWeight(10, 0) > computeWeight(1, 0));
        assert.ok(computeWeight(100, 0) > computeWeight(10, 0));
    });

    test("resonance is sub-linear, which is what prevents a rich-get-richer collapse", () => {
        // Linear weighting would make 100 resonances worth 20x four of them,
        // and within weeks a handful of early messages would own the beach.
        const strong = computeWeight(100, 0);
        const modest = computeWeight(4, 0);
        const ratio = strong / modest;

        assert.ok(ratio > 4, `expected a real advantage, got ${ratio}x`);
        assert.ok(ratio < 6, `expected sub-linear growth, got ${ratio}x`);
    });

    test("being discovered gently lowers weight, so the pool keeps breathing", () => {
        assert.ok(computeWeight(5, 100) < computeWeight(5, 0));
    });

    test("the discovery penalty is weak enough that quality still wins", () => {
        // A well-received but frequently-seen message must still outrank an
        // unseen mediocre one. If this inverts, good writing gets buried for
        // the crime of having been read.
        const goodAndSeen = computeWeight(50, 200);
        const unremarkableAndFresh = computeWeight(0, 0);

        assert.ok(
            goodAndSeen > unremarkableAndFresh,
            `seen-but-loved ${goodAndSeen} should beat fresh-but-unrated ${unremarkableAndFresh}`,
        );
    });

    test("a brand new message has a usable, non-zero weight", () => {
        // Weight zero means never selected, which would make new bottles
        // undiscoverable and the pool would never grow.
        const fresh = computeWeight(0, 0);
        assert.ok(fresh > 0, `a new bottle must be discoverable, got ${fresh}`);
        assert.ok(Number.isFinite(fresh));
    });

    test("weight is always finite and positive", () => {
        const cases: Array<[number, number]> = [
            [0, 0],
            [0, 10_000],
            [10_000, 0],
            [10_000, 10_000],
            [1, 1],
        ];

        for (const [resonated, discoveries] of cases) {
            const w = computeWeight(resonated, discoveries);
            assert.ok(
                Number.isFinite(w) && w > 0,
                `computeWeight(${resonated}, ${discoveries}) = ${w}`,
            );
        }
    });
});
