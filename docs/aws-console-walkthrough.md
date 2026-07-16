# ECS Fargate Blue/Green via CodeDeploy — AWS Console Walkthrough

This is the click-by-click console equivalent of the Terraform in this repo. It
produces the **same architecture**: an ECS Fargate service behind an ALB, with
CodeDeploy blue/green deployments and automatic rollback driven by a CloudWatch
alarm.

> **Two honest caveats:**
> 1. **The console UI changes frequently.** Button labels and page layouts may
>    differ slightly from what's written here. The *fields and values* are what
>    matter — find the equivalent control if a label has moved.
> 2. **You cannot build a Docker image in the console.** ECR stores images but
>    doesn't build them. The image build+push steps use the CLI. If you have no
>    local Docker, use **AWS CloudShell** (has Docker + AWS CLI preconfigured) —
>    the icon is in the top navigation bar of the console.

**Region for everything below: `ap-south-1` (Mumbai).** Set it in the top-right
region selector *before* you start, and never switch it mid-way — resources are
region-scoped and won't see each other across regions.

**Reference values (match the Terraform):**

| Thing | Value |
|-------|-------|
| Project prefix | `fargate-bg` |
| Container port | `8080` |
| ALB listener port | `80` |
| Task CPU / memory | `256` / `512` |
| Health check path | `/health` (expect HTTP 200) |
| Health check | interval `10s`, healthy/unhealthy threshold `2` |
| ECS health-check grace period | `0` |
| Deployment config | `CodeDeployDefault.ECSAllAtOnce` |

---

## Order of operations (why this sequence)

Resources reference each other, so build bottom-up:

```
1. VPC + subnets + IGW + routes        (network foundation)
2. Security groups                     (needs VPC)
3. ECR repo                            (independent)
4. Build + push v1 image  [CLI]        (needs ECR)
5. IAM roles (task exec, task, CodeDeploy)
6. CloudWatch log group
7. Target groups (blue + green)        (needs VPC)
8. ALB + listener :80                  (needs subnets, SG, blue TG)
9. ECS cluster
10. Task definition                    (needs IAM roles, log group, ECR image)
11. ECS service (CODE_DEPLOY)          (needs everything above) -> brings up v1
12. CloudWatch alarms (unhealthy hosts)(needs target groups + ALB)
13. Attach alarms to CodeDeploy DG
14. Deploy v2 (blue/green)             (via CodeDeploy)
15. Deploy v3 (broken) -> rollback     (via CodeDeploy)
16. Evidence + teardown
```

---

## 1. VPC, subnets, internet gateway, routing

You can use the default VPC to save time, but here's the explicit build that
matches the repo.

### 1a. Create the VPC
1. Console → search **VPC** → open the VPC service.
2. Left nav → **Your VPCs** → **Create VPC**.
3. Select **VPC only** (not "VPC and more" — we'll add pieces explicitly so you
   learn each one; "VPC and more" auto-creates subnets/NAT and hides the wiring).
4. **Name tag:** `fargate-bg-vpc`
5. **IPv4 CIDR:** `10.0.0.0/16`
6. Leave IPv6 = No, Tenancy = Default. → **Create VPC**.
7. Open the new VPC → **Actions → Edit VPC settings** → tick **Enable DNS
   hostnames** (DNS resolution is on by default). Save.

### 1b. Create two public subnets (different AZs)
1. Left nav → **Subnets** → **Create subnet**.
2. **VPC:** select `fargate-bg-vpc`.
3. Subnet 1: Name `fargate-bg-public-1`, AZ `ap-south-1a`, CIDR `10.0.1.0/24`.
4. Click **Add new subnet**. Subnet 2: Name `fargate-bg-public-2`, AZ
   `ap-south-1b`, CIDR `10.0.2.0/24`.
5. **Create subnet.**
6. For **each** subnet: select it → **Actions → Edit subnet settings** → tick
   **Enable auto-assign public IPv4 address** → Save. (Fargate tasks need a
   public IP to pull from ECR without a NAT gateway.)

### 1c. Internet gateway
1. Left nav → **Internet gateways** → **Create internet gateway**.
2. Name `fargate-bg-igw` → **Create**.
3. On the new IGW → **Actions → Attach to VPC** → select `fargate-bg-vpc` →
   **Attach**.

### 1d. Route table → route to the internet
1. Left nav → **Route tables** → **Create route table**.
2. Name `fargate-bg-public-rt`, VPC `fargate-bg-vpc` → **Create**.
3. Select it → **Routes** tab → **Edit routes** → **Add route**:
   - Destination `0.0.0.0/0`, Target **Internet Gateway** → `fargate-bg-igw`.
   - **Save changes.**
