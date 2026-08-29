# AWS Portfolio Roadmap - Message in a Bottle

Three projects: a scalable 3-tier web app, the same infrastructure in Terraform,
and a CI/CD pipeline. Sequenced around the real constraint, which is credits, not
difficulty.

> **Status as of 2026-08-29:** Phase 0 and Phase 2 (Terraform) complete. The
> stack has been applied, verified end to end on AWS, and destroyed. **Nothing
> is running.** Next up is Phase 3, CI/CD.
>
> **Read `message-in-a-bottle/RECAP.md` before running anything.** Two items in
> particular will waste a session otherwise: Terraform must be the **arm64**
> build from `/opt/homebrew` (the x86 one runs under Rosetta and never
> completes an apply), and only the `aws-dev-project` profile may be used.

## The application

**Message in a Bottle** - users write short reflective messages (musings,
affirmations, struggles persevered through) which are "bottled" into a shared
pool. Other users log in to a digital beach, find bottles in the sand, uncork
them, read, and rate the message's theme. Well-rated messages surface more often.
Users keep a chest of what they've saved.

Deliberately not a news or social feed. Zen, anonymous, short form.

### Why it fits the infrastructure

- **Relational data is load-bearing.** Users, messages, discoveries
  (many-to-many with a uniqueness constraint), ratings, reports, saved state.
- **The app tier is naturally stateless.** Session in the DB or a signed cookie,
  assets on S3/CloudFront, nothing on local disk.
- **There is a real database problem at the centre** (see below), which makes
  load testing meaningful rather than theatrical.

### The technical centrepiece: bottle discovery

Select N messages a user has **not** already seen, weighted by vote score, from a
growing pool.

Naive `ORDER BY RANDOM()` collapses as the pool grows, and the anti-join against
prior discoveries compounds it. Real approaches: precomputed weight buckets,
cumulative-weight sampling, materialized candidate pools refreshed on a schedule.

This is the endpoint to load test, and the one worth writing up.

### Scope discipline

The backend is roughly four weekends. The **beach presentation is where scope
explodes**, and none of it teaches AWS.

**In v1:** static illustrated background, bottle sprites at randomized positions,
one good CSS uncork-and-unfurl animation.

**Deferred to polish:** panning the beach, ocean audio, dusting bottles off,
first-person framing, collectible trinkets, bottle variants.

**Set aside entirely:** monetization. The loot box loop is in tension with the
premise, and this is a learning project.

### Draft schema

| Table | Notes |
|---|---|
| `users` | anonymous handle, created_at |
| `messages` | author_id, body, status (pending/approved/rejected), created_at |
| `discoveries` | user_id, message_id, discovered_at, saved, favorited. **unique(user_id, message_id)** |
| `ratings` | user_id, message_id, theme, created_at |
| `reports` | user_id, message_id, reason, resolved |
| `message_stats` | denormalized vote count and discovery weight |

Character limit: **~500** as a starting point. Long enough for a real thought,
short enough to fit a handwritten note. Tune from experience.

Themes are a fixed set, and "sad" is not a negative rating - it is reflective.
Rating is theme classification, not quality scoring.

### Moderation is a feature, not a burden

Naturally asynchronous, which makes it good infrastructure:

```
submit -> RDS (pending) -> SQS -> Lambda -> denylist + tone classifier
                                              |
                          auto-approve / auto-reject / human review queue
```

Adds SQS, Lambda, EventBridge and Bedrock to the portfolio honestly.

Critically, a **tone classifier solves the "will users get the vibe" problem as
well as the safety problem**. Spam, ads and news takes are not profane, so a
denylist misses them, but a classifier checking for reflective intent catches
both. One pipeline, two problems.

**v1:** denylist plus a manual approval queue. The async pipeline is its own
phase.

### Onboarding

Seed the pool with a set of hand-written messages before launch, so a new user's
first three bottles establish the tone. Guide the first click with a gentle
animated indicator, not a wall of explanatory text.

## Account facts (verified 2026-08-27)

