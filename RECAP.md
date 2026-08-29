# Terraform Phase - Recap and Gotchas

Written 2026-08-29, after the first full apply/verify/destroy cycle.

Self-contained handoff: what exists, how to run it, and every trap we hit. If
you are picking this up cold, read "Before you touch anything" first - the
first item cost the better part of a session.

---

## Before you touch anything

### 1. Terraform must be the arm64 build (the expensive one)

**This machine is an Apple M1 Pro. Homebrew at `/usr/local` is the Intel
build.** `brew install terraform` from there installs an x86_64 Terraform,
which downloads the **x86_64 AWS provider** - an 874 MB Go binary - and runs
the whole thing under Rosetta.

Symptoms, in the order they appeared:

- `Error: Failed to load plugin schemas ... timeout while waiting for plugin
  to start` on roughly half of all commands
- `terraform plan` producing a **partial, misleading result**: it printed
  "You can apply this plan ... without changing any real infrastructure" while
  ~45 resources were actually pending
- `terraform apply` spinning at **100% CPU for 21 minutes** and creating
  nothing at all

The false diagnosis was memory pressure (swap was genuinely near-full, which
made it plausible). The real cause was the architecture mismatch.

**Fix, already applied:**

```bash
/usr/local/bin/brew uninstall hashicorp/tap/terraform   # remove the x86 one
/opt/homebrew/bin/brew install hashicorp/tap/terraform  # native arm64
```

After the switch, the same plan completed in **11.8 seconds**.

**Still outstanding for you:** `/opt/homebrew/bin` is **not on your PATH**.
Every command in this document assumes:

```bash
export PATH="/opt/homebrew/bin:$PATH"
```

Put that in `~/.zshrc` **before** anything that adds `/usr/local/bin`. On
Apple Silicon, `/opt/homebrew` should always win. Worth auditing whatever else
the Intel brew installed - it is all running translated.

Verify at any time:

```bash
file $(which terraform)   # must say arm64, not x86_64
```

### 2. Use the `aws-dev-project` profile exclusively

`[default]` and `[profile aws-dev-project]` in `~/.aws/config` reference the
**same `login_session`**, and every CLI invocation rotates the underlying
refresh token. Using one profile invalidates the other's cached grant, so
alternating between them produces a stream of:

```
ValidationException ... The provided authorization grant is invalid, expired,
revoked, or malformed
```

The session is fine; the grant was rotated out from under it. Always:

```bash
export AWS_PROFILE=aws-dev-project
```

`[default]` also points at **us-east-1**, while the project region is
**us-east-2** and is enforced by the account. Treat `[default]` as off-limits.

**This matters in Phase 3.** Parallel CI jobs sharing one credential cache
would hit this permanently, not intermittently. Each job needs its own OIDC
role assumption, not a shared cached session.

### 3. Sessions expire often

`aws login --profile aws-dev-project` is an interactive browser flow. It
expired 4+ times across this work, sometimes mid-command. If a command fails
with "Your session has expired", that is all it is.

---

## Account facts

| Fact | Value |
|---|---|
| Account | 116307287000 |
| Plan | New AWS experience, **Free Plan** (not the classic 12-month free tier) |
| Credits | $120, expiring **2027-02-25** |
| Region (enforced) | **us-east-2** |
| Profile | `aws-dev-project` |
| Budget | `bottle-monthly-10-usd` - alerts at 50/80/100% actual + 100% forecasted |

There are **no free EC2/RDS/ALB hours**. Everything bills against the $120.
The budget uses `IncludeCredit: false` so it tracks *gross usage* - with
`true` it would read $0 until the credits vanished and never warn you.

The **forecasted** alert is the one that matters. A forgotten NAT Gateway is
~$33/month, which would blow a $10 budget in nine days, but the forecast
catches it within hours of the spend rate appearing.

---

## What exists

