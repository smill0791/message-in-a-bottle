import { randomBytes, scrypt as scryptCb, timingSafeEqual } from "node:crypto";
import { promisify } from "node:util";
import type { FastifyReply, FastifyRequest } from "fastify";
import { pool } from "./db.js";
import { config } from "./config.js";

const scrypt = promisify(scryptCb) as (
    password: string,
    salt: Buffer,
    keylen: number,
) => Promise<Buffer>;

const SCRYPT_KEYLEN = 64;
export const SESSION_COOKIE = "bottle_session";

/**
 * scrypt from node:crypto rather than bcrypt or argon2.
 *
 * Both alternatives are native modules, which means a compile step in CI and a
 * build toolchain on the EC2 AMI. scrypt is memory-hard, in the standard
 * library, and entirely adequate here. One less thing to break in Phase 3.
 */
export async function hashPassword(password: string): Promise<string> {
    const salt = randomBytes(16);
    const derived = await scrypt(password, salt, SCRYPT_KEYLEN);
    return `scrypt$${salt.toString("hex")}$${derived.toString("hex")}`;
}

export async function verifyPassword(password: string, stored: string): Promise<boolean> {
    const [scheme, saltHex, hashHex] = stored.split("$");
    if (scheme !== "scrypt" || !saltHex || !hashHex) return false;

    const salt = Buffer.from(saltHex, "hex");
    const expected = Buffer.from(hashHex, "hex");
    const actual = await scrypt(password, salt, expected.length);

    // Constant-time compare. A plain === leaks how much of the hash matched
    // via response timing.
    return actual.length === expected.length && timingSafeEqual(actual, expected);
}

/**
 * Sessions live in Postgres, not in process memory.
 *
 * This is the single design decision that makes the Auto Scaling group real.
 * With in-memory sessions, scaling out logs users out at random and scaling in
 * loses them entirely, so you would need sticky sessions on the load balancer
 * and the whole exercise becomes theatre.
 */
export async function createSession(userId: string): Promise<string> {
    const token = randomBytes(32).toString("base64url");
    await pool.query(
        `insert into sessions (token, user_id, expires_at)
         values ($1, $2, now() + make_interval(hours => $3))`,
        [token, userId, config.SESSION_TTL_HOURS],
    );
    return token;
}

export async function destroySession(token: string): Promise<void> {
    await pool.query("delete from sessions where token = $1", [token]);
}

export interface AuthedUser {
    id: string;
    handle: string;
}

declare module "fastify" {
    interface FastifyRequest {
        user?: AuthedUser;
    }
}

/** Resolve the session cookie to a user, if there is a valid one. */
export async function loadUser(req: FastifyRequest): Promise<void> {
    const token = req.cookies[SESSION_COOKIE];
    if (!token) return;

    const { rows } = await pool.query<AuthedUser>(
        `select u.id, u.handle
           from sessions s
           join users u on u.id = s.user_id
          where s.token = $1
            and s.expires_at > now()`,
        [token],
    );

    if (rows[0]) req.user = rows[0];
}

/** Route guard. Use as a preHandler on anything that needs a signed-in user. */
export async function requireUser(req: FastifyRequest, reply: FastifyReply): Promise<void> {
    if (!req.user) {
        await reply.code(401).send({ error: "not signed in" });
    }
}

export function sessionCookieOptions() {
    return {
        httpOnly: true,
        sameSite: "lax" as const,
        // Behind the ALB we terminate TLS, so cookies must be secure in prod.
        secure: config.NODE_ENV === "production",
        path: "/",
        maxAge: config.SESSION_TTL_HOURS * 3600,
    };
}
