import { useState } from "react";
import { ApiError, api, type User } from "../api.ts";

export function Gate({ onIn }: { onIn: (user: User) => void }) {
    const [mode, setMode] = useState<"in" | "up">("up");
    const [handle, setHandle] = useState("");
    const [password, setPassword] = useState("");
    const [error, setError] = useState<string | null>(null);
    const [busy, setBusy] = useState(false);

    async function submit(e: React.FormEvent) {
        e.preventDefault();
        setBusy(true);
        setError(null);
        try {
            const user = mode === "up"
                ? await api.register(handle, password)
                : await api.login(handle, password);
            onIn(user);
        } catch (err) {
            setError(err instanceof ApiError ? err.message : "Something went wrong.");
        } finally {
            setBusy(false);
        }
    }

    return (
        <div className="veil" style={{ background: "rgba(59,58,54,0.2)" }}>
            <form className="panel" style={{ maxWidth: 420 }} onSubmit={(e) => void submit(e)}>
                <h2>Message in a Bottle</h2>
                <p className="sub">
                    Somewhere out there, someone wrote something down and let the sea take it.
                    Pick a name - it does not have to be yours.
                </p>

                <label className="field">
                    <span>Name</span>
                    <input
                        value={handle}
                        onChange={(e) => setHandle(e.target.value.toLowerCase())}
                        placeholder="driftwood"
                        autoComplete="username"
                        autoFocus
                        required
                    />
                </label>

                <label className="field">
                    <span>Password</span>
                    <input
                        type="password"
                        value={password}
                        onChange={(e) => setPassword(e.target.value)}
                        autoComplete={mode === "up" ? "new-password" : "current-password"}
                        required
                    />
                </label>

                {error && <p className="note bad">{error}</p>}

                <div className="row">
                    <button className="primary" type="submit" disabled={busy}>
                        {mode === "up" ? "Walk down to the beach" : "Come back"}
                    </button>
                    <button
                        className="link plain"
                        type="button"
                        onClick={() => {
                            setMode(mode === "up" ? "in" : "up");
                            setError(null);
                        }}
                    >
                        {mode === "up" ? "I have been here before" : "I am new here"}
                    </button>
                </div>
            </form>
        </div>
    );
}