```
message-in-a-bottle/
├── api/               Fastify + TypeScript. All routes under /api.
│   └── src/
│       ├── migrate.ts     advisory-lock migration runner
│       └── ssl.ts         RDS CA trust (see gotcha #4)
├── web/               React + Vite. Beach UI.
├── db/migrations/     001_init, 002_handle_allows_dashes, 003_moderation
├── infra/             Terraform: network, security, data, compute
└── scripts/
    ├── bootstrap-state.sh   creates the S3 state bucket (run once)
    ├── package.sh           build + upload the artifact
    ├── e2e.sh               60 end-to-end checks
    ├── seed.sh              placeholder bottles
    └── make-moderator.sh    grant moderator rights (local only)
```

### Architecture

Three subnet tiers across two AZs:

- **public** - ALB and NAT gateway
- **app** - EC2 instances, outbound only
- **data** - RDS, route table with **no internet route at all**

Security groups chain by **reference, not CIDR**: `internet → alb → app → db`.
The database has no egress rule whatsoever.

### Deliberate cost trades

Both are one-line changes if you want to demo production posture briefly:

| Choice | Production would | Why not here |
|---|---|---|
| One NAT gateway | One per AZ | ~$33/mo each against $120 of credits |
| Single-AZ RDS | Multi-AZ | Doubles instance cost for a standby |
| `backup_retention_days = 0` | 7-30 days | See gotcha #10 |

### Running cost

**~$0.10/hour** with the stack up. A three-hour session is about 30 cents.
Running it 24/7 would exhaust $120 in roughly six weeks - which is the entire
reason the workflow is "apply, verify, destroy" rather than leaving it up.

---

## How to run it

```bash
export AWS_PROFILE=aws-dev-project
export PATH="/opt/homebrew/bin:$PATH"
cd message-in-a-bottle

# 1. Bring the stack up (~15 min; RDS alone takes 7-10)
cd infra && terraform init && terraform apply

# 2. Upload the application artifact
cd .. && ARTIFACT_BUCKET=bottle-artifacts-116307287000 ./scripts/package.sh

# 3. Get the URL
terraform -chdir=infra output -raw url

# 4. Tear it down when finished - this is the cost control
terraform -chdir=infra destroy
```

**Ordering note:** on a completely fresh account the artifact bucket must
exist before the ASG boots instances, since they download the artifact at
startup. The first apply handles this via `depends_on`, but if you ever
rebuild from nothing, a targeted apply of the bucket → upload → full apply is
the safe sequence.

Local development:

```bash
npm run db:reset     # fresh Postgres + migrations
npm run dev          # API on :3000
npm run dev --workspace web   # Vite on :5173, proxies /api
./scripts/e2e.sh     # 60 checks (NOTE: truncates the database)
```

---

## Gotchas

Ordered by how much time each one cost.

### 1. Rosetta / architecture mismatch

Covered above. The single most expensive problem in this phase.

### 2. RDS TLS - "self-signed certificate in certificate chain"

