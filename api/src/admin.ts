/**
 * Administrative operations against the database.
 *
 * ---------------------------------------------------------------------------
 * Why this exists
 *
 * Two operations - seeding the bottle pool and promoting a moderator - were
 * only ever possible against a local Docker container. On AWS the database
 * sits in a subnet with no internet route and no public endpoint, which is
 * correct and worth keeping, but it meant both tasks required hand-writing an
 * `aws ssm send-command` with a Node one-liner inlined into it. That is
 * error-prone, unreviewable, and got the SQL wrong twice.
 *
 * The same gap appearing twice is the justification for a tool rather than a
 * third one-off. This runs identically in both places:
 *
 *   local   npm run admin -- seed
 *   on AWS  ./scripts/remote-admin.sh seed
 *
 * The AWS path is the same compiled file, executed on an instance over Session
 * Manager, because the instance is already inside the VPC and already holds
 * the credentials. Nothing new is exposed to reach it.
 * ---------------------------------------------------------------------------
 */

import { readFile } from "node:fs/promises";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { pool, transaction } from "./db.js";

/**
 * A fixed id for the account that owns seeded messages.
 *
 * Constant rather than generated so that re-seeding replaces the previous
 * seed set instead of layering a second copy on top of it, and so seeded
 * bottles are always distinguishable from user-written ones.
 */
const SEED_AUTHOR = "99999999-9999-9999-9999-999999999999";
const SEED_HANDLE = "tide";

const HERE = dirname(fileURLToPath(import.meta.url));

/**
 * Where the seed file lives, in both layouts.
 *
 * In the repo this file is api/src/admin.ts and the seeds are db/seeds/.
 * In the deployment artifact it is api/dist/admin.js with db/seeds/ alongside,
 * because package.sh ships the seed set the same way it ships migrations - so
 * the data that defines the tone of the app travels with the code that serves
 * it and the two cannot drift apart.
 */
const DEFAULT_SEED_FILE = resolve(HERE, "../../db/seeds/messages.txt");

const MAX_BODY = 500;

/**
 * Parse the seed file.
 *
 * One message per line. Blank lines and `#` comments are ignored so the file
 * can be organised and annotated by whoever is writing it - these messages set
 * the tone for every new arrival, so the file is meant to be edited by hand and
 * read like prose, not like a data format.
 */
export function parseSeedFile(contents: string): string[] {
    const messages: string[] = [];
    const problems: string[] = [];

    contents.split("\n").forEach((raw, i) => {
        const line = raw.trim();
        if (line === "" || line.startsWith("#")) return;

        if (line.length > MAX_BODY) {
            // Reported rather than truncated. A message silently cut at 500
            // characters would lose its ending, which for this app is usually
            // the entire point of it.
            problems.push(`line ${i + 1}: ${line.length} chars, limit is ${MAX_BODY}`);
            return;
        }
        messages.push(line);
    });

    if (problems.length > 0) {
        throw new Error(`seed file has messages that are too long:\n  ${problems.join("\n  ")}`);
    }
    return messages;
}

async function seed(file: string): Promise<void> {
    let contents: string;
    try {
        contents = await readFile(file, "utf8");
    } catch {
        throw new Error(`cannot read seed file: ${file}`);
    }

    const messages = parseSeedFile(contents);
    if (messages.length === 0) {
        throw new Error(`no messages found in ${file}`);
    }

    console.log(`seeding ${messages.length} message(s) from ${file}`);

    await transaction(async (tx) => {
        // The seed author is a real row because messages.author_id is a
        // foreign key. It has an unusable password hash: this account exists to
        // own rows, and must never be signed into.
        await tx.query(
            `insert into users (id, handle, password_hash)
             values ($1, $2, 'scrypt$00$00')
             on conflict (id) do nothing`,
            [SEED_AUTHOR, SEED_HANDLE],
        );

        // Replace rather than append, so running this twice does not double the
        // pool. Cascades to message_stats.
        const { rowCount: removed } = await tx.query(
            `delete from messages where author_id = $1`,
            [SEED_AUTHOR],
        );
        if (removed) console.log(`  removed ${removed} previous seed message(s)`);

        // Approved directly. These are hand-written and already reviewed by
        // the person who wrote them; sending them through the moderation queue
        // would mean a new deployment has an empty beach until someone clicks
        // thirty times.
        const { rows } = await tx.query<{ id: string }>(
            `insert into messages (author_id, body, status)
             select $1, unnest($2::text[]), 'approved'
             returning id`,
            [SEED_AUTHOR, messages],
        );

        // Every message needs a stats row or the discovery query cannot weight
        // it, and it will never surface.
        await tx.query(
            `insert into message_stats (message_id)
             select unnest($1::uuid[])
             on conflict (message_id) do nothing`,
            [rows.map((r) => r.id)],
        );

        console.log(`  inserted ${rows.length} approved message(s)`);
    });
}

async function makeModerator(handle: string): Promise<void> {
    const { rows } = await pool.query<{ handle: string }>(
        `update users set is_moderator = true
         where handle = $1
         returning handle`,
        [handle],
    );

    if (rows.length === 0) {
        throw new Error(`no account with handle '${handle}'`);
    }
    console.log(`${rows[0]!.handle} is now a moderator`);
}

/** A quick read of what is actually in the database. */
async function status(): Promise<void> {
    const { rows } = await pool.query<Record<string, string>>(
        `select
           (select count(*) from users)                              as users,
           (select count(*) from users where is_moderator)           as moderators,
           (select count(*) from messages)                           as messages,
           (select count(*) from messages where status = 'approved') as approved,
           (select count(*) from messages where status = 'pending')  as pending,
           (select count(*) from messages where status = 'rejected') as rejected,
           (select count(*) from reports where not resolved)         as open_reports`,
    );

    for (const [k, v] of Object.entries(rows[0] ?? {})) {
        console.log(`  ${k.padEnd(12)} ${v}`);
    }
}

function usage(): void {
    console.log(`
Administrative operations against the bottle database.

  admin seed [file]          load approved messages (default: db/seeds/messages.txt)
  admin moderator <handle>   grant moderator rights to an existing account
  admin status               counts of users, messages and open reports

Locally:  npm run admin -- <command>
On AWS:   ./scripts/remote-admin.sh <command>
`);
}

async function main(): Promise<void> {
    const [command, arg] = process.argv.slice(2);

    switch (command) {
        case "seed":
            await seed(arg ?? DEFAULT_SEED_FILE);
            break;

        case "moderator":
            if (!arg) throw new Error("usage: admin moderator <handle>");
            await makeModerator(arg);
            break;

        case "status":
            await status();
            break;

        default:
            usage();
            process.exitCode = command ? 1 : 0;
            return;
    }
}

main()
    .catch((err: unknown) => {
        console.error(err instanceof Error ? err.message : String(err));
        process.exitCode = 1;
    })
    // Without this the pool keeps the event loop alive and the process hangs
    // instead of exiting - which over SSM looks like a command that never
    // finishes rather than one that succeeded.
    .finally(() => pool.end());
