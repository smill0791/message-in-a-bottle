import { useEffect, useState } from "react";
import { THEMES, api, type OpenedLetter, type Theme } from "../api.ts";

interface Props {
    letter: OpenedLetter;
    onClose: () => void;
}

const REPORT_REASONS = [
    ["hateful", "Hateful"],
    ["harassment", "Harassment"],
    ["spam", "Spam"],
    ["off_vibe", "Not in the spirit of this place"],
] as const;

export function Letter({ letter, onClose }: Props) {
    const [theme, setTheme] = useState<Theme | null>(null);
    const [kept, setKept] = useState(false);
    const [reporting, setReporting] = useState(false);
    const [reported, setReported] = useState(false);
    const [busy, setBusy] = useState(false);

    // Escape closes. A modal you cannot dismiss with the keyboard is a trap.
    useEffect(() => {
        const onKey = (e: KeyboardEvent) => {
            if (e.key === "Escape") onClose();
        };
        window.addEventListener("keydown", onKey);
        return () => window.removeEventListener("keydown", onKey);
    }, [onClose]);

    async function chooseTheme(next: Theme) {
        setTheme(next);
        setBusy(true);
        try {
            // Choosing a theme is also the resonance signal. Asking twice
            // ("how did it feel?" then "did you like it?") would be one
            // question too many for the mood of this app.
            await api.rate(letter.id, next, true);
        } catch {
            setTheme(null);
        } finally {
            setBusy(false);
        }
    }

    async function keep() {
        setBusy(true);
        try {
            await api.keep(letter.id, true);
            setKept(true);
        } finally {
            setBusy(false);
        }
    }

    async function report(reason: string) {
        setBusy(true);
        try {
            await api.report(letter.id, reason);
            setReported(true);
            setReporting(false);
        } finally {
            setBusy(false);
        }
    }

    const written = new Date(letter.writtenAt).toLocaleDateString(undefined, {
        year: "numeric",
        month: "long",
        day: "numeric",
    });

    return (
        <div className="veil" onClick={onClose} role="presentation">
            <div
                className="letter"
                onClick={(e) => e.stopPropagation()}
                role="dialog"
                aria-modal="true"
                aria-label="A letter from a bottle"
            >
                {/* The cork flies off before the paper unrolls. Purely
                    decorative, so it is hidden from assistive tech. */}
                <svg
                    className="cork"
                    viewBox="0 0 24 24"
                    width="26"
                    height="26"
                    aria-hidden="true"
                    style={{ position: "absolute", top: -14, left: "calc(50% - 13px)" }}
                >
                    <rect x="7" y="4" width="10" height="14" rx="3" fill="var(--cork)" />
                </svg>

                <p className="letter-body">{letter.body}</p>
                <p className="letter-meta">Written {written}. Set adrift by someone you will never meet.</p>

                <div className="letter-actions">
                    {reported ? (
                        <p className="note">Thank you. Someone will take a look at this.</p>
                    ) : reporting ? (
                        <>
                            <p className="prompt">What is wrong with it?</p>
                            <div className="themes">
                                {REPORT_REASONS.map(([value, label]) => (
                                    <button
                                        key={value}
                                        className="chip"
                                        disabled={busy}
                                        onClick={() => void report(value)}
                                    >
                                        {label}
                                    </button>
                                ))}
                            </div>
                            <div className="row">
                                <button className="link plain" onClick={() => setReporting(false)}>
                                    Never mind
                                </button>
                            </div>
                        </>
                    ) : (
                        <>
                            <p className="prompt">How did this one land?</p>
                            <div className="themes">
                                {THEMES.map((t) => (
                                    <button
                                        key={t}
                                        className="chip"
                                        aria-pressed={theme === t}
                                        disabled={busy}
                                        onClick={() => void chooseTheme(t)}
                                    >
                                        {t}
                                    </button>
                                ))}
                            </div>

                            <div className="row">
                                <button className="primary" onClick={() => void keep()} disabled={busy || kept}>
                                    {kept ? "In your chest" : "Keep it"}
                                </button>
                                <button className="link" onClick={onClose}>
                                    {kept ? "Back to the beach" : "Put it back"}
                                </button>
                                <span className="spacer" style={{ flex: 1 }} />
                                <button className="link plain" onClick={() => setReporting(true)}>
                                    Report
                                </button>
                            </div>
                        </>
                    )}
                </div>
            </div>
        </div>
    );
}