| Fact | Value |
|---|---|
| Account | 116307287000 |
| Plan | New AWS experience, **Free Plan** |
| Credits remaining | **$120**, expiring **2027-02-25** |
| Classic 12-month free tier | **Not applicable** - no 750 free EC2/RDS/ALB hours |
| Region (enforced) | **us-east-2** via profile `aws-dev-project` |
| Existing resources | Default VPC only. Nothing running. |
| Budgets in place | `northwind-zero-spend` ($1), `northwind-monthly-5-usd` ($5) |

Three traps:

1. The `[default]` CLI profile is **us-east-1**. The project region is
   **us-east-2**. Always pass `--profile aws-dev-project`, or export
   `AWS_PROFILE=aws-dev-project`. Resources cannot be created outside the
   assigned region.
2. `TEARDOWN.md` says to delete both budgets. **Do not** delete without
   replacing - they are the only thing standing between a forgotten NAT Gateway
   and the credit balance.
3. **Never alternate between the two CLI profiles.** `[default]` and
   `[profile aws-dev-project]` reference the *same* `login_session`, and every
   invocation rotates the underlying refresh token. Using one profile
   invalidates the other's cached grant, so alternating produces a constant
   stream of:

   ```
   ValidationException ... The provided authorization grant is invalid,
   expired, revoked, or malformed
   ```

   The session is fine; the grant was rotated out from under it. **Use
   `aws-dev-project` exclusively** (`export AWS_PROFILE=aws-dev-project`) - it
   carries the correct us-east-2 default. Treat `[default]` as off-limits.

   This matters in Phase 3: parallel CI jobs sharing one credential cache would
   hit this permanently, not intermittently. Each job needs its own OIDC role
   assumption rather than a shared cached session.

Services confirmed available on the Free Plan: EC2, VPC, Elastic Load Balancing,
RDS, Auto Scaling, CloudFormation, CodePipeline, CodeBuild, CodeDeploy,
CodeArtifact, Secrets Manager, Systems Manager, CloudWatch, ACM, Route 53, WAF.

Confirmed **unavailable** (would need advanced features activated): IAM Identity
Center, Organizations, Transit Gateway, Site-to-Site VPN, Client VPN, GuardDuty,
Security Hub, CodeCatalyst, Lightsail, DMS.

## The cost model, which drives everything

Rough on-demand rates for the Project 1 architecture:

| Component | Hourly | If left running 24/7 |
|---|---|---|
| Application Load Balancer | ~$0.0225 | ~$16/mo |
| 2x t3.micro EC2 | ~$0.021 | ~$15/mo |
| RDS db.t4g.micro + 20GB | ~$0.019 | ~$14/mo |
| NAT Gateway | ~$0.045 | ~$33/mo |
| Public IPv4 addresses | ~$0.005 each | ~$3.65/mo each |

**Running the full stack 24/7 burns the entire $120 in about six weeks.**
Running it for a focused three-hour work session costs about **$0.32**. The same
$120 buys roughly **370 hours** of the complete, correctly-architected stack.

The conclusion is not "cut the NAT Gateway" or "use a smaller instance." It is:

> **Build the architecture correctly. Run it briefly. Destroy it every time.**

Time is the currency here, not architecture. This is why Terraform moves earlier
than a normal learning path would put it - `terraform destroy` is the cost
control mechanism, not just a portfolio credential.

## Ordering

Your instinct that CI/CD could come before or alongside Terraform is half right.
Split it:

- **CI** (test, build, notify) has zero AWS dependency. It starts in Phase 1 and
  runs from the first commit.
- **CD** (deploy into AWS) must wait for Terraform. Building a deploy pipeline
  against hand-clicked resources means rewriting it as soon as those resources
  are replaced by Terraform-managed ones.

So the order is 1 → 2 → 3, with the CI half of 3 pulled forward to run alongside
everything.

---

## Phase 0 - Guardrails and the app decision

No AWS spend. One session.

- [x] Refresh credentials (`aws login`) and confirm `aws-dev-project` resolves to
      us-east-2. **Done** - 3 AZs confirmed (us-east-2a/b/c).
- [x] Budget for this project. **Done** - `bottle-monthly-10-usd`, alerts at
      50/80/100% actual plus 100% forecasted, all wired to smill0791@gmail.com,
      `IncludeCredit: false` so it tracks gross usage rather than post-credit
      spend. Verified subscribers are actually attached.