4. **Subnet associations** tab → **Edit subnet associations** → tick both
   `fargate-bg-public-1` and `-2` → **Save associations**.

---

## 2. Security groups

### 2a. ALB security group (public HTTP in)
1. VPC service → left nav → **Security groups** → **Create security group**.
2. Name `fargate-bg-alb-sg`, Description `ALB inbound HTTP`, VPC `fargate-bg-vpc`.
3. **Inbound rules → Add rule:** Type **HTTP**, Port `80`, Source **Anywhere-IPv4**
   `0.0.0.0/0`.
4. Leave outbound as default (all traffic). → **Create security group.**

### 2b. Tasks security group (only ALB → tasks on 8080)
1. **Create security group** again.
2. Name `fargate-bg-tasks-sg`, Description `Fargate tasks`, VPC `fargate-bg-vpc`.
3. **Inbound rules → Add rule:** Type **Custom TCP**, Port `8080`, Source
   **Custom** → in the search box pick the **`fargate-bg-alb-sg`** security group
   (source is the SG, not a CIDR — this is the key "ALB → tasks only" rule).
4. Leave outbound = all traffic (tasks need egress for ECR/CloudWatch).
5. **Create security group.**

---

## 3. ECR repository

1. Console → search **ECR** → **Elastic Container Registry**.
2. Left nav → **Repositories** → **Create repository**.
3. Visibility **Private**. Name `fargate-bg`.
4. **Tag immutability:** Disabled (we reuse tags like `v1` during iteration).
5. **Scan on push:** Enable.
6. **Create repository.**
7. (Optional, matches repo) Open the repo → **Lifecycle policy** → **Create rule**:
   expire **untagged** images older than 7 days.

---

## 4. Build and push the v1 image  — CLI / CloudShell (no console option)

Open **CloudShell** (top nav bar icon) or a local terminal with Docker + AWS CLI.

1. Get the push commands: in the ECR repo page click **View push commands** and
   copy them, or run:

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-south-1
REPO="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/fargate-bg"

# 1. Authenticate Docker to ECR
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

# 2. Build v1 (healthy). Run from the repo's app/ directory (Dockerfile + app.py).
docker build --platform linux/amd64 --build-arg APP_VERSION=v1 --build-arg HEALTHY=true -t $REPO:v1 .

