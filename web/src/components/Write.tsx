import { useState } from "react";
import { MAX_BODY, api, ApiError } from "../api.ts";

export function Write({ onClose }: { onClose: () => void }) {
    const [body, setBody] = useState("");
    const [sent, setSent] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const [busy, setBusy] = useState(false);

    const left = MAX_BODY - body.length;
    const over = left < 0;

    async function send() {
        setBusy(true);
        setError(null);
        try {
            await api.write(body.trim());
            setSent(true);
        } catch (err) {
            setError(err instanceof ApiError ? err.message : "Something went wrong.");
        } finally {
            setBusy(false);
        }
    }

    return (
        <div className="veil" onClick={onClose} role="presentation">
            <div
                className="panel"
                onClick={(e) => e.stopPropagation()}
                role="dialog"
                aria-modal="true"
                aria-label="Write a message"
            >
                {sent ? (
                    <>
                        <h2>Sealed</h2>
                        <p className="sub">
                            Your bottle goes out with the next tide, once someone has read it over.
                            You will not be told who finds it.
                        </p>
                        <button className="primary" onClick={onClose}>
                            Back to the beach
                        </button>
                    </>
                ) : (
                    <>
                        <h2>Write something</h2>
                        <p className="sub">
                            A reflection, an encouragement, something you got through. It will reach
                            someone who needs it, and you will never know who.
                        </p>

                        <label className="field">
                            <textarea
                                value={body}
                                onChange={(e) => setBody(e.target.value)}
                                placeholder="The hardest year of my life turned out to be..."
                                maxLength={MAX_BODY + 40}
                                autoFocus
                            />
                        </label>
                        <div className={over ? "count over" : "count"}>{left} characters left</div>

                        {error && <p className="note bad">{error}</p>}

                        <div className="row">
                            <button
                                className="primary"
                                onClick={() => void send()}
                                disabled={busy || over || body.trim().length === 0}
                            >
                                Cork it and set it adrift
                            </button>
                            <button className="link plain" onClick={onClose}>
                                Not now
                            </button>
                        </div>
                    </>
                )}
            </div>
        </div>
    );
}
