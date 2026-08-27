interface Props {
    id: string;
    slot: number;
    total: number;
    onOpen: () => void;
    nudge: boolean;
}

/**
 * Scatter bottles deterministically from their id.
 *
 * Deterministic rather than random so a bottle does not jump between renders,
 * which would break the illusion that it is lying in one place. The API only
 * sends a slot; where it sits on screen is the client's business.
 */
function scatter(id: string, slot: number, total: number) {
    let hash = 0;
    for (let i = 0; i < id.length; i++) {
        hash = (hash * 31 + id.charCodeAt(i)) | 0;
    }
    const jitter = (n: number, spread: number) => ((Math.abs(hash >> n) % 1000) / 1000 - 0.5) * spread;

    // Spread across the sand, biased away from the very edges so nothing is
    // clipped on narrow screens.
    const lane = total === 1 ? 0.5 : 0.14 + (slot / Math.max(1, total - 1)) * 0.72;

    return {
        left: `${(lane + jitter(3, 0.06)) * 100}%`,
        // Further down the sand reads as nearer the viewer.
        top: `${70 + jitter(7, 16)}%`,
        tilt: `${jitter(11, 26)}deg`,
        delay: `${(Math.abs(hash >> 5) % 4000) / 1000}s`,
        scale: 0.86 + (Math.abs(hash >> 13) % 300) / 1000,
    };
}

export function Bottle({ id, slot, total, onOpen, nudge }: Props) {
    const pos = scatter(id, slot, total);

    return (
        <>
            <button
                className="bottle"
                onClick={onOpen}
                aria-label="A bottle in the sand. Open it."
                style={{
                    left: pos.left,
                    top: pos.top,
                    animationDelay: pos.delay,
                    transform: `scale(${pos.scale})`,
                    ["--tilt" as string]: pos.tilt,
                }}
            >
                <svg viewBox="0 0 40 64" width="100%" height="100%" aria-hidden="true">
                    {/* cork */}
                    <rect x="16" y="2" width="8" height="9" rx="2" fill="var(--cork)" />
                    {/* neck and body */}
                    <path
                        d="M17 11h6v7c0 2 6 6 6 12v27a5 5 0 0 1-5 5H16a5 5 0 0 1-5-5V30c0-6 6-10 6-12z"
                        fill="var(--glass)"
                        fillOpacity="0.82"
                        stroke="rgba(59,58,54,0.32)"
                        strokeWidth="1"
                    />
                    {/* the letter inside, just visible */}
                    <rect x="15" y="34" width="10" height="19" rx="2" fill="var(--paper)" fillOpacity="0.94" />
                    {/* highlight */}
                    <path d="M14 30v22" stroke="rgba(255,255,255,0.6)" strokeWidth="2" strokeLinecap="round" />
                </svg>
            </button>

            {nudge && (
                <svg
                    className="nudge"
                    viewBox="0 0 24 24"
                    aria-hidden="true"
                    style={{
                        left: `calc(${pos.left} + 14px)`,
                        top: `calc(${pos.top} - 42px)`,
                    }}
                >
                    <path
                        d="M12 3v16m0 0l-6-6m6 6l6-6"
                        fill="none"
                        stroke="currentColor"
                        strokeWidth="2"
                        strokeLinecap="round"
                        strokeLinejoin="round"
                    />
                </svg>
            )}
        </>
    );
}