# 3. Push
docker push $REPO:v1
```

> CloudShell has a small disk; if `docker build` complains about space, use a
> local machine or an EC2 box. Build v2/v3 later the same way (`HEALTHY=false`
> for v3).

Confirm in the ECR console: repo `fargate-bg` now shows image tag `v1`.

---

## 5. IAM roles

Three roles. Console → search **IAM** → **Roles**.

### 5a. Task execution role (ECR pull + logs)
1. **Create role** → Trusted entity **AWS service** → use case **Elastic Container
   Service** → **Elastic Container Service Task** → Next.
2. Attach policy: search and tick **`AmazonECSTaskExecutionRolePolicy`** → Next.
3. Name `fargate-bg-task-execution` → **Create role**.

### 5b. Task role (app runtime identity; empty)
1. **Create role** → **AWS service** → **Elastic Container Service Task** → Next.
2. Attach **no** policies (our app calls no AWS APIs) → Next.
3. Name `fargate-bg-task` → **Create role**.

### 5c. CodeDeploy service role (for ECS blue/green)
1. **Create role** → **AWS service** → use case **CodeDeploy** → pick
   **CodeDeploy - ECS** → Next.
2. The managed policy **`AWSCodeDeployRoleForECS`** is attached automatically →
   Next.
3. Name `fargate-bg-codedeploy` → **Create role**.

---

## 6. CloudWatch log group

1. Console → search **CloudWatch** → left nav **Logs → Log groups**.
2. **Create log group.** Name `/ecs/fargate-bg`. Retention `1 week (7 days)`.
   **Create.**

---

## 7. Target groups (blue + green)

Two target groups so CodeDeploy can shift between them. EC2 service → left nav
**Load Balancing → Target Groups**.

### 7a. Blue target group
1. **Create target group.**
2. Target type **IP addresses** (Fargate/awsvpc registers by IP — **not**
   "Instances").
3. Name `fargate-bg-blue`. Protocol **HTTP**, Port `8080`. VPC `fargate-bg-vpc`.
   Protocol version **HTTP1**.
4. **Health checks:** Protocol HTTP, Path `/health`.
5. Expand **Advanced health check settings**:
   - Port: **Traffic port**.
   - Healthy threshold: `2`
   - Unhealthy threshold: `2`
   - Timeout: `5` seconds
   - Interval: `10` seconds
   - Success codes: `200`
6. **Next.** On the "Register targets" page register **nothing** — ECS registers
   task IPs automatically. → **Create target group.**

### 7b. Green target group
Repeat 7a exactly, but name it `fargate-bg-green`. Same everything else.

---

## 8. Application Load Balancer + listener

EC2 service → left nav **Load Balancing → Load Balancers** → **Create load
balancer** → **Application Load Balancer**.

1. Name `fargate-bg-alb`. Scheme **Internet-facing**. IP type **IPv4**.
2. **Network mapping:** VPC `fargate-bg-vpc`; tick **both** AZs and select
   `fargate-bg-public-1` and `fargate-bg-public-2`.
3. **Security groups:** remove the default, add **`fargate-bg-alb-sg`**.
4. **Listeners and routing:** Protocol **HTTP**, Port `80`. Default action
   **Forward to** → `fargate-bg-blue`.
5. **Create load balancer.** Wait until State = **Active** (1–3 min).
6. Copy the ALB **DNS name** (e.g. `fargate-bg-alb-xxxx.ap-south-1.elb.amazonaws.com`)
   — this is the URL you'll test.

> The listener starts on blue. CodeDeploy will rewrite this default action during
> deployments — that's expected; don't edit it manually afterward.

---

## 9. ECS cluster

1. Console → search **ECS** → **Elastic Container Service**.
2. Left nav **Clusters** → **Create cluster**.
3. Name `fargate-bg-cluster`.
4. **Infrastructure:** ensure **AWS Fargate (serverless)** is ticked. Leave EC2
   unticked (Fargate only).
5. **Create.**

---

## 10. Task definition

ECS → left nav **Task definitions** → **Create new task definition**.

1. **Task definition family:** `fargate-bg-task`.
2. **Launch type:** AWS Fargate.
3. **OS/Architecture:** Linux/X86_64.
4. **Task size:** CPU `.25 vCPU` (256), Memory `.5 GB` (512).
5. **Task role:** `fargate-bg-task`.
   **Task execution role:** `fargate-bg-task-execution`.
6. **Container 1:**
   - Name: `fargate-bg-app`
   - Image URI: `<ACCOUNT>.dkr.ecr.ap-south-1.amazonaws.com/fargate-bg:v1`
   - Essential container: **Yes**.
   - **Port mappings:** Container port `8080`, Protocol TCP, App protocol HTTP.
   - **Environment variables:** add `PORT` = `8080`.
7. **Logging:** ensure **Use log collection** is on with **Amazon CloudWatch**.
   Expand and set it to the **existing** group `/ecs/fargate-bg` (the console
   otherwise auto-creates `/ecs/fargate-bg-task`; either is fine, just know which).
8. **Create.** You now have `fargate-bg-task:1`.

---

## 11. ECS service with the CODE_DEPLOY controller  ⭐ (the important one)

This step wires blue/green. In the console, creating a blue/green service **also
auto-creates a CodeDeploy application and deployment group for you** — a key
difference from Terraform (where we declared them explicitly).

1. Open cluster `fargate-bg-cluster` → **Services** tab → **Create**.
2. **Environment / Compute:** Launch type **Fargate**, Platform version
   **1.4.0** (or LATEST).
3. **Deployment configuration:**
   - Application type **Service**.
   - Family `fargate-bg-task`, Revision **1 (latest)**.
   - Service name `fargate-bg-svc`.
   - Desired tasks `1`.
4. **Deployment options → Deployment type:** select **Blue/green deployment
   (powered by AWS CodeDeploy)**. *(If you don't set this now you cannot switch
   an existing ECS-type service to CodeDeploy later — you'd recreate the service.)*
   - **Deployment configuration:** `CodeDeployDefault.ECSAllAtOnce`.
   - **CodeDeploy service role:** `fargate-bg-codedeploy`.
5. **Networking:**
   - VPC `fargate-bg-vpc`; Subnets: both public subnets.
   - Security group: **use existing** → `fargate-bg-tasks-sg` (remove any default).
   - **Public IP: Turned ON** (required, no NAT).
6. **Load balancing:**
   - Type **Application Load Balancer** → **Use existing** → `fargate-bg-alb`.
   - Container to load balance: `fargate-bg-app 8080:8080`.
   - **Listener:** use existing **HTTP:80**.
   - **Target group 1 (blue/production):** existing `fargate-bg-blue`.
   - **Target group 2 (green/test):** existing `fargate-bg-green`.
     *(Blue/green requires two target groups here — this is where the console
     needs both.)*
   - Health check grace period: **`0`** seconds. *(Critical — see the "Why
     rollback needs this" note below. The console defaults this too high.)*
7. **Create.** ECS launches one v1 task, registers it to blue, and it turns
   healthy within ~20s.

**Verify v1 is live:** browse `http://<ALB-DNS>/` → `{"version": "v1"}`, and
`http://<ALB-DNS>/health` → 200.