- [x] Inherited `northwind-*` budgets. **Both deleted** - `northwind-zero-spend`
      had a notification but no subscribers and could never alert anyone.
- [x] Tagging standard. **Done** - `Project`, `ManagedBy`, `Repo` applied to
      every resource via provider `default_tags`.
- [x] Teardown. **`terraform destroy` is the teardown** - a separate
      `nuke.sh` would be a second source of truth that drifts. Verified: 49
      resources destroyed, then a direct AWS sweep confirmed nothing billable
      remained.
- [x] Initialise the repo, pick the git host, push the first commit. **Done** -
      https://gitlab.com/aws-projects6841835/message-in-a-bottle
- [x] Schema + discovery query, verified against local Postgres 16. **Done.**
- [x] GitLab push mirroring to a public GitHub repo. **Done and verified** -
      https://github.com/smill0791/message-in-a-bottle. Note: GitLab's UI offers
      a separate Username field, which takes the **GitHub account name**
      (`smill0791`), not the email address, and the URL stays plain.
- [x] Build the API: auth, write, discover, rate, save, report. **Done** -
      36 end-to-end checks passing via `scripts/e2e.sh`.
- [ ] Hand-write ~30 seed messages to establish the tone. *(Sampson)* - the only
      Phase 0 item still open.
- [x] Build the beach UI (React + Vite). **Done** - seen once, needs a proper
      visual review.
- [x] Admin approval queue. **Done** - 60 checks passing. Grant rights with
      `./scripts/make-moderator.sh <handle>`.

**Note:** `scripts/e2e.sh` truncates the database, so it deletes any local
account you made. Re-register and re-grant moderator afterwards; `seed.sh`
restores the placeholder bottles.

**Exit criteria:** met, apart from the seed messages.

Building the app locally first means Phase 1 deploys something real instead of a
placeholder page, and it costs nothing.

## Phase 1 - Console build *(deferred, by decision 2026-08-28)*

Originally first. Moved to the end because Terraform teaches more: the console
silently creates route tables, default security group rules and subnet
associations for you, while Terraform forces you to name every one. Recreating
a stack you already understand also makes the screenshots faster and better
informed.

Now tracked as **Phase 6** below.

## Phase 2 - Terraform ✅ **COMPLETE** (2026-08-29)

The real deliverable. Full three-tier architecture, reproducible.

- [x] Install Terraform. **Note: must be the arm64 build** - see `RECAP.md`
      gotcha #1, which cost most of a session.
- [x] Remote state in S3 with native locking (`use_lockfile`, no DynamoDB).
- [x] Modules: `network`, `security`, `data`, `compute`. Root composes them.
- [x] Variables for everything that differs between a demo and a real run.
- [x] `terraform validate` and `plan` clean.
- [x] Full cycle: `apply` from empty → app serves traffic → `destroy` → AWS
      swept directly to confirm nothing billable remained.
- [x] VPC across two AZs, three subnet tiers. Data tier has **no internet route
      at all**.
- [x] Security groups chained by reference, never CIDR. Database has no egress
      rule whatsoever.
- [x] Launch template + ASG, min 2 max 4, ELB health checks, instance refresh
      configured as the Phase 3 deploy mechanism.
- [x] ALB with target group on `/api/healthz` - shallow by design, so an RDS
      blip cannot fail every target at once.
- [x] RDS single-AZ in the data subnets, `manage_master_user_password` so the
      password never enters Terraform state.
- [x] Prove it works: full loop verified on AWS (write → moderate → discover →
      open → keep), and 20 consecutive authenticated requests through the ALB
      confirming the app tier is genuinely stateless.
- [ ] **Second full apply/destroy cycle.** Only one has been run. The three
      bugs found (Rosetta, RDS TLS, ASG `name_prefix`) are fixed but the fixed
      version has not been applied from scratch.
- [ ] Kill an instance and watch the ASG replace it. Not yet done.
- [ ] Load test `/api/beach`, watch the ASG scale 2 → 4, document where the
      discovery query degrades.

