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

## 3. Health-check timing — 15s interval, 3 thresholds, 60s grace

**Choice:** ALB target group health check every 15s, path `/health`, 3 checks to
flip healthy or unhealthy; ECS `health_check_grace_period_seconds = 60`.

**Why:** These have to balance two failure modes. Too aggressive (short interval
/ threshold of 1 / no grace period) and a cold-starting task gets killed before
it finishes booting, producing *false* rollbacks. Too lax (long interval / high
thresholds) and a genuinely broken v3 takes a long time to be declared failed,
slowing the demo. ~45s to declare healthy (3×15s) with a 60s grace window is a
comfortable middle for a container that boots in a second or two, and it still
detects v3's broken `/health` well within the deployment window.

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