> **What just got created for you:** go to the **CodeDeploy** console →
> **Applications**. You'll see an app like `AppECS-fargate-bg-cluster-fargate-bg-svc`
> and inside it a deployment group `DgpECS-...`. That's what the console made
> from step 11.4. You'll edit it in step 13 and deploy from it in steps 14–15.

---

## 12. CloudWatch alarms — the piece that makes rollback actually work

**Why:** ECS blue/green does **not** fail a deployment just because ALB health
checks fail — as long as the container is *running*, CodeDeploy shifts traffic
and marks the deploy successful. A "runs but unhealthy" release (our v3, whose
`/health` returns 500) will otherwise go live. A CloudWatch alarm on unhealthy
hosts is what triggers the rollback. Create one alarm per target group.

For **each** of `fargate-bg-blue` and `fargate-bg-green`:

1. CloudWatch → left nav **Alarms → All alarms** → **Create alarm**.
2. **Select metric** → **ApplicationELB** → **Per AppELB, per TG Metrics**.
3. In the filter box find the row where **TargetGroup = `fargate-bg-blue`** (or
   green) **and LoadBalancer = `fargate-bg-alb`**, metric **`UnHealthyHostCount`**.
   Tick it → **Select metric**.
4. **Statistic:** Maximum. **Period:** 1 minute.
5. **Conditions:** Threshold type **Static**, **Greater/Equal** `>= 1`.
6. Expand **Additional configuration:**
   - Datapoints to alarm: `1 out of 1`.
   - **Missing data treatment:** **Treat missing data as good (not breaching)** —
     an idle target group publishes nothing and must not read as a problem.
7. **Next.** Notification: you can **Remove** the SNS notification (not needed).
   **Next.**
8. **Alarm name:** `fargate-bg-blue-unhealthy-hosts` (or `-green-...`). **Next →
   Create alarm.**

You end with two alarms. The one for the *idle* target group will sit in
`INSUFFICIENT_DATA`/OK — that's fine.

---

## 13. Attach the alarms to the CodeDeploy deployment group

1. CodeDeploy → **Applications** → open the auto-created app
   `AppECS-fargate-bg-cluster-fargate-bg-svc` → open its deployment group →
   **Edit**.
2. **Deployment settings** — confirm/adjust:
   - Deployment configuration `CodeDeployDefault.ECSAllAtOnce`.
   - **Traffic rerouting:** *Reroute traffic immediately*.
   - **Original revision termination:** wait **`3`** minutes before terminating
     the original task set. *(This is the bake window during which the alarm can
     trip and roll back. Too short and a bad deploy completes before the alarm
     fires.)*
3. **Alarms (CloudWatch alarms):** enable, then **Add alarm** and add **both**
   `fargate-bg-blue-unhealthy-hosts` and `fargate-bg-green-unhealthy-hosts`.
4. **Rollbacks:** tick **Roll back when a deployment fails** and **Roll back when
   alarm thresholds are met**.
5. **Save changes.**

---

## 14. Deploy v2 (prove blue/green works)

First push the v2 image, then register a task-def revision, then deploy.

### 14a. Build + push v2  [CLI/CloudShell]
```bash
docker build --platform linux/amd64 --build-arg APP_VERSION=v2 --build-arg HEALTHY=true -t $REPO:v2 .
docker push $REPO:v2
```

### 14b. New task-definition revision pointing at v2
1. ECS → **Task definitions** → `fargate-bg-task` → select the latest revision →
   **Create new revision**.
2. Under Container 1, change the **Image URI** tag from `:v1` to `:v2`.
3. Leave everything else. **Create.** You now have `fargate-bg-task:2`.

### 14c. Create the CodeDeploy deployment
1. CodeDeploy → your application → deployment group → **Create deployment**.
2. **Revision type:** *Use AppSpec editor* (or "enter inline"). Choose **JSON**
   and paste — **replace the task-definition ARN** with your `:2` revision ARN
   (copy it from the task-definition page):

