import { useEffect, useState } from "react";
import { api, type KeptMessage } from "../api.ts";

export function Chest({ onClose }: { onClose: () => void }) {
    const [messages, setMessages] = useState<KeptMessage[] | null>(null);

    useEffect(() => {
        void api.chest().then((r) => setMessages(r.messages));
    }, []);

    async function putBack(id: string) {
        await api.keep(id, false);
        setMessages((prev) => prev?.filter((m) => m.id !== id) ?? null);
    }

    async function toggleFavorite(m: KeptMessage) {
        const next = !m.favorited;
        await api.favorite(m.id, next);
        setMessages(
            (prev) => prev?.map((x) => (x.id === m.id ? { ...x, favorited: next } : x)) ?? null,
        );
    }

    return (
        <div className="veil" onClick={onClose} role="presentation">
            <div
                className="panel"
                onClick={(e) => e.stopPropagation()}
                role="dialog"
                aria-modal="true"
                aria-label="Your chest"
            >
                <h2>Your chest</h2>
                <p className="sub">The letters you decided to keep.</p>

                {messages === null ? (
                    <p className="empty-note">Opening the lid...</p>
                ) : messages.length === 0 ? (
                    <p className="empty-note">
                        Nothing kept yet.
                        <br />
                        Letters you keep from the beach will wait here for you.
                    </p>
                ) : (
                    messages.map((m) => (
                        <article className="kept" key={m.id}>
                            <p>{m.body}</p>
                            <div className="row" style={{ marginTop: 8 }}>
                                <span className="when">
                                    Found {new Date(m.discovered_at).toLocaleDateString()}
                                    {m.theme ? ` · ${m.theme}` : ""}
                                </span>
                                <span style={{ flex: 1 }} />
                                <button
                                    className="link plain"
                                    onClick={() => void toggleFavorite(m)}
                                    aria-pressed={m.favorited}
                                >
                                    {m.favorited ? "★ Favourite" : "☆ Favourite"}
                                </button>
                                <button className="link plain" onClick={() => void putBack(m.id)}>
                                    Put back in the sea
                                </button>
                            </div>
                        </article>
                    ))
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
