import { z } from "zod";

/**
 * Configuration comes from the environment, never from a file on disk.
 *
 * This matters more than it looks. In Phase 1 the database credentials come
 * from Secrets Manager and are injected as environment variables at boot, so
 * an instance carries no secret material on its filesystem and can be replaced
 * by the Auto Scaling group without any provisioning step.
 */
const schema = z.object({
    NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
    PORT: z.coerce.number().int().positive().default(3000),

    // Bind to all interfaces in containers and on EC2 so the ALB health check
    // can reach us. Defaults to loopback locally.
    HOST: z.string().default("127.0.0.1"),

    DATABASE_URL: z.string().url(),

    // Postgres in RDS requires TLS. Local Docker does not have a cert.
    DATABASE_SSL: z
        .enum(["true", "false"])
        .default("false")
        .transform((v) => v === "true"),

    /**
     * Path to the Amazon RDS CA bundle.
     *
     * RDS certificates are signed by Amazon's own CA, which Node does not
     * trust by default. Without this, a verified TLS connection to RDS fails
     * with "self-signed certificate in certificate chain". See ssl.ts.
     */
    DATABASE_CA_PATH: z.string().optional(),

    SESSION_TTL_HOURS: z.coerce.number().int().positive().default(24 * 30),

    // How many bottles appear on the beach at once.
    BEACH_SIZE: z.coerce.number().int().min(1).max(20).default(5),

    /**
     * Whether to mark the session cookie `Secure`.
     *
     * Deliberately its own variable rather than being derived from NODE_ENV.
     * The load balancer currently terminates HTTP, not HTTPS - there is no
     * domain name yet, so no ACM certificate - and a Secure cookie is never
     * sent over plain HTTP. Tying this to NODE_ENV=production would mean every
     * login silently failing in the deployed environment while working
     * perfectly on localhost, which is a genuinely horrible thing to debug.
     *
     * Set to true the moment there is a TLS listener.
     */
    COOKIE_SECURE: z
        .enum(["true", "false"])
        .default("false")
        .transform((v) => v === "true"),

    /**
     * Directory of built frontend assets. When set, the API serves the site as
     * well, so there is one origin, one target group and no CORS.
     */
    STATIC_DIR: z.string().optional(),
});

const parsed = schema.safeParse(process.env);

if (!parsed.success) {
    const issues = parsed.error.issues
        .map((i) => `  ${i.path.join(".")}: ${i.message}`)
        .join("\n");
    // Fail loudly at boot rather than at the first request. On EC2 this makes
    // a misconfigured instance fail its health check immediately and get
    // replaced, instead of serving errors indefinitely.
    throw new Error(`Invalid environment configuration:\n${issues}`);
}

export const config = parsed.data;
export type Config = typeof config;
