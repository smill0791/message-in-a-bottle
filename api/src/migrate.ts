import { readdir, readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { config } from "./config.js";

/**
 * Migration runner.
 *
 * Runs on every instance at boot, before the service starts. That means
 * several instances may run it simultaneously during a scale-out or an
 * instance refresh, so it must be safe to execute concurrently.
 *
 * A Postgres advisory lock provides that. The first instance takes the lock
 * and applies whatever is pending; the others block, then wake up and find
 * nothing to do. Without it, two instances can both see a migration as
 * unapplied and run it twice.
 */

// Arbitrary but fixed. Any process using this number is coordinating on the
// same thing.
const LOCK_ID = 8_147_320_051;

const here = dirname(fileURLToPath(import.meta.url));

// api/dist/migrate.js -> ../../db/migrations
const MIGRATIONS_DIR = process.env["MIGRATIONS_DIR"]
    ? resolve(process.env["MIGRATIONS_DIR"])
    : resolve(here, "..", "..", "db", "migrations");

async function run(): Promise<void> {
    const client = new pg.Client({
        connectionString: config.DATABASE_URL,
        ssl: config.DATABASE_SSL ? { rejectUnauthorized: true } : false,
    });

    await client.connect();

    try {
        console.log(`migrations directory: ${MIGRATIONS_DIR}`);

        const files = (await readdir(MIGRATIONS_DIR))
            .filter((f) => f.endsWith(".sql"))
            // Filenames are zero-padded and ordered (001_, 002_, ...), so a
            // lexicographic sort is the intended order.
            .sort();

        if (files.length === 0) {
            console.log("no migrations found");
            return;
        }

        // Taken outside any transaction so it is held across the whole run and
        // released only when the connection closes.
        console.log("waiting for migration lock...");
        await client.query("select pg_advisory_lock($1)", [LOCK_ID]);
        console.log("lock acquired");

        await client.query(`
            create table if not exists schema_migrations (
                filename   text primary key,
                applied_at timestamptz not null default now()
            )
        `);

        const { rows } = await client.query<{ filename: string }>(
            "select filename from schema_migrations",
        );
        const applied = new Set(rows.map((r) => r.filename));

        let count = 0;
        for (const file of files) {
            if (applied.has(file)) {
                console.log(`  skip    ${file}`);
                continue;
            }

            const sql = await readFile(join(MIGRATIONS_DIR, file), "utf8");

            // Each migration is one transaction: it applies completely, or not
            // at all, and the bookkeeping row commits with it. A migration that
            // half-applies leaves a schema nobody can reason about.
            try {
                await client.query("begin");
                await client.query(sql);
                await client.query("insert into schema_migrations (filename) values ($1)", [file]);
                await client.query("commit");
                console.log(`  applied ${file}`);
                count++;
            } catch (err) {
                await client.query("rollback");
                throw new Error(`migration ${file} failed: ${(err as Error).message}`);
            }
        }

        console.log(count === 0 ? "already up to date" : `applied ${count} migration(s)`);
    } finally {
        // Releases the advisory lock as a side effect.
        await client.end();
    }
}

run().catch((err) => {
    console.error(err instanceof Error ? err.message : err);
    // Non-zero so the bootstrap script fails loudly and the instance never
    // starts serving against a schema it does not match.
    process.exit(1);
});
