import { readFileSync } from "node:fs";
import type { ConnectionOptions } from "node:tls";
import { config } from "./config.js";

/**
 * TLS settings for the Postgres connection.
 *
 * RDS presents a certificate signed by the Amazon RDS certificate authority,
 * which is not in Node's default trust store. With `rejectUnauthorized: true`
 * and no CA supplied, the connection fails with:
 *
 *     self-signed certificate in certificate chain
 *
 * The tempting fix is `rejectUnauthorized: false`. That silences the error by
 * turning off verification entirely, which means the client will accept any
 * certificate from anything that answers on that host and port - it encrypts
 * the connection while giving up the guarantee that it is talking to the real
 * database. The database password crosses this connection.
 *
 * The correct fix is to trust the RDS CA explicitly. The bundle is downloaded
 * onto the instance at boot and its path passed in DATABASE_CA_PATH.
 */
export function sslConfig(): ConnectionOptions | false {
    if (!config.DATABASE_SSL) return false;

    if (config.DATABASE_CA_PATH) {
        return {
            ca: readFileSync(config.DATABASE_CA_PATH, "utf8"),
            rejectUnauthorized: true,
        };
    }

    // TLS requested but no CA supplied. Verification stays on, so this will
    // fail loudly against RDS rather than silently downgrading to an
    // unauthenticated connection.
    return { rejectUnauthorized: true };
}
