import { useCallback, useEffect, useState } from "react";
import { api, type Bottle as BottleData, type OpenedLetter } from "../api.ts";
import { Bottle } from "./Bottle.tsx";
import { Letter } from "./Letter.tsx";

const OPENED_BEFORE = "bottle.openedBefore";

export function Beach() {
    const [bottles, setBottles] = useState<BottleData[]>([]);
    const [letter, setLetter] = useState<OpenedLetter | null>(null);
    const [loading, setLoading] = useState(true);
    const [firstVisit, setFirstVisit] = useState(
        () => localStorage.getItem(OPENED_BEFORE) === null,
    );

    const load = useCallback(async () => {
        setLoading(true);
        try {
            const res = await api.beach();
            setBottles(res.bottles);
        } finally {
            setLoading(false);
        }
    }, []);

    useEffect(() => {
        void load();
    }, [load]);

    async function open(id: string) {
        try {
            const opened = await api.open(id);
            setLetter(opened);
            if (firstVisit) {
                localStorage.setItem(OPENED_BEFORE, "1");
                setFirstVisit(false);
            }
        } catch {
            // Moderation may have pulled it between render and click. Quietly
            // refresh rather than explaining a race to someone on a beach.
            void load();
        }
    }

    function closeLetter() {
        setLetter(null);
        // A bottle that has been opened will not come back, so re-sampling
        // gives the sense of the tide having turned while you were reading.
        void load();
    }

    return (
        <>
            {!loading && bottles.length === 0 && (
                <div className="notice-layer">
                    <div className="panel" style={{ maxWidth: 420, textAlign: "center" }}>
                        <h2>The tide is out</h2>
                        <p className="sub" style={{ marginBottom: 0 }}>
                            No bottles right now. Come back later, or set one adrift yourself -
                            someone else's beach is empty too.
                        </p>
                    </div>
                </div>
            )}

            {bottles.map((b, i) => (
                <Bottle
                    key={b.id}
                    id={b.id}
                    slot={b.slot}
                    total={bottles.length}
                    nudge={firstVisit && i === 0}
                    onOpen={() => void open(b.id)}
                />
            ))}

            {letter && <Letter letter={letter} onClose={closeLetter} />}
        </>
    );
}
