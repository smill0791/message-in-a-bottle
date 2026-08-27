import { useEffect, useState } from "react";
import { api, type User } from "./api.ts";
import { Beach } from "./components/Beach.tsx";
import { Chest } from "./components/Chest.tsx";
import { Gate } from "./components/Gate.tsx";
import { Write } from "./components/Write.tsx";

type Overlay = "none" | "chest" | "write";

export function App() {
    const [user, setUser] = useState<User | null>(null);
    const [checking, setChecking] = useState(true);
    const [overlay, setOverlay] = useState<Overlay>("none");

    // Resolve the existing session cookie on load, so returning visitors land
    // straight on the beach.
    useEffect(() => {
        api.me()
            .then(setUser)
            .catch(() => setUser(null))
            .finally(() => setChecking(false));
    }, []);

    async function signOut() {
        await api.logout();
        setUser(null);
        setOverlay("none");
    }

    return (
        <div className="scene">
            <div className="sun" />
            <div className="sea">
                <div className="wave wave-1" />
                <div className="wave wave-2" />
                <div className="wave wave-3" />
            </div>
            <div className="shore" />
            <div className="sand" />

            {user && (
                <header className="bar">
                    <h1 className="title">Message in a Bottle</h1>
                    <span className="spacer" />
                    <button className="link" onClick={() => setOverlay("write")}>
                        Write one
                    </button>
                    <button className="link" onClick={() => setOverlay("chest")}>
                        Your chest
                    </button>
                    <button className="link plain" onClick={() => void signOut()}>
                        Leave
                    </button>
                </header>
            )}

            {/* The beach stays mounted behind overlays so closing one does not
                flash an empty scene. */}
            {user && <Beach />}

            {!checking && !user && <Gate onIn={setUser} />}
            {user && overlay === "chest" && <Chest onClose={() => setOverlay("none")} />}
            {user && overlay === "write" && <Write onClose={() => setOverlay("none")} />}
        </div>
    );
}
