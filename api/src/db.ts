import pg from "pg";
import { config } from "./config.js";

/**
 * One pool per process. Sized deliberately small.
 *
 * db.t4g.micro allows roughly 60 connections. With an Auto Scaling group that
 * can reach 4 instances, a pool of 10 each leaves headroom for migrations and
 * a psql session. Raising max here is how you exhaust RDS connections during a
 * scale-out event, which looks exactly like a database outage.
 */
export const pool = new pg.Pool({
    connectionString: config.DATABASE_URL,
    max: 10,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000,
    ssl: config.DATABASE_SSL ? { rejectUnauthorized: true } : false,
});

pool.on("error", (err) => {
    // An idle client erroring is usually RDS failing over or dropping an idle
    // connection. Log it; the pool will make a new one.
    console.error({ err: err.message }, "idle postgres client error");
});

export type Sql = Pick<pg.Pool, "query">;

/** Run a set of statements in a transaction, rolling back on any throw. */
export async function transaction<T>(fn: (tx: pg.PoolClient) => Promise<T>): Promise<T> {
    const client = await pool.connect();
    try {
        await client.query("begin");
        const result = await fn(client);
        await client.query("commit");
        return result;
    } catch (err) {
        await client.query("rollback");
        throw err;
    } finally {
        client.release();
    }
}
