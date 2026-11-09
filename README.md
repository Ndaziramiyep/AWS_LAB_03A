# Onward Logistics: Sales Day Demand

Highly available, auto-scaling, private-compute order system behind a single public Application Load Balancer.
It is provisioned entirely by **CloudFormation** and deployed by **CloudFormation Git sync**.

- Student: **Patrick Ndaziramiye**
- Lab: *Handling Sales Day Demand for the Onward Logistics Order System*
- Region: `eu-west-1` (change it if the Client Profile says otherwise)

## Architecture at a glance
```
Internet -> IGW -> ALB (public subnets, AZ-a + AZ-b, SG: 80 from 0.0.0.0/0)
                    -> EC2 Auto Scaling Group (private subnets, SG: 8080 from ALB SG only, min 2 / max 6)
                         -> Regional NAT Gateway -> IGW   (outbound only: updates, git, pip, SSM)
Scaling: target tracking on ASGAverageCPUUtilization = 50%
Access:  SSM Session Manager only (no key pair, no port 22)
```
Full diagram: [docs/architecture.md](docs/architecture.md). Cost model: [docs/cost-model.md](docs/cost-model.md).
Discovery report draft: [docs/discovery-report.md](docs/discovery-report.md).

## Repository layout
```
deployment-file.yaml        Git sync deployment file (template path, parameters, stack tags)
infra/template.yaml         Main CloudFormation template (network, SGs, IAM, ALB, ASG, scaling)
bootstrap/gitsync-role.yaml One-time template: Git sync role + CloudFormation execution role
app/app.py                  Flask app: UI, /orders, /health, /whoami, protected /burn
app/templates/index.html    Page showing name, lab and the serving instance and AZ
scripts/demo.sh             Live-review proof commands (balance, scale, kill, AZ loss, private, egress)
docs/                       Architecture, cost model, discovery report
```

## How the app gets onto each server
The launch template's UserData runs on **every** new instance (first boot and every scale-out). It:
1. runs `dnf update` and installs git and Python through the Regional NAT;
2. runs `git clone --branch $AppRepoRef` on this repository, then installs `app/requirements.txt` into a venv;
3. writes `/etc/onward.env` (student name, lab name, secret ID, region);
4. starts the app as a systemd service (`gunicorn` on port 8080) and waits for `/health`.

## Deploying

### 0. Prerequisites
- AWS CLI v2 configured for the target account and region, and this repository pushed to GitHub (public, so instances can clone it).
- Tag the app release that instances will deploy:
  ```bash
  git tag v1.0.0 && git push origin v1.0.0
  ```

### 1. Bootstrap (one time)
1. **CodeConnections**: in the console, go to *Developer Tools → Settings → Connections → Create connection → GitHub*
   and complete the OAuth handshake. The status must be **Available**. This is the only console step,
   because the authorisation handshake cannot be done in code.
2. **Git sync roles** (managed policies only):
   ```bash
   aws cloudformation deploy \
     --stack-name onward-logistics-lab-bootstrap \
     --template-file bootstrap/gitsync-role.yaml \
     --capabilities CAPABILITY_NAMED_IAM \
     --tags Project=onward-logistics Environment=lab Owner=patrick.ndaziramiye CostCenter=training
   ```

### 2. Create the stack with Git sync
*CloudFormation → Create stack → **Sync from Git***
- Repository: `Ndaziramiyep/AWS_LAB_03A`, branch `main`, deployment file path `deployment-file.yaml`
- IAM role: `onward-logistics-lab-gitsync-role`
- Stack name: `onward-logistics-lab`
- Optional (Permissions step): stack service role `onward-logistics-lab-cfn-exec-role`

From now on every `git push` to `main` updates the stack. Check the stack's *Git sync* tab for status
(it must show **Succeeded**).

### Alternative: plain CLI deploy (fallback and quick tests)
```bash
aws cloudformation deploy --stack-name onward-logistics-lab --template-file infra/template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides StudentFullName="Patrick Ndaziramiye" \
     AppRepoUrl=https://github.com/Ndaziramiyep/AWS_LAB_03A.git AppRepoRef=v1.0.0 \
  --tags Project=onward-logistics Environment=lab Owner=patrick.ndaziramiye CostCenter=training
```

### Validate before pushing
```bash
pip install cfn-lint
cfn-lint infra/template.yaml bootstrap/gitsync-role.yaml
grep -n "Policies:" infra/template.yaml bootstrap/gitsync-role.yaml   # must print nothing (no inline policies)
```

## Live review: proof script
```bash
export STACK_NAME=onward-logistics-lab
scripts/demo.sh outputs     # 1. single public address
scripts/demo.sh balance     # 2. requests shared across instances and AZs
scripts/demo.sh token       #    load token for the web "Generate load" button (never commit it)
scripts/demo.sh load        # 3. stress-ng on all instances through SSM Run Command
scripts/demo.sh scale       # 3. desired capacity rises, then falls ~15 min after the load ends
scripts/demo.sh kill-one    # 4. instance replaced automatically
scripts/demo.sh kill-az     # 5. survives the loss of an AZ
scripts/demo.sh private     # 6a. no public IPs, App SG only allows the ALB SG
scripts/demo.sh egress      # 6b. private route to NAT and a successful outbound curl/dnf
scripts/demo.sh health      #    target group health view
```
8. **Rebuild from the repo:** delete the stack, then recreate it with *Sync from Git* (or the CLI deploy above).

## Standards
- Naming: `${ProjectName}-${Environment}-<resource>`, for example `onward-logistics-lab-alb`.
- Mandatory tags on every resource: `Project`, `Environment`, `Owner`, `CostCenter` (plus `ManagedBy` at stack level).
  Replace them with the Client Profile's values if they differ.
- No inline IAM policies: only `ManagedPolicyArns` and `AWS::IAM::ManagedPolicy`.
- The load-test token lives only in Secrets Manager and is never committed.

## Teardown
```bash
aws cloudformation delete-stack --stack-name onward-logistics-lab
aws cloudformation delete-stack --stack-name onward-logistics-lab-bootstrap   # only after the app stack is gone
```
