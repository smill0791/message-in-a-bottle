import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { pool } from "../db.js";
import {
    SESSION_COOKIE,
    createSession,
    destroySession,
    hashPassword,
    sessionCookieOptions,
    verifyPassword,
} from "../auth.js";

export const HANDLE_PATTERN = /^[a-z0-9_-]{3,24}$/;
export const PASSWORD_MIN = 10;

const credentials = z.object({
    handle: z
        .string()
        .regex(
            HANDLE_PATTERN,
            "Name must be 3-24 characters: lowercase letters, numbers, dashes or underscores.",
        ),
    password: z
        .string()
        .min(PASSWORD_MIN, `Password must be at least ${PASSWORD_MIN} characters.`)
        .max(200, "Password must be under 200 characters."),
});

/**
 * Report *every* problem, keyed by field.
 *
 * Returning only `issues[0]` meant that a form with a bad name and a short
 * password showed the name error alone, so fixing it revealed a second error
 * the user had no way to anticipate. Worse, neither message named its field,
 * which on a two-field form is a guessing game.
 */
function fieldErrors(error: z.ZodError): Record<string, string> {
    const fields: Record<string, string> = {};
    for (const issue of error.issues) {
        const key = String(issue.path[0] ?? "form");
        fields[key] ??= issue.message;
    }
    return fields;
}

export async function authRoutes(app: FastifyInstance): Promise<void> {
    app.post("/auth/register", async (req, reply) => {
        const parsed = credentials.safeParse(req.body);
        if (!parsed.success) {
            const fields = fieldErrors(parsed.error);
            return reply.code(400).send({
                error: Object.values(fields).join(" "),
                fields,
            });
        }
        const { handle, password } = parsed.data;

        const passwordHash = await hashPassword(password);

        // Let the unique constraint decide, rather than checking first. A
        // check-then-insert races with a concurrent registration of the same
        // handle, and the database already knows the answer.
        let userId: string;
        try {
            const { rows } = await pool.query<{ id: string }>(
                `insert into users (handle, password_hash)
                 values ($1, $2)
                 returning id`,
                [handle, passwordHash],
            );
            userId = rows[0]!.id;
        } catch (err) {
            if ((err as { code?: string }).code === "23505") {
                return reply.code(409).send({ error: "that handle is taken" });
            }
            throw err;
        }

        const token = await createSession(userId);
        return reply
            .setCookie(SESSION_COOKIE, token, sessionCookieOptions())
            .code(201)
            .send({ id: userId, handle });
    });

    app.post("/auth/login", async (req, reply) => {
        const parsed = credentials.safeParse(req.body);
        if (!parsed.success) {
            return reply.code(401).send({ error: "wrong handle or password" });
        }
        const { handle, password } = parsed.data;

        const { rows } = await pool.query<{ id: string; password_hash: string }>(
            "select id, password_hash from users where handle = $1",
            [handle],
        );
        const user = rows[0];

        // Verify against a dummy hash when the user does not exist, so the
        // response time does not reveal whether a handle is registered.
        const stored = user?.password_hash ?? "scrypt$00$00";
        const ok = await verifyPassword(password, stored);

        if (!user || !ok) {
            return reply.code(401).send({ error: "wrong handle or password" });
        }

        const token = await createSession(user.id);
        return reply
            .setCookie(SESSION_COOKIE, token, sessionCookieOptions())
            .send({ id: user.id, handle });
    });

    app.post("/auth/logout", async (req, reply) => {
        const token = req.cookies[SESSION_COOKIE];
        if (token) await destroySession(token);
        return reply.clearCookie(SESSION_COOKIE, { path: "/" }).send({ ok: true });
    });

    app.get("/auth/me", async (req, reply) => {
        if (!req.user) return reply.code(401).send({ error: "not signed in" });
        return req.user;
    });
}
