import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { screen } from "./screen.js";

/**
 * screen() is the only thing standing between a submission and the human
 * review queue, and its rules are deliberately blunt. These tests pin the two
 * behaviours that matter: links never reach the beach, and ordinary writing
 * about difficult things is never auto-rejected.
 *
 * The second is the one worth guarding. This app exists to carry messages
 * about hardship; a screening rule that quietly rejects them defeats the
 * premise, and it would be invisible - the author sees "queued for review"
 * either way.
 */
describe("screen", () => {
    describe("rejects links, which are the clearest spam signal", () => {
        const links = [
            "check out https://example.com for more",
            "visit http://spam.io",
            "go to www.buy-things.net now",
            "cheap stuff at bargains.shop",
            "read more at medium.com",
            "MY SITE IS HTTPS://SHOUTY.COM",
        ];

        for (const body of links) {
            test(body.slice(0, 40), () => {
                const verdict = screen(body);
                assert.equal(verdict.decision, "reject");
                assert.match(
                    verdict.decision === "reject" ? verdict.reason : "",
                    /link/i,
                );
            });
        }
    });

    describe("sends ordinary writing to review, not to reject", () => {
        const genuine = [
            "Some days the tide goes out further than you expect. It always comes back.",
            "I was certain I had ruined everything. Two years on, I can barely remember why.",
            "You do not have to be doing well to be doing enough.",
            // Hardship, self-loathing and despair are the substance of this
            // app, not abuse. If a screening change ever starts rejecting
            // these, it has broken the product.
            "I hated myself for a long time and I am only now stopping.",
            "The worst year of my life ended and I did not notice for months.",
            "I could not get out of bed. That was not a moral failure.",
            // Punctuation that superficially resembles a domain.
            "It ended. Finally. I am okay.",
            "She said no...com si, com sa, she said, and laughed.",
        ];

        for (const body of genuine) {
            test(body.slice(0, 40), () => {
                assert.equal(screen(body).decision, "review");
            });
        }
    });

    test("nothing is ever auto-approved", () => {
        // Every path must lead to reject or review. An 'approve' verdict here
        // would put unreviewed text straight onto the beach.
        const verdicts = [
            screen("hello"),
            screen("https://example.com"),
            screen(""),
        ];
        for (const v of verdicts) {
            assert.ok(v.decision === "reject" || v.decision === "review");
        }
    });
});
