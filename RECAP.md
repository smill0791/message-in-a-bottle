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

## Phase 3 gotchas (CI/CD, 2026-08-29)

### 14. A new artifact in S3 does not trigger a deployment

The intuitive model - upload the build, the Auto Scaling group picks it up - is
wrong. Instances fetch the artifact **once**, in user data, at first boot.
Publishing to the same S3 key leaves the launch template byte for byte
identical, so nothing is replaced and the fleet serves the old build forever.

The pipeline goes green and the site does not change, which is the worst
possible combination. `scripts/deploy.sh` exists to call
`start-instance-refresh` explicitly and poll it to completion.

### 15. The CI role cannot live in the main stack

`terraform destroy` is the teardown and it runs after every session. A deploy
role defined in that state is destroyed with it, and the next pipeline has no
identity to come back with - recoverable only by a manual local apply, which
defeats the point of having CI.

`infra/bootstrap/` is a separate root with its own state key
(`bottle/bootstrap.tfstate`) holding the OIDC provider and both CI roles. It is
applied from a laptop, once. CI cannot apply it, because it creates the
credential CI authenticates with.

### 16. `provider "aws"` pinned a profile that does not exist in CI

`profile = var.aws_profile` defaulted to `aws-dev-project`, which lives only in
`~/.aws/config` on the laptop. On a runner this fails before a single resource
is planned. It now collapses to `null` when empty, and CI sets
`TF_VAR_aws_profile: ""`.

Note `null` and `""` are not interchangeable: an empty string is still a
lookup, for a profile named `""`.

### 17. Fresh `apply` needs the artifact published *before* the ASG exists

On an empty account a single `terraform apply` creates the artifact bucket and
the Auto Scaling group in one run. The instances boot, find an empty bucket,
fail their bootstrap, fail the ELB health check, and get replaced in a loop -
while billing.

`stack:up` therefore does three steps: targeted apply of the bucket, publish
the artifact, then the full apply.

### 18. `docker exec` cannot reach a CI service container

`e2e.sh` and `seed.sh` shelled out to `docker exec bottle-db psql`. In GitLab,
Postgres is a service container on another host and there is nothing to exec
into. Conversely this laptop has no `psql` binary at all - only the one inside
the container.

`scripts/lib/db.sh` now prefers a real client over `DATABASE_URL` and falls
back to `docker exec`, so both environments work from one definition.

### 19. Node's type stripping does not resolve `.js` to `.ts`

The project follows the NodeNext convention of importing `./screen.js` from
TypeScript source. `node --test --experimental-strip-types` does not rewrite
that specifier and fails with `ERR_MODULE_NOT_FOUND` on a file that plainly
exists.

The test runner is now `node --import tsx --test`. `tsx` was already a
dependency and handles the convention.

### 20. `npm test` passed with zero tests

The glob `src/**/*.test.ts` matched nothing and the runner exited 0. CI would
have reported "tests passed" forever without a single assertion existing - a
green badge that means nothing is worse than no badge.

There are now 21 real unit tests over `screen()` and `computeWeight()`, chosen
because they are pure and because they encode design claims (the sub-linear
resonance curve) that a later tuning change could quietly break.

### 21. ESLint `allowDefaultProject` rejects `**` globs

Test files are excluded from `api/tsconfig.json` so they never reach `dist`,
which also puts them outside the TypeScript program that type-aware lint rules
need. The obvious fix - `allowDefaultProject: ["api/src/**/*.test.ts"]` - is
rejected outright: the option forbids `**`.

`api/tsconfig.eslint.json` exists solely to give ESLint a program that includes
the tests. It never emits anything.

### 22. A service control policy blocks OIDC entirely

The single biggest constraint found in this phase, and it is invisible until
you try to apply:

```
AccessDenied: iam:CreateOpenIDConnectProvider ... explicit deny in a
service control policy (arn:aws:organizations::714989832131:.../p-iyptwjyf)
```

Free Plan accounts sit inside an **AWS-managed organization**, and its SCP
cannot be read or edited from the account - `iam:ListOpenIDConnectProviders`,
`iam:GetAccountSummary` and `iam:ListRoles` are all denied too, so you cannot
even enumerate what exists.

What *is* permitted, established by probing: `CreateRole`, `CreateUser`,
`CreateAccessKey`. So role-based access works; federation does not.

The fallback is an IAM user whose only permission is `sts:AssumeRole` on the
two CI roles. Worth stating plainly why that shape was chosen over the obvious
one: with the policies attached directly to users, the long-lived key in GitLab
*is* the permission, and a leaked terraform key would be immediate
PowerUserAccess usable from anywhere. Here the key grants one capability -
ask STS for a session - so the blast radius is bounded by the role policy,
there is one credential to rotate rather than two, and CloudTrail records every
use as an AssumeRole naming the pipeline and job.

What is genuinely lost: OIDC pins the branch and project *in the AWS trust
policy*. That protection now rests on GitLab's Protected variable flag. If
`main` is not a protected branch, the variables are invisible and every AWS job
fails - which is also the failure mode if somebody unprotects it later.

