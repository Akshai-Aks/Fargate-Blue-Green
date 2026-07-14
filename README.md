# ECS Fargate Blue/Green via CodeDeploy

Deploys a containerized web app on **ECS Fargate** behind an **Application Load
Balancer**, using **CodeDeploy** for **blue/green** deployments with health
checks and **automatic rollback** on failure.

The demonstration proves three things:

1. **v1** — an initial healthy release comes up behind the ALB.
2. **v2** — a healthy upgrade shifts traffic blue→green (blue/green works).
3. **v3** — an intentionally broken release (its `/health` returns `500`) fails
   its health check, so CodeDeploy **rolls back** and the service keeps serving
   **v2**.

---

## Architecture

```
                     Internet
                        │  HTTP :80
                 ┌──────▼───────┐
                 │     ALB      │  (public subnets, 2 AZs)
                 │  listener:80 │
                 └──────┬───────┘
              default action (managed by CodeDeploy)
                 ┌──────┴───────┐
        ┌────────▼──────┐  ┌────▼─────────┐
        │ TG "blue"     │  │ TG "green"   │   target_type = ip
        └────────┬──────┘  └────┬─────────┘
                 │              │
          ┌──────▼──────────────▼──────┐
          │  ECS Fargate service       │  CODE_DEPLOY controller
          │  (tasks in public subnets, │  tasks SG: :8080 from ALB only
          │   assign_public_ip = true) │
          └────────────┬───────────────┘
                       │ pull image / ship logs
             ┌─────────▼─────────┐   ┌──────────────────┐
             │       ECR         │   │ CloudWatch Logs   │
             └───────────────────┘   └──────────────────┘

CodeDeploy application + deployment group orchestrate blue/green:
launch replacement task set on the idle TG → wait for health → shift
listener → (on failure) auto-rollback to the original TG.
```

### Repository layout

```
app/                Minimal HTTP app (/health, /) + Dockerfile
terraform/          All AWS infrastructure
  network.tf        VPC, subnets, IGW, routes, security groups
  ecr.tf            ECR repo + lifecycle + scan-on-push
  iam.tf            Task exec role, task role, CodeDeploy service role
  logs.tf           CloudWatch log group
  alb.tf            ALB, blue + green target groups, prod listener
  ecs.tf            Cluster, task definition, service (CODE_DEPLOY controller)
  codedeploy.tf     CodeDeploy app + blue/green deployment group + rollback
  outputs.tf        Values consumed by the scripts
scripts/
  build_push.sh     Build + push an image version to ECR
  deploy.sh         Register task def + create a CodeDeploy deployment (waits)
  verify.sh         curl the ALB for the live version + health status
  collect_evidence.sh  Dump `aws deploy get-deployment` into evidence/
appspec/            Reference AppSpec (deploy.sh generates the real one)
evidence/           Rollback evidence goes here
decisions.md        Trade-offs (subnet layout, deploy config, health timing, …)
```

---

## Prerequisites

- Terraform `>= 1.5`, AWS provider `~> 5.0` (pinned in `terraform/versions.tf`)
- AWS CLI v2, configured with credentials that can create the resources above
- Docker (with buildx; images are built `--platform linux/amd64` for Fargate)
- `jq`
- Region defaults to **`ap-south-1`** (override with `-var aws_region=…`)

---

## Deploy flow

There is a one-time chicken-and-egg step: the ECS task can't start until a v1
image exists in ECR, but the ECR repo is created by Terraform. So we create ECR
first, push v1, then apply the rest.

### 0. Init

```bash
cd terraform
terraform init
```

### 1. Create ECR, then build + push v1

```bash
# create just the ECR repository first
terraform apply -target=aws_ecr_repository.app -auto-approve

# build + push the initial healthy image
cd ..
./scripts/build_push.sh v1
```

### 2. Apply the rest of the infrastructure (brings up v1)

```bash
terraform -chdir=terraform apply -auto-approve
```

When apply finishes, the ECS service launches the v1 task, the ALB target group
turns healthy, and:

```bash
./scripts/verify.sh
#   GET /        -> {"version": "v1"}
#   GET /health  -> HTTP 200
```

### 3. Upgrade to v2 (blue/green cutover)

```bash
./scripts/build_push.sh v2
./scripts/deploy.sh v2       # registers a new task def, creates a CodeDeploy deployment, waits
./scripts/verify.sh
#   GET /        -> {"version": "v2"}
#   GET /health  -> HTTP 200
```

`deploy.sh` prints the deployment id and its final status. Traffic shifts from
the blue target group to green once the v2 tasks pass the health check.

### 4. Deploy broken v3 (triggers rollback)

```bash
./scripts/build_push.sh v3   # this image's /health returns 500 on purpose
./scripts/deploy.sh v3        # deployment FAILS; CodeDeploy auto-rolls back to v2
```

The v3 replacement task set never becomes healthy, so CodeDeploy never shifts
production traffic and, per the deployment group's
`auto_rollback_configuration`, marks the deployment failed and rolls back.

```bash
./scripts/verify.sh
#   GET /        -> {"version": "v2"}   <- still v2, rollback succeeded
#   GET /health  -> HTTP 200
```

### 5. Capture rollback evidence

```bash
./scripts/collect_evidence.sh        # uses the last deployment id
# writes evidence/deployment-<id>.json and prints the status + rollbackInfo
```

Expected in the output: `"status": "STOPPED"` (or `"FAILED"`) with a
`rollbackInfo` block referencing the automatic rollback deployment. Commit the
JSON (and/or a CodeDeploy console screenshot) under `evidence/`.

---

## Teardown

```bash
terraform -chdir=terraform destroy -auto-approve
```

The ECR repo is created with `force_delete = true`, so `destroy` removes it even
with images still present. **Tear down within 24 hours of submission.**

If a deployment is mid-flight when you destroy, stop it first:

```bash
aws deploy stop-deployment --deployment-id "$(cat .last_deployment_id)" \
  --auto-rollback-enabled --region ap-south-1
```

---

## How rollback actually works here

- The ECS service uses the **`CODE_DEPLOY`** deployment controller — the piece
  the brief calls out as easy to miss.
- Two target groups (`blue`, `green`) are attached to one prod listener via the
  deployment group's **`load_balancer_info.target_group_pair_info`** block.
- On each `deploy.sh` run, CodeDeploy launches the new task set on the *idle*
  target group and waits for ALB health checks to pass.
- **Success (v2):** it rewrites the listener default action to the new target
  group and (after a 1-minute wait) terminates the old task set.
- **Failure (v3):** the new tasks fail `/health`, so they never become healthy;
  the deployment times out/fails and `auto_rollback_configuration`
  (`events = ["DEPLOYMENT_FAILURE"]`) leaves the listener pointed at v2 and
  tears the broken task set down.

Terraform deliberately `ignore_changes` on the service's `task_definition` /
`load_balancer` and the listener's `default_action` so re-running
`terraform apply` doesn't fight CodeDeploy. See `decisions.md`.

---

## Notes / knobs

- Change region/size/etc. via `terraform/terraform.tfvars` (see
  `terraform.tfvars.example`) or `-var` flags.
- `platform_version` is pinned to `1.4.0` (the brief warns AI snippets often get
  this wrong); `LATEST` also works.
- To slow the cutover down for a more production-like demo, switch
  `deployment_config_name` in `codedeploy.tf` to
  `CodeDeployDefault.ECSCanary10Percent5Minutes`.
