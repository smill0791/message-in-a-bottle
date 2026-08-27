import { useCallback, useEffect, useState } from "react";
import { api, type QueueItem } from "../api.ts";

export function Review({ onClose }: { onClose: () => void }) {
    const [queue, setQueue] = useState<QueueItem[] | null>(null);
    const [busy, setBusy] = useState<string | null>(null);

    const load = useCallback(async () => {
        const res = await api.queue();
        setQueue(res.queue);
    }, []);

    useEffect(() => {
        void load();
    }, [load]);

    async function decide(id: string, decision: "approve" | "reject") {
        setBusy(id);
        try {
            await (decision === "approve" ? api.approve(id) : api.reject(id));
            // Drop it locally rather than refetching, so the list does not
            // jump under the cursor mid-review.
            setQueue((prev) => prev?.filter((m) => m.id !== id) ?? null);
        } catch {
            // Someone else decided it first, or it moved. Resync.
            await load();
        } finally {
            setBusy(null);
        }
    }

    const reported = queue?.filter((m) => m.open_reports > 0) ?? [];
    const fresh = queue?.filter((m) => m.open_reports === 0) ?? [];

    function card(m: QueueItem) {
        return (
            <article className="kept" key={m.id}>
                {m.open_reports > 0 && (
                    <p className="flag">
                        Pulled from the beach after {m.open_reports}{" "}
                        {m.open_reports === 1 ? "report" : "reports"}
                        {m.reasons.length > 0 && `: ${m.reasons.join(", ").replace(/_/g, " ")}`}
                        {m.discovery_count > 0 && ` · seen by ${m.discovery_count}`}
                    </p>
                )}
                <p>{m.body}</p>
                <div className="row" style={{ marginTop: 8 }}>
                    <span className="when">
                        {m.author} · {new Date(m.created_at).toLocaleDateString()}
                        {m.previously_reviewed && " · previously approved"}
                    </span>
                    <span style={{ flex: 1 }} />
                    <button
                        className="link"
                        disabled={busy === m.id}
                        onClick={() => void decide(m.id, "approve")}
                    >
                        Set adrift
                    </button>
                    <button
                        className="link plain"
                        disabled={busy === m.id}
                        onClick={() => void decide(m.id, "reject")}
                    >
                        Reject
                    </button>
                </div>
            </article>
        );
    }

    return (
        <div className="veil" onClick={onClose} role="presentation">
            <div
                className="panel"
                onClick={(e) => e.stopPropagation()}
                role="dialog"
                aria-modal="true"
                aria-label="Review queue"
            >
                <h2>Review</h2>
                <p className="sub">
                    Nothing reaches the beach until it passes through here.
                </p>

                {queue === null ? (
                    <p className="empty-note">Loading...</p>
                ) : queue.length === 0 ? (
                    <p className="empty-note">Nothing waiting. The queue is clear.</p>
                ) : (
                    <>
                        {reported.length > 0 && (
                            <>
                                {/* Reported items were live and seen by real
                                    people, so they come first. */}
                                <h3 className="group">Reported ({reported.length})</h3>
                                {reported.map(card)}
                            </>
                        )}
                        {fresh.length > 0 && (
                            <>
                                <h3 className="group">Waiting ({fresh.length})</h3>
                                {fresh.map(card)}
                            </>
                        )}
                    </>
                )}

                <div className="row" style={{ marginTop: 24 }}>
                    <button className="primary" onClick={onClose}>
                        Back to the beach
                    </button>
                </div>
            </div>
        </div>
    );
}
