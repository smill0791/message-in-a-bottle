import { useState } from "react";
import { ApiError, api, type User } from "../api.ts";

// Mirrors the server rules so the form can explain itself before a round trip.
// The server stays authoritative; this exists to avoid making someone guess.
const HANDLE_PATTERN = /^[a-z0-9_-]{3,24}$/;
const PASSWORD_MIN = 10;

const HANDLE_HINT = "3-24 characters: lowercase letters, numbers, dashes or underscores";
const PASSWORD_HINT = `at least ${PASSWORD_MIN} characters`;

export function Gate({ onIn }: { onIn: (user: User) => void }) {
    const [mode, setMode] = useState<"in" | "up">("up");
    const [handle, setHandle] = useState("");
    const [password, setPassword] = useState("");
    const [fields, setFields] = useState<Record<string, string>>({});
    const [error, setError] = useState<string | null>(null);
    const [busy, setBusy] = useState(false);
    const [touched, setTouched] = useState(false);

    const signingUp = mode === "up";

    // Only validate locally when signing up. On sign-in these rules are
    // irrelevant - an existing account may predate them, and telling someone
    // their password is "too short" while they are trying to log in is both
    // wrong and a disclosure.
    const handleProblem =
        signingUp && touched && handle.length > 0 && !HANDLE_PATTERN.test(handle)
            ? `Name must be ${HANDLE_HINT}.`
            : (fields["handle"] ?? null);

    const passwordProblem =
        signingUp && touched && password.length > 0 && password.length < PASSWORD_MIN
            ? `Password must be ${PASSWORD_HINT}.`
            : (fields["password"] ?? null);

    const canSubmit =
        handle.length > 0 &&
        password.length > 0 &&
        (!signingUp || (HANDLE_PATTERN.test(handle) && password.length >= PASSWORD_MIN));

    async function submit(e: React.FormEvent) {
        e.preventDefault();
        setTouched(true);
        setBusy(true);
        setError(null);
        setFields({});
        try {
            const user = signingUp
                ? await api.register(handle, password)
                : await api.login(handle, password);
            onIn(user);
        } catch (err) {
            if (err instanceof ApiError) {
                // Prefer per-field messages; fall back to the summary for
                // things like "that handle is taken".
                if (err.fields && Object.keys(err.fields).length > 0) {
                    setFields(err.fields);
                } else {
                    setError(err.message);
                }
            } else {
                setError("Something went wrong.");
            }
        } finally {
            setBusy(false);
        }
    }

    return (
        <div className="veil" style={{ background: "rgba(59,58,54,0.2)" }}>
            <form className="panel" style={{ maxWidth: 420 }} onSubmit={(e) => void submit(e)} noValidate>
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
                        onBlur={() => setTouched(true)}
                        placeholder="driftwood"
                        autoComplete="username"
                        aria-describedby="handle-hint"
                        aria-invalid={handleProblem ? true : undefined}
                        autoFocus
                    />
                    {/* Requirements are shown up front, not revealed by failing. */}
                    <small id="handle-hint" className={handleProblem ? "hint bad" : "hint"}>
                        {handleProblem ?? (signingUp ? HANDLE_HINT : " ")}
                    </small>
                </label>

                <label className="field">
                    <span>Password</span>
                    <input
                        type="password"
                        value={password}
                        onChange={(e) => setPassword(e.target.value)}
                        onBlur={() => setTouched(true)}
                        autoComplete={signingUp ? "new-password" : "current-password"}
                        aria-describedby="password-hint"
                        aria-invalid={passwordProblem ? true : undefined}
                    />
                    <small id="password-hint" className={passwordProblem ? "hint bad" : "hint"}>
                        {passwordProblem ?? (signingUp ? PASSWORD_HINT : " ")}
                    </small>
                </label>

                {error && <p className="note bad">{error}</p>}

                <div className="row">
                    <button className="primary" type="submit" disabled={busy || !canSubmit}>
                        {signingUp ? "Walk down to the beach" : "Come back"}
                    </button>
                    <button
                        className="link plain"
                        type="button"
                        onClick={() => {
                            setMode(signingUp ? "in" : "up");
                            setError(null);
                            setFields({});
                            setTouched(false);
                        }}
                    >
                        {signingUp ? "I have been here before" : "I am new here"}
                    </button>
                </div>
            </form>
        </div>
    );
}
