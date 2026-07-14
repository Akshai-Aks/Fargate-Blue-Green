# Design Decisions & Trade-offs

This document records the significant choices made in this exercise and the
alternatives that were rejected.

## 1. Subnet layout — public subnets for tasks, no NAT gateway

**Choice:** A minimal VPC with two public subnets (two AZs). Both the ALB and
the Fargate tasks live in the public subnets, and tasks get a public IP
(`assign_public_ip = true`).

**Why:** Fargate tasks must reach ECR (image pull) and CloudWatch Logs. The two
ways to give a task in a *private* subnet that egress are (a) a NAT gateway or
(b) interface/gateway VPC endpoints for ECR, S3, CloudWatch and STS. Both add
cost and moving parts. For a short-lived exercise that is torn down within 24h,
public subnets with a public IP are the cheapest and simplest path, and the
tasks are still not reachable from the internet because their security group
only accepts traffic from the ALB.

**Rejected alternative (production choice):** Private subnets for tasks + a NAT
gateway (or VPC endpoints) + public subnets only for the ALB. This is the
correct posture for real workloads — the task ENIs never get a public IP — but
NAT gateways bill hourly + per-GB, which is unjustified here. The security group
rules are written so switching to private subnets later is only a networking
change, not an app change.

## 2. Deployment configuration — `ECSAllAtOnce`

**Choice:** `CodeDeployDefault.ECSAllAtOnce` with automatic traffic shift
(`deployment_ready_option.action_on_timeout = CONTINUE_DEPLOYMENT`).

**Why:** The exercise's goal is to *demonstrate* a blue/green cutover and a
failed-deploy rollback quickly. All-at-once shifts 100% of traffic the moment
the replacement task set is healthy, so a healthy v2 goes live fast and a broken
v3 fails fast (its tasks never pass the target-group health check, so CodeDeploy
never shifts traffic and rolls back). Canary/linear configs would stretch the
demo out with bake times that add nothing to what we're proving.

**Rejected alternative (production choice):**
`CodeDeployDefault.ECSCanary10Percent5Minutes` (or a linear config) plus
CloudWatch-alarm-based rollback. In production you want a canary so a bad
release only touches a fraction of traffic before alarms trip. That is the right
call for a real service but slows and complicates the demonstration.

## 3. Health-check timing — 10s interval, 2 thresholds, **0s grace**

**Choice:** ALB target group health check every 10s, path `/health`, 2
consecutive checks to flip healthy or unhealthy; ECS
`health_check_grace_period_seconds = 0`.

**Why:** The grace period is the subtle one, and getting it wrong breaks the
whole rollback story. `health_check_grace_period_seconds` tells the ECS
scheduler to *ignore* load-balancer health for that many seconds after a task
starts. During a CodeDeploy blue/green deployment, ECS reports the replacement
task set as "healthy" while the grace window is open (the task is merely
RUNNING). CodeDeploy takes that as its cue to shift production traffic and mark
the deployment **Succeeded** — which, with a 60s grace period, happened *before*
the ALB ever noticed the broken v3 returning 500. The old task set was then
terminated, so there was nothing left to roll back to, and the broken release
stayed live. (This was observed in practice; see the note below.)

Because the app binds in under two seconds and serves `/health` immediately, it
needs no warm-up window at all, so the grace period is set to **0**: ECS honors
the health check from the start, a broken task never reports healthy, CodeDeploy
never cuts traffic over to it, and `auto_rollback_configuration` fires. The
10s interval with a threshold of 2 declares a healthy v2 ready in ~20s and a
broken v3 failed in ~20s — fast for the demo without being so twitchy that a
genuinely healthy task is failed mid-startup (which would cause *false*
rollbacks, the failure mode the brief warns about).

> **Lesson learned:** an initial 60s grace period let a broken v3 deploy succeed
> instead of rolling back. The grace period must be shorter than the window in
> which CodeDeploy evaluates replacement-set health — for an instant-start app,
> that means 0.

## 4. CodeDeploy owns rollouts — Terraform `ignore_changes`

**Choice:** The ECS service uses the `CODE_DEPLOY` deployment controller, and
Terraform ignores changes to `task_definition`, `load_balancer`, and
`desired_count` on the service, and to `default_action` on the prod listener.

**Why:** With blue/green, CodeDeploy is the component that registers new task
sets and rewrites the listener's default action to point at the newly-healthy
target group. If Terraform did not ignore those attributes, the next
`terraform apply` would try to "correct" the live listener back to blue and
reset the task definition, fighting CodeDeploy and potentially reverting a good
deployment. Ignoring them makes Terraform own the *infrastructure* and
CodeDeploy own the *rollouts* — a clean split of responsibilities.

## 5. Image strategy — one Dockerfile, behaviour via build args

**Choice:** A single tiny Python-stdlib app and Dockerfile. `APP_VERSION` and
`HEALTHY` are build args, so v1/v2 are healthy and v3 is a genuinely broken
*image* (its `/health` returns 500) rather than a config toggle.

**Why:** It keeps the repo minimal (no framework, no dependencies → tiny image,
fast pulls) while making v3 a real broken artifact, which is a more honest test
of rollback than flipping an env var on an otherwise-good image.
