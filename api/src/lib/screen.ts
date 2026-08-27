/**
 * Phase 0 screening: the cheap, obvious cases only.
 *
 * This is deliberately a stub with a clear seam. In Phase 4 the same call site
 * publishes to SQS and a Lambda runs a real classifier, which can judge *tone*
 * rather than vocabulary - the thing that actually protects the feel of this
 * app. Spam, ads and hot takes are not profane, so no denylist will ever catch
 * them.
 *
 * Until then: reject the unambiguous, queue everything else for human review.
 * Nothing reaches the beach without passing through `status = 'approved'`.
 */

export type Verdict =
    | { decision: "reject"; reason: string }
    | { decision: "review" };

// Intentionally short. A long denylist creates false positives on words that
// appear in genuine writing about hardship - which is precisely the content
// this app exists to carry. Better to under-block here and let a human decide.
const SLURS_AND_ABUSE: readonly string[] = [
    // Populate from a maintained list rather than inventing one. Left minimal
    // on purpose; the classifier in Phase 4 is the real control.
];

const URL_PATTERN = /https?:\/\/|www\.|\b[a-z0-9-]+\.(com|net|org|io|co|shop|xyz)\b/i;

export function screen(body: string): Verdict {
    const normalized = body.toLowerCase();

    for (const term of SLURS_AND_ABUSE) {
        if (normalized.includes(term)) {
            return { decision: "reject", reason: "abusive language" };
        }
    }

    // Links are the clearest spam signal and have no place in a handwritten
    // note. This one rule removes most drive-by advertising.
    if (URL_PATTERN.test(body)) {
        return { decision: "reject", reason: "links are not allowed in bottles" };
    }

    // Shouting is usually not the register this app is for, but it is a tone
    // judgement rather than a safety one, so it goes to review, not reject.
    return { decision: "review" };
}