**Exit criteria:** met for the core claim - the stack rises and falls with two
commands and leaves nothing billable behind. The remaining items are
demonstrations, not construction.

**See `message-in-a-bottle/RECAP.md`** for the full gotcha list. Read it before
running anything.

## Phase 3 - CI/CD ← **NEXT**

- [ ] **CI:** lint, test, build on every push. `scripts/e2e.sh` needs a Postgres
      service container in the pipeline.
- [ ] Slack notification on pass/fail, reusing the pattern from the earlier
      project.
- [ ] **CD:** OIDC federation to an AWS IAM role. No static access keys, ever.
- [ ] Build the artifact, upload to S3, roll it out via ASG instance refresh
      (already configured in the launch template).
- [ ] Deploy gated on tests passing.
- [ ] Slack notification on deploy start and finish, including the ALB URL.
- [ ] Optional and genuinely impressive: a scheduled job that destroys the stack
      nightly and recreates it on demand. Both a cost control and continuous
      proof the Terraform still works.

**Known traps for this phase, from `RECAP.md`:**

- **Credential caching.** `[default]` and `aws-dev-project` share a
  `login_session` and rotate each other's refresh token. Parallel CI jobs
  sharing one credential cache would hit this *permanently*. Each job needs its
  own OIDC role assumption.
- **Provider lock platforms.** Already fixed - the lock covers `linux_amd64`
  and `linux_arm64` as well as `darwin_arm64`. Without those, CI fails
  immediately.
- **`e2e.sh` truncates the database.** Fine in CI, destructive locally.

**Exit criteria:** a commit to main reaches AWS with no manual step, and Slack
says so.

## Phase 4 - Moderation pipeline

The async architecture described above. Its own phase because it is a distinct
piece of portfolio work, not a footnote.

- [ ] SQS queue fed on message submission.
- [ ] Lambda consumer: denylist, then tone/safety classification via Bedrock
      (confirm Bedrock is enabled in us-east-2 first).
- [ ] Three outcomes: auto-approve, auto-reject, route to human review.
- [ ] Admin review queue UI.
- [ ] User reporting, with a threshold that pulls a message from the pool
      automatically pending review.
- [ ] Dead letter queue and CloudWatch alarms on it.

## Phase 5 - Polish

Only after the infrastructure story is complete. Beach panning, ocean audio,
dusting bottles off, bottle variants, first-person framing.

Also outstanding, and smaller:

- [ ] **The UI has been seen once, briefly.** Nobody has evaluated the opening
      animation timing (~2.5s, a guess), the bottle scatter, or the horizon
      where sea meets sand.
- [ ] TLS: domain → ACM certificate → HTTPS listener → flip `COOKIE_SECURE=true`
      and `enable_https=true`. Until then the ALB speaks HTTP and the session
      cookie must **not** carry `Secure`.
- [ ] A proper admin path for granting moderator on AWS. `make-moderator.sh` is
      local-only; on AWS it currently takes an SSM `send-command` with an inline
      Node script.

## Phase 6 - Console build and screenshots

Deferred from Phase 1. Recreate the same architecture through the AWS console
for the portfolio write-up.

- [ ] VPC, subnets, route tables, IGW, NAT.
- [ ] Security group chain.
- [ ] Launch template, ASG, ALB, target group.
- [ ] RDS.
- [ ] Screenshot every page plus the working app.
- [ ] Tear down and confirm the account is empty.

Faster now than it would have been first: the architecture is understood, and
the Terraform serves as the reference for what each console page should say.

---

## Decisions made (2026-08-27)

1. **Stack: TypeScript end to end.** Fastify + TypeScript API, React + Vite
   frontend, Postgres (Docker locally, RDS in AWS).
   Hard requirement: the app tier stays **stateless**. Sessions in Postgres,
   uploads to S3, nothing on local disk. Otherwise the Auto Scaling group is
   decorative.
2. **Git: GitLab as the working remote**, with push mirroring to a public GitHub
   repo for visibility. OIDC to AWS from GitLab CI - no static access keys.
3. **Auth: simple session auth in Postgres** to start. Cognito is the migration
   target if the app ever gets real users. Anonymous handles suit the premise.
