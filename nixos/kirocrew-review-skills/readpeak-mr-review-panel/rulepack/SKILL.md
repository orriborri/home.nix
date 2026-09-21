---
name: readpeak-rulepack
description: Per-repo Sage rule pack for readpeak infra repos (cdk, cloudformation, eks-workloads). Additional review checks layered on Sage's generic dimensions — encodes readpeak's hard-won CloudWatch, KEDA, CDK, and secrets conventions. Read-only reuse, no fork of the core ruleset.
version: 1.0.0
tags: [code-review, readpeak, infra, cdk, cloudformation, kubernetes]
---

# Readpeak Infra Rule Pack

Additional review rules for `readpeak/cdk`, `readpeak/cloudformation`, and
`readpeak/eks-workloads`. Applied ON TOP OF Sage's 10 generic dimensions — every
finding still needs a chain of consequences (cause → mechanism → consequence)
and is DRAFT-ONLY. These encode defects that have actually shipped or been caught
in these repos, so treat a match as high-signal.

## CloudWatch alarms & step-scaling (cloudformation, cdk)

- **Step-scaling bounds are RELATIVE to the alarm threshold**, and for a
  LessThanThreshold (scale-in) breach they are NEGATIVE. Enforce: exactly ONE
  step has a null/open bound; the deepest (most-negative) scale-in band uses
  `MetricIntervalUpperBound` ONLY (no lower bound); bands are contiguous — no
  gaps, no overlaps. A gap/overlap or a bounded deepest band is a 🔴 (silent
  mis-scaling; cfn-lint does NOT catch it — only a deploy does).
- **Comments that hard-code a tuning** ("2x/4x band", "1200/min") are stale the
  moment a param is retuned — flag as 🟡 unless documented as threshold-relative
  offsets calibrated for a named default.
- **Metric-math**: a mixed `[time-series, scalar]` array to `MAX` (e.g.
  `MAX([FILL(x,1),1])`) is INVALID and rejected at deploy. Use `FILL(x,1)`
  directly as a divisor floor — division-by-zero drops the datapoint, no MAX
  guard needed. 🔴.
- **FILL-in-ALARM on a 1-of-1 evaluation can STICK** (fabricates a value that
  pins the alarm) when the latest minute is chronically missing. Prefer an
  M-of-N alarm (e.g. EvaluationPeriods 3 / DatapointsToAlarm 2). 🟡→🔴 if it
  gates a scaling action.
- **EstimatedInstanceWarmup on a scale-IN policy** stalls the descent — omit it
  from scale-in. StepScaling has no cooldown; a sustained breach re-applies the
  step ~once/min by design. Flag a warmup on a scale-in policy. 🟡.

## KEDA / autoscaling (eks-workloads, cdk)

- **`metricType: AverageValue` paired with an `avg(...)` PromQL query is a
  double-average bug** — the HPA divides by replica count again, under-scaling.
  Correct: `sum(...)` + AverageValue (per-pod target), or `avg(...)` + Value. 🔴.
- **Averaging a per-pod saturation metric hides a hot pod** (single-threaded
  Node makes hot pods routine). Use `max()`-over-pods for guardrail triggers;
  `histogram_quantile(0.95/0.99)` for latency, never a fleet-average ratio. 🟡.
- **Scaling Node.js on CPU** is the worst signal (event loop saturates while CPU
  looks normal). Prefer ELU (event-loop utilization) primary, raw lag as a
  high-threshold wedged-loop guardrail only. 🟡.
- **KEDA `identityOwner: operator`** makes ANY ScaledObject query under the
  operator SA cred (cluster-wide cross-tenant read). Use `identityOwner: workload`
  bound to the namespace SA, and scope the IAM policy to the single workspace
  ARN, not `Resource: *`. 🔴 (security).
- **KEDA fallback only fires on query ERROR, never on stale-but-valid data** — a
  single-replica collector SPOF returning ~0 scales DOWN under load. Require ≥2
  collector replicas + PDB AND staleness-aware PromQL. 🔴.

## CDK conventions (cdk)

- **Hand-rolled IAM role** where the shared `createPodIdentityRole` construct
  applies → use the construct + scoped `addToPolicy`; drop fixed `roleName`; trim
  actions to the minimum (e.g. `aps:QueryMetrics`, `rds-db:connect`). 🟡→🔴 if
  over-broad.
- **Service-specific stack bundling general access policies** (e.g. metabase
  stack owning db_admin/dev_readonly) — scope a service stack to that service's
  own administration only. 🟡.
- **`CfnOutput` for secrets** / `unsafeUnwrap()` in outputs → SSM SecureString
  instead. 🔴 (secret exposure).
- **IAM is owned by cdk; eks-workloads only CONSUMES ARNs** (via SSM). An IAM
  role/policy authored in eks-workloads is in the wrong repo. 🟡 (architecture).
- **Pure logic as a class method** that doesn't use `this` → standalone function
  (per repo coding guideline). NOT for CDK construct creation, which needs scope.
  🟡.
- **VPC Gateway Endpoints (S3, DynamoDB) are free** — removing one is a pure cost
  regression (~$0.045/GB through NAT). Flag any removal. 🔴.
- **`jest.config.base.js` and other shared `require()`d files** — a deletion
  breaks CI for stacks that weren't updated. Verify against actual diff + grep. 🔴.

## Secrets / K8s (eks-workloads)

- **External Secrets over `secretGenerator`** is the established convention — if
  the repo already uses ExternalSecret, "switch to secretGenerator" is NOT a fix.
- **ExternalSecret target name colliding with a same-named ConfigMap** →
  `creationPolicy: Owner` won't adopt a pre-existing object (CreateContainerConfig
  error). Fix is RENAME the Secret target, not flipping `secretKeyRef` →
  `configMapKeyRef` (the Secret source can be deliberate/SSM-synced). 🔴.
- **PodSecurity `restricted` namespaces** — `kubectl run` / pod specs need
  runAsNonRoot, runAsUser, seccompProfile RuntimeDefault, drop ALL caps, no
  privilege escalation, or admission rejects them. 🟡.

## RDS / data (cdk, cloudformation)

- **MariaDB GRANT + REVOKE is additive** — a table-level REVOKE cannot subtract a
  database-level GRANT. Use an allowlist or reporting-schema views. 🔴.
- **RDS IAM auth with Knex** — use Knex's async connection factory +
  expirationChecker (refresh before the 15-min TTL), NOT the mysql2 authPlugins
  hook (stale-token bug). expirationChecker must eventually return true. 🔴.