Instances booted, installed dependencies, read the secret, then **died
applying migrations**. RDS presents a certificate signed by the **Amazon RDS
CA**, which is not in Node's default trust store, so `rejectUnauthorized:
true` correctly refused it.

The tempting fix is `rejectUnauthorized: false`. **Do not.** That silences the
error by accepting *any* certificate from anything answering on that host and
port - it encrypts the connection while discarding the guarantee that you are
talking to the real database. The database password crosses that connection.

The correct fix, in `api/src/ssl.ts`: fetch the regional CA bundle at boot and
trust it explicitly.

```
https://truststore.pki.rds.amazonaws.com/us-east-2/us-east-2-bundle.pem
```

### 3. ASG `name` vs `name_prefix` with `create_before_destroy`

The Auto Scaling group used a static `name` alongside
`create_before_destroy`. Any change forcing replacement makes Terraform build
the new group *before* destroying the old one - which with a fixed name is
impossible:

```
AlreadyExists: AutoScalingGroup by this name already exists
```

The stack wedges and needs a manual untaint or console deletion. Now
`name_prefix`, which is the entire point of that lifecycle rule.

**General lesson:** any resource with `create_before_destroy` and a
user-supplied unique name needs `name_prefix`.

### 4. Auto Scaling service-linked role - eventual consistency

First apply failed with:

```
Access denied when attempting to assume role
arn:aws:iam::...:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling
```

The role did not exist (AWS normally creates it on first console use). It was
auto-created *during* the failed attempt, but IAM had not propagated before
the ASG validated the load balancer config. **Retrying was the fix** - no code
change needed. Fresh accounts driven purely by API hit this once.

### 5. `COOKIE_SECURE` must not derive from `NODE_ENV`

Originally `secure: config.NODE_ENV === "production"`. The ALB terminates
**HTTP** (no domain, so no ACM certificate), and browsers never send a
`Secure` cookie over plain HTTP.

That would have meant **every login silently failing in the deployed
environment while working perfectly on localhost** - a genuinely horrible bug
to chase. It is now its own `COOKIE_SECURE` variable.

**Flip it to `true` the moment there is a TLS listener.**

### 6. The SPA fallback makes health checks lie

The not-found handler returns `index.html` with **200** for any unmatched GET.
After moving the API under `/api`, a health check still pointing at
`/healthz` would have **passed while serving HTML** - a green target group in
front of a broken app.

The Terraform path was updated to `/api/healthz` and verified. Worth
remembering whenever the routing changes.

### 7. Postgres hoists uncorrelated subqueries (InitPlan)

The first distribution test of the discovery query returned **the same bottle
100% of the time**. Not a query bug: Postgres saw an uncorrelated subquery,
lifted it to an InitPlan, and evaluated `random()` exactly **once**.

Only surfaced because the test checked the *distribution* over 4000 draws
rather than eyeballing a few rows. If you ever batch this query, correlate it
(`cross join lateral` with a reference to the outer row) or every user gets
served the identical bottle.

### 8. Test hygiene traps

Three separate ones, each of which briefly looked like a product bug:

- **`curl -f` swallows error bodies.** It exits non-zero and prints nothing,
  so a real API error looks like an empty response. `scripts/e2e.sh`
  deliberately does not use `-f`.
- **`docker exec` needs `-i`** for heredocs/stdin. Without it the SQL never
  reaches psql and every insert silently does nothing.
- **Whole-pool assertions need a clean database.** "The beach is empty before
  approval" fails on a second run if the first left approved messages behind.
  The suite now truncates first - which also means **it deletes your local
  account and moderator grant** every run.

### 9. zsh does not word-split unquoted variables

`R="--region us-east-2"; aws ec2 describe-vpcs $R` passes the whole string as
**one argument** and fails with `Unknown options`. Bash would split it; zsh
does not. Use arrays or write the flags out.

### 10. Automated RDS snapshots outlive the instance and cannot be deleted

After a clean `Destroy complete! Resources: 49 destroyed`, a **20 GB RDS
snapshot remained**. Deleting it by hand fails:

```
InvalidDBSnapshotState: automated snapshots cannot be deleted
```

It only clears when its retention period expires (~6 cents in the meantime).

`backup_retention_days` was 1, on the reasoning that point-in-time recovery
was worth a few cents. **Wrong twice:** the data does not survive `destroy`
anyway (`skip_final_snapshot = true`), so the backups protected nothing, and
they left residue that outlived the stack. **Now defaults to 0.** Raise it for
anything long-lived.

### 11. Interrupted Terraform leaves a state lock

Killing a run mid-flight leaves `terraform.tfstate.tflock` in the state
bucket, and the next command fails with `Error acquiring the state lock`.

Safe to clear **only** once you have confirmed no Terraform process is alive:

```bash
pgrep -f terraform          # must be empty
terraform force-unlock -force <LOCK_ID>
```

The lock ID is in the error message, or read the `.tflock` object from S3.

### 12. macOS `tar` embeds xattrs that spam the boot log

GNU tar on the instance warned
`Ignoring unknown extended header keyword 'LIBARCHIVE.xattr.com.apple.provenance'`
**for every single file**, burying the real error. Fixed in `package.sh` with
`COPYFILE_DISABLE=1` and `--no-xattrs`.

### 13. Provider lock file needs CI platforms

`.terraform.lock.hcl` records provider hashes **per platform**. Generated on
macOS it only had `darwin_arm64`, so a Linux CI runner would fail with "no
package available for your current platform".

Already fixed - the lock now covers `darwin_arm64`, `linux_amd64`,
`linux_arm64`. If you add a platform later:

```bash
terraform providers lock -platform=darwin_arm64 -platform=linux_amd64
```

Also: `infra/tfplan` had been committed by mistake. Saved plans are binary,
stale immediately, and can carry resource attributes you would not want in
git history. Now gitignored.

---

## Application bugs found along the way

Not Terraform, but they shaped the design.

**Auto-pull counted lifetime reports.** A moderator's decision never stuck:
approve a message that had been reported three times, and the very next report
re-pulled it instantly because the counter still said four. Self-reinforcing -
a small group could keep a message down permanently. The threshold now counts
**unresolved** reports, and approving resolves them.

**Anonymous requests to `/admin/*` returned 401, not 404.** `requireModerator`
deliberately answers 404 so the moderation surface is not disclosed, but it
was chained behind `requireUser`, which fired first and confirmed the endpoint
exists to any prober.

**An invisible overlay swallowed every click.** The empty-beach "tide is out"
notice reused `.veil` (`position: fixed; inset: 0`). Making it transparent hid
it visually but changed nothing about hit-testing, so after opening the last
bottle an invisible sheet covered the page and the header buttons silently
stopped working. Now `.notice-layer` with `pointer-events: none`.

**Registration errors did not name their field.** Only `issues[0]` was
returned, so a bad handle *and* a short password showed the handle error
alone - fixing it revealed a second error the user could not have anticipated.

---

## What was verified, not assumed

- **Stateless app tier:** 20 consecutive authenticated requests through the
  ALB all returned 200. In-memory sessions would have failed roughly half.
  This is the claim the whole Auto Scaling story rests on.
- **Weighted discovery:** 4000 draws with weights 1/2/4/8 produced
  7.1/14.7/25.4/53.0% against expected 6.7/13.3/26.7/53.3%.
- **Concurrent migrations:** four simultaneous runs against an empty database
  applied each migration exactly once (Postgres advisory lock).
- **Full loop on AWS:** write → pending → moderator approves → a *different*
  user finds it on the beach → opens → keeps. Author correctly does not see
  their own bottle.
- **Teardown:** 49 resources destroyed, then a direct AWS sweep confirmed zero
  instances, load balancers, target groups, RDS instances, NAT gateways,
  Elastic IPs, non-default VPCs, ASGs and EBS volumes.
- **SSM Session Manager** reaches both instances - used to promote the first
  moderator, since RDS has no public endpoint. Validates the no-SSH design.

---

## Known issues / next session

**Nothing is currently running.** The stack is destroyed; only the S3 state
bucket and artifact bucket remain (both near-zero cost).

Open items, roughly in priority order:

1. **Seed messages** - ~30 hand-written ones. *(Sampson)* These set the tone
   for every new arrival, which is the thing you were least sure about
   conveying.
2. **The UI has only been seen once, briefly.** Nobody has evaluated the
   opening animation timing (~2.5s, a guess), the bottle scatter, or the
   horizon where sea meets sand. The click bug is fixed but unverified in a
   browser.
3. **`make-moderator.sh` is local-only.** On AWS, promotion currently requires
   an SSM `send-command` with an inline Node script. Worth a proper admin path.
4. **No TLS.** Needs a domain name → ACM certificate → HTTPS listener → flip
   `COOKIE_SECURE=true` and `enable_https=true`.
5. **Load test not yet run.** Hammer `/api/beach`, watch the ASG go 2 → 4,
   document where the discovery query degrades. This is the strongest
   portfolio artifact available and it is cheap.
6. **Console screenshots** - deferred deliberately. Now that the architecture
   is understood, recreating it in the console is faster and the screenshots
   are more informed.