`infra/bootstrap/` keeps the OIDC code behind `enable_oidc`, default false.

### 23. IAM tag values reject semicolons and commas

A `Purpose` tag reading `"Assumes roles only; holds no permissions"` failed the
apply outright:

```
ValidationError: Value at 'tags.2.member.value' failed to satisfy constraint:
Member must satisfy regular expression pattern: [\p{L}\p{Z}\p{N}_.:/=+\-@]*
```

Letters, spaces, digits and `_ . : / = + - @` only. No semicolon, and **no
comma** either, which is the one that catches ordinary English prose.

### 24. RDS creates a log group Terraform does not own, and destroy leaves it

Verified on the 2026-09-01 full cycle. After a clean `Destroy complete!` and a
sweep showing zero billable resources, one thing remained:

```
/aws/rds/instance/bottle-db/postgresql   retention: None   4571 bytes
```

`enabled_cloudwatch_logs_exports = ["postgresql"]` on the RDS instance makes
**AWS** create that log group, not Terraform. It is therefore outside the
state, survives `terraform destroy`, and - because AWS creates it with no
retention policy - **never expires**.

The application's own `/bottle/app` group was destroyed correctly, because
Terraform owns it. The difference is instructive: a resource created as a side
effect of another resource is not managed by the thing that caused it.

Cost is negligible at this size, but it accumulates on every cycle and is the
same class of orphan as the automated snapshot in gotcha #10.

**Fix:** declare the log group in Terraform, with retention, so it is owned and
destroyed like anything else. It must be created *before* the RDS instance, or
AWS creates it first and the apply fails with an already-exists error:

```hcl
resource "aws_cloudwatch_log_group" "rds" {
  name              = "/aws/rds/instance/${var.name}-db/postgresql"
  retention_in_days = var.log_retention_days
}
```

Note the existing orphan has to be deleted by hand once, or imported, before
that will apply cleanly.

**General lesson:** "terraform destroy succeeded" and "the account is empty"
are different claims. Sweep directly, every time. Both this and gotcha #10 were
found only because the sweep exists.

### 25. zsh word-splitting, again - this time it faked a passing security test

Gotcha #9 recurred while verifying the new roles, and did real damage to the
conclusion rather than just failing loudly.

A permission matrix looped over command strings and ran `aws $p`. In zsh the
unquoted variable is **not** word-split, so every probe was passed as one
argument and failed. The "should be allowed" half reported DENIED, which looked
like a broken policy - but far worse, the "must NOT be allowed" half reported
`denied (correct)` for everything, which looked like a **passing security
test** and proved nothing at all.

Two lessons, the second more important than the first:

- Loop over commands with `bash -c`, an array, or `eval` - never `aws $p` in zsh.
- The probes discarded stderr (`2>&1` into a test). A negative test that cannot
  distinguish "denied by policy" from "command was malformed" is not a test.
  This is gotcha #8 wearing a different hat.

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

*Updated 2026-09-01, after the first full CI-driven cycle.*

**Nothing is currently running.** The stack was applied from CI, deployed to,
and destroyed. A direct sweep confirmed zero billable resources. Only the S3
state bucket and the two CI IAM roles remain, all free.

Open items, roughly in priority order:

1. **Seed messages.** A set has now been written and is collected in a text
   file. Two things stand between that and the beach:
   - `scripts/seed.sh` has its placeholder messages hardcoded in SQL. It
     should read a file instead, so the seed set is data rather than code.
   - **There is no way to seed the AWS database at all.** RDS has no public
     endpoint, so seeding there needs the same SSM `send-command` route as
     `make-moderator.sh`. This is the same gap twice, and worth solving once.
2. **`make-moderator.sh` is local-only.** See above - one admin path would
   cover both this and seeding.
3. **The UI has only been seen once, briefly.** Nobody has evaluated the
   opening animation timing (~2.5s, a guess), the bottle scatter, or the
   horizon where sea meets sand. The click bug is fixed but unverified in a
   browser. The stack was up for ~45 minutes on 2026-09-01 and this was still
   not done.
4. **Load test not yet run.** Hammer `/api/beach`, watch the ASG go 2 → 4,
   document where the discovery query degrades. This is the strongest
   portfolio artifact available and it is cheap - and now that CI can raise
   and destroy the stack on a button, the setup cost is gone.
5. **No TLS.** Needs a domain name → ACM certificate → HTTPS listener → flip
   `COOKIE_SECURE=true` and `enable_https=true`.
6. **Console screenshots** - deferred deliberately. Now that the architecture
   is understood, recreating it in the console is faster and the screenshots
   are more informed.

### Resolved on 2026-09-01

- **Automated RDS snapshots (gotcha #10).** `backup_retention_days = 0` fixed
  it; verified through a complete cycle with no snapshot left behind.
- **Orphaned Postgres log group (gotcha #24).** Found by the sweep, deleted,
  and the log group is now declared in `modules/data` with retention so
  Terraform owns and destroys it.
- **Second full apply/destroy cycle**, which had been outstanding since Phase
  2 - this one ran entirely from CI under a scoped role rather than from a
  laptop with admin credentials.
