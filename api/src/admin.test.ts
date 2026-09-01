import { test, describe } from "node:test";
import assert from "node:assert/strict";

// admin.ts imports the database module, which builds a pool at import time and
// reads DATABASE_URL. Constructing a pool opens no socket, so a placeholder is
// enough - but it must be set before the import is evaluated.
process.env["DATABASE_URL"] ??= "postgres://unused:unused@127.0.0.1:5432/unused";
const { parseSeedFile } = await import("./admin.js");

/**
 * The seed file is written by hand and read by a machine, which is exactly
 * where formats go wrong. These tests pin the parts a person editing prose
 * would reasonably expect: comments work, spacing is forgiven, and nothing is
 * silently dropped or cut short.
 */
describe("parseSeedFile", () => {
    test("reads one message per line", () => {
        const out = parseSeedFile("first message\nsecond message\nthird message");
        assert.deepEqual(out, ["first message", "second message", "third message"]);
    });

    test("ignores comments and blank lines", () => {
        const out = parseSeedFile(
            ["# a heading", "", "a real message", "   ", "# another note", "another message", ""].join("\n"),
        );
        assert.deepEqual(out, ["a real message", "another message"]);
    });

    test("trims surrounding whitespace", () => {
        assert.deepEqual(parseSeedFile("   padded message   "), ["padded message"]);
    });

    test("a file of only comments yields nothing", () => {
        assert.deepEqual(parseSeedFile("# just\n# comments\n\n"), []);
    });

    test("does not treat a mid-line # as a comment", () => {
        // Otherwise a message could lose its ending to something that only
        // looks like syntax.
        assert.deepEqual(parseSeedFile("a thought # not a comment"), ["a thought # not a comment"]);
    });

    test("accepts a message of exactly the limit", () => {
        const exact = "x".repeat(500);
        assert.deepEqual(parseSeedFile(exact), [exact]);
    });

    /**
     * The important one.
     *
     * Truncating at 500 characters would cut the ending off a message, which
     * in this app is usually the whole point of it - and the author would
     * never know. Failing the load is the only acceptable behaviour.
     */
    test("rejects an over-long message instead of truncating it", () => {
        assert.throws(
            () => parseSeedFile("x".repeat(501)),
            /too long/,
        );
    });

    test("names every offending line, not just the first", () => {
        const contents = ["ok", "y".repeat(501), "ok too", "z".repeat(600)].join("\n");
        assert.throws(
            () => parseSeedFile(contents),
            (err: unknown) => {
                const msg = err instanceof Error ? err.message : "";
                // Line numbers are 1-based and must survive comment skipping,
                // or the report sends you to the wrong line of your own file.
                return msg.includes("line 2") && msg.includes("line 4");
            },
        );
    });

    test("line numbers account for skipped comments and blanks", () => {
        const contents = ["# heading", "", "fine", "w".repeat(501)].join("\n");
        assert.throws(() => parseSeedFile(contents), /line 4/);
    });
});