```json
{
  "version": 0.0,
  "Resources": [
    {
      "TargetService": {
        "Type": "AWS::ECS::Service",
        "Properties": {
          "TaskDefinition": "arn:aws:ecs:ap-south-1:<ACCOUNT>:task-definition/fargate-bg-task:2",
          "LoadBalancerInfo": { "ContainerName": "fargate-bg-app", "ContainerPort": 8080 }
        }
      }
    }
  ]
}
```
3. **Create deployment.**
4. Watch the deployment page: it shows **Step 1 (deploy replacement)** →
   **reroute traffic** → **original stopped**. Traffic flips to green when the
   v2 task is healthy.
5. **Verify:** `http://<ALB-DNS>/` → `{"version": "v2"}`, `/health` → 200.

---

## 15. Deploy v3 (broken) → automatic rollback

### 15a. Build + push v3 (broken health)  [CLI/CloudShell]
```bash
docker build --platform linux/amd64 --build-arg APP_VERSION=v3 --build-arg HEALTHY=false -t $REPO:v3 .
docker push $REPO:v3
```

### 15b. New task-def revision for v3
ECS → Task definitions → `fargate-bg-task` → **Create new revision** → set image
tag to `:v3` → **Create** (`fargate-bg-task:3`).

### 15c. Create the deployment (same as 14c) with the `:3` ARN
1. CodeDeploy → deployment group → **Create deployment** → paste the same AppSpec
   JSON but with `.../fargate-bg-task:3`. **Create deployment.**
2. Watch it: CodeDeploy launches the v3 task on the idle target group, it fails
   `/health` (500), the unhealthy-hosts alarm trips within a minute or two, and
   the deployment status becomes **Stopped** with reason **`ALARM_ACTIVE`**.
   Traffic is rerouted back to v2.
3. **Verify rollback:** `http://<ALB-DNS>/` → still `{"version": "v2"}`,
   `/health` → 200. ✅

---

## 16. Evidence to capture

- CodeDeploy → the v3 deployment → screenshot the **Status: Stopped** and the
  **Rollback / alarm** details (`ALARM_ACTIVE`).
- CloudWatch → Alarms → screenshot `fargate-bg-blue-unhealthy-hosts` (or green)
  in **In alarm** state during the v3 deploy.
- ECS → service → **Deployments/Tasks** showing the running task back on the v2
  revision.
- Browser screenshots of `GET /` returning `v2` before and after the failed v3.
- CLI equivalent for the write-up:
  `aws deploy get-deployment --deployment-id <id> --region ap-south-1`.

---

## 17. Teardown (do within 24h — reverse order)

1. **CodeDeploy:** delete the deployment group, then the application.
2. **ECS:** update the service → desired tasks `0` → then **Delete service**.
   Then delete the cluster. Deregister task-definition revisions (optional).
3. **CloudWatch:** delete the two alarms and the `/ecs/fargate-bg` log group.
4. **ALB:** delete the load balancer, then the two target groups.
5. **ECR:** delete the `fargate-bg` repository (delete images first, or use force).
6. **IAM:** delete the three roles.
7. **VPC:** delete subnets → detach + delete IGW → delete route table → delete
   security groups (`tasks-sg` before `alb-sg` — the tasks SG references the ALB
   SG) → delete the VPC.

> Deleting in the wrong order gives "dependency" errors — that's the console
> telling you something still references the resource. Delete the dependent
> thing first.

---

## Console vs Terraform — the differences worth remembering

| Aspect | Terraform (this repo) | Console |
|--------|----------------------|---------|
| CodeDeploy app + deployment group | Declared explicitly (`codedeploy.tf`) | **Auto-created** when you pick blue/green at service creation |
| Task-def revision per deploy | `deploy.sh` registers it via CLI | You click **Create new revision** each time |
| AppSpec | Generated by `deploy.sh` | You paste JSON into the deployment form |
| Health-check grace period | `0` in code | You must remember to set it to `0` (console defaults higher) |
| Rollback alarm | `alarms.tf` + `alarm_configuration` | Create alarms, then **Edit deployment group** to attach |
| Repeatability | `terraform apply` recreates identically | Manual clicks, easy to miss a field |

**The single most important console gotcha:** blue/green + rollback is *not*
automatic from health checks. You must (a) set the grace period to `0`, and
(b) create the unhealthy-host CloudWatch alarms and attach them to the
deployment group. Without those, a broken-but-running release goes live and
never rolls back — exactly the bug this project hit and fixed.
