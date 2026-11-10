#!/usr/bin/env bash
# One-shot AWS CloudShell runner for the Onward Logistics sales day lab.
# Upload this single file to CloudShell, then:
#   chmod +x cloudshell-setup.sh
#   ./cloudshell-setup.sh                 # everything: preflight, validate, bootstrap, deploy, verify
#   ./cloudshell-setup.sh <step>          # one step only
#
# Steps:
#   all        preflight + validate + bootstrap + deploy + verify (default)
#   preflight  check tools, credentials, region, repo and the pinned app tag
#   validate   cfn-lint + validate-template + "no inline IAM policies" check
#   bootstrap  deploy the Git sync role stack (bootstrap/gitsync-role.yaml)
#   deploy     create/update the app stack (MODE=gitsync or MODE=cli, see below)
#   verify     wait for healthy targets, then run the read-only proofs from demo.sh
#   demo <c>   run scripts/demo.sh <c> (outputs|balance|health|load|stop-load|scale|kill-one|kill-az|private|egress|token)
#   status     stack status, Git sync status, outputs and target health
#   teardown   remove sync config, app stack, repository link and bootstrap stack
#
# Settings (environment variables, all optional):
#   MODE=gitsync   create the stack with CloudFormation Git sync (the lab requirement, default)
#   MODE=cli       plain "aws cloudformation deploy" fallback, no GitHub connection needed
#   REGION=eu-west-1        target region
#   APP_REF=v1.0.0          Git tag/branch the servers deploy (MODE=cli only; Git sync reads deployment-file.yaml)
#   DELETE_CONNECTION=yes   teardown also deletes the GitHub connection
#
# Example:  MODE=cli ./cloudshell-setup.sh
#           ./cloudshell-setup.sh demo load
set -euo pipefail                                          # stop on errors and unset variables

# ---------------------------------------------------------------- settings
GITHUB_OWNER="${GITHUB_OWNER:-Ndaziramiyep}"               # GitHub account that owns the repo
GITHUB_REPO="${GITHUB_REPO:-AWS_LAB_03A}"                  # repository name
REPO_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git"
BRANCH="${BRANCH:-main}"                                   # branch Git sync watches
MODE="${MODE:-gitsync}"                                    # gitsync | cli
REGION="${REGION:-eu-west-1}"                              # lab region
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"   # demo.sh and the CLI use the same region
export AWS_PAGER=""                                        # never open a pager in CloudShell

PROJECT="onward-logistics"                                 # naming convention: <project>-<env>-<resource>
ENVIRONMENT="lab"
OWNER="patrick.ndaziramiye"
COST_CENTER="training"
STUDENT="Patrick Ndaziramiye"

STACK="${STACK_NAME:-${PROJECT}-${ENVIRONMENT}}"           # app stack: onward-logistics-lab
BOOT_STACK="${STACK}-bootstrap"                            # bootstrap stack
SYNC_ROLE_NAME="${PROJECT}-${ENVIRONMENT}-gitsync-role"    # created by the bootstrap stack
CONN_NAME="${PROJECT}-${ENVIRONMENT}-github"               # CodeConnections connection name (max 32 chars)
TAGS=(Project="$PROJECT" Environment="$ENVIRONMENT" Owner="$OWNER" CostCenter="$COST_CENTER")

# ---------------------------------------------------------------- helpers
c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'; c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'; c_off=$'\e[0m'
step() { echo; echo "${c_blue}==> $*${c_off}"; }
ok()   { echo "${c_green}  ok${c_off} $*"; }
warn() { echo "${c_yellow}  warning:${c_off} $*"; }
die()  { echo "${c_red}  error:${c_off} $*" >&2; exit 1; }

# Find the repository: use the one this script sits in, else clone/update it in $HOME.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/../infra/template.yaml" ]]; then
  REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  REPO_DIR="${REPO_DIR:-$HOME/$GITHUB_REPO}"
fi

sync_repo() {
  if [[ "$REPO_DIR" == "$HOME/$GITHUB_REPO" && -d "$REPO_DIR/.git" ]]; then
    # Script-managed clone: always match GitHub exactly (discards any edits made in CloudShell).
    git -C "$REPO_DIR" fetch --quiet origin "$BRANCH" \
      && git -C "$REPO_DIR" reset --quiet --hard "origin/$BRANCH" \
      || warn "could not update $REPO_DIR from GitHub, using it as is"
  elif [[ ! -f "$REPO_DIR/infra/template.yaml" ]]; then
    git clone --quiet --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
  fi
  [[ -f "$REPO_DIR/infra/template.yaml" ]] || die "infra/template.yaml not found in $REPO_DIR"
}

# demo <check>: run scripts/demo.sh with bash (no chmod, so the clone stays clean).
demo() {
  [[ "$(stack_status "$STACK")" == NONE ]] && die "stack $STACK does not exist yet, run: $0 deploy"
  STACK_NAME="$STACK" bash "$REPO_DIR/scripts/demo.sh" "$1" "$STACK"
}

# deployment_value <Key>: read a parameter value from deployment-file.yaml.
deployment_value() {
  sed -nE "s/^[[:space:]]+$1:[[:space:]]*\"?([^\"#]*[^\"#[:space:]])\"?.*/\1/p" "$REPO_DIR/deployment-file.yaml" | head -1
}

# deployment_section parameters|tags: print "Key=Value" for each entry of that block in deployment-file.yaml.
deployment_section() {
  awk -v sec="$1" '
    /^[^[:space:]#]/ { insec = ($0 ~ "^" sec ":"); next }   # top-level key starts a new block
    insec && /^[[:space:]]+[A-Za-z0-9]+:/ {
      line = $0
      match(line, /^[[:space:]]+[A-Za-z0-9]+:/)
      key = substr(line, RSTART, RLENGTH); gsub(/[[:space:]:]/, "", key)
      val = substr(line, RSTART + RLENGTH)
      sub(/[[:space:]]+#.*$/, "", val); sub(/^[[:space:]]+/, "", val); sub(/[[:space:]]+$/, "", val)
      gsub(/^"|"$/, "", val)
      print key "=" val
    }' "$REPO_DIR/deployment-file.yaml"
}

# ref_exists <ref>: true if the branch or tag exists on GitHub (servers clone it at boot).
ref_exists() {
  git ls-remote --exit-code "$REPO_URL" "refs/tags/$1" "refs/heads/$1" >/dev/null 2>&1
}

stack_status() {
  aws cloudformation describe-stacks --stack-name "$1" --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "NONE"
}

out() {
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

sync_config_exists() {
  aws codeconnections get-sync-configuration --sync-type CFN_STACK_SYNC --resource-name "$STACK" >/dev/null 2>&1
}

# Delete a stack left in a state that cannot be updated (failed first create).
clear_failed_stack() {
  local s; s="$(stack_status "$1")"
  if [[ "$s" == "ROLLBACK_COMPLETE" || "$s" == "ROLLBACK_FAILED" || "$s" == "CREATE_FAILED" ]]; then
    warn "$1 is in $s, deleting it before retrying"
    aws cloudformation delete-stack --stack-name "$1"
    aws cloudformation wait stack-delete-complete --stack-name "$1"
  fi
}

# wait_stack <name> <minutes>: poll until the stack settles, print each status change.
wait_stack() {
  local name="$1" limit=$(( $2 * 6 )) last="" s i
  for (( i = 0; i < limit; i++ )); do
    s="$(stack_status "$name")"
    [[ "$s" != "$last" ]] && echo "  $(date +%H:%M:%S) $name: $s" && last="$s"
    case "$s" in
      CREATE_COMPLETE|UPDATE_COMPLETE|IMPORT_COMPLETE) return 0 ;;
      *ROLLBACK_COMPLETE|*FAILED)
        aws cloudformation describe-stack-events --stack-name "$name" --max-items 40 \
          --query "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatusReason]" --output table || true
        die "$name ended in $s" ;;
    esac
    sleep 10
  done
  die "timed out waiting for $name"
}

# ---------------------------------------------------------------- steps
do_preflight() {
  step "Preflight"
  for t in aws git curl python3; do command -v "$t" >/dev/null || die "$t is not installed"; done
  ok "tools: aws $(aws --version 2>&1 | cut -d' ' -f1 | cut -d/ -f2), git, curl, python3"

  local ident; ident="$(aws sts get-caller-identity --query "[Account,Arn]" --output text)" || die "no AWS credentials"
  ok "identity: $ident"
  ok "region: $REGION   mode: $MODE   stack: $STACK"

  aws ec2 describe-availability-zones --query "length(AvailabilityZones[?State=='available'])" --output text \
    | { read -r n; [[ "$n" -ge 2 ]] || die "region $REGION has fewer than 2 AZs"; ok "$n availability zones"; }

  sync_repo
  ok "repository: $REPO_DIR ($(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo 'no git'))"

  # The servers run "git clone --branch <AppRepoRef>" at boot, so that ref must exist on GitHub.
  local ref; ref="$(deployment_value AppRepoRef)"
  if [[ "$MODE" == "gitsync" ]]; then
    ref_exists "$ref" || die "AppRepoRef '$ref' (deployment-file.yaml) is not on GitHub. On your laptop run:
         git tag $ref && git push origin $ref
       then re-run this script (or change AppRepoRef in deployment-file.yaml and push)."
    ok "app ref '$ref' exists on GitHub"
  else
    APP_REF="${APP_REF:-$ref}"
    if ! ref_exists "$APP_REF"; then
      warn "ref '$APP_REF' is not on GitHub, servers will deploy branch '$BRANCH' instead"
      APP_REF="$BRANCH"
    fi
    ok "app ref: $APP_REF"
  fi
}

do_validate() {
  step "Validate templates"
  cd "$REPO_DIR"
  if ! command -v cfn-lint >/dev/null; then
    pip3 install --user --quiet --disable-pip-version-check cfn-lint >/dev/null 2>&1 || warn "could not install cfn-lint"
    export PATH="$HOME/.local/bin:$PATH"
  fi
  if command -v cfn-lint >/dev/null; then
    local rc=0; cfn-lint infra/template.yaml bootstrap/gitsync-role.yaml || rc=$?
    (( rc & 2 )) && die "cfn-lint found errors"            # bit 2 = error, 4 = warning, 8 = info
    ok "cfn-lint passed (exit $rc)"
  fi
  for f in infra/template.yaml bootstrap/gitsync-role.yaml; do
    aws cloudformation validate-template --template-body "file://$f" >/dev/null
    ok "validate-template: $f"
  done
  if grep -nE '^[[:space:]]+Policies:' infra/template.yaml bootstrap/gitsync-role.yaml; then
    die "inline IAM policies found (only managed policies are allowed)"
  fi
  ok "no inline IAM policies"
}

do_bootstrap() {
  step "Bootstrap: Git sync role and CloudFormation execution role ($BOOT_STACK)"
  clear_failed_stack "$BOOT_STACK"
  aws cloudformation deploy --stack-name "$BOOT_STACK" \
    --template-file "$REPO_DIR/bootstrap/gitsync-role.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides ProjectName="$PROJECT" Environment="$ENVIRONMENT" Owner="$OWNER" CostCenter="$COST_CENTER" \
    --tags "${TAGS[@]}" --no-fail-on-empty-changeset
  ok "$BOOT_STACK: $(stack_status "$BOOT_STACK")"
}

# GitHub connection: created here, but the OAuth handshake must be finished once in the console.
ensure_connection() {
  CONN_ARN="$(aws codeconnections list-connections --provider-type-filter GitHub \
    --query "Connections[?ConnectionName=='$CONN_NAME'].ConnectionArn | [0]" --output text)"
  if [[ -z "$CONN_ARN" || "$CONN_ARN" == "None" ]]; then
    CONN_ARN="$(aws codeconnections create-connection --provider-type GitHub --connection-name "$CONN_NAME" \
      --tags Key=Project,Value="$PROJECT" Key=Environment,Value="$ENVIRONMENT" Key=Owner,Value="$OWNER" Key=CostCenter,Value="$COST_CENTER" \
      --query ConnectionArn --output text)"
    ok "created connection $CONN_NAME"
  fi
  local s; s="$(aws codeconnections get-connection --connection-arn "$CONN_ARN" --query Connection.ConnectionStatus --output text)"
  if [[ "$s" != "AVAILABLE" ]]; then
    echo
    echo "${c_yellow}  ACTION NEEDED (one time only): authorise the GitHub connection in the console.${c_off}"
    echo "  1. Open https://${REGION}.console.aws.amazon.com/codesuite/settings/connections?region=${REGION}"
    echo "  2. Select '$CONN_NAME' (status Pending) -> Update pending connection"
    echo "  3. Install/choose the AWS Connector for GitHub app with access to ${GITHUB_OWNER}/${GITHUB_REPO} -> Connect"
    echo "  Waiting for the status to become AVAILABLE (up to 15 min)..."
    for (( i = 0; i < 90; i++ )); do
      sleep 10
      s="$(aws codeconnections get-connection --connection-arn "$CONN_ARN" --query Connection.ConnectionStatus --output text)"
      [[ "$s" == "AVAILABLE" ]] && break
    done
    [[ "$s" == "AVAILABLE" ]] || die "connection is still $s; finish the handshake and re-run: $0 deploy"
  fi
  ok "connection AVAILABLE: $CONN_ARN"
}

ensure_repo_link() {
  LINK_ID="$(aws codeconnections list-repository-links \
    --query "RepositoryLinks[?OwnerId=='$GITHUB_OWNER' && RepositoryName=='$GITHUB_REPO'].RepositoryLinkId | [0]" --output text)"
  if [[ -z "$LINK_ID" || "$LINK_ID" == "None" ]]; then
    LINK_ID="$(aws codeconnections create-repository-link --connection-arn "$CONN_ARN" \
      --owner-id "$GITHUB_OWNER" --repository-name "$GITHUB_REPO" \
      --query RepositoryLinkInfo.RepositoryLinkId --output text)"
    ok "created repository link"
  fi
  ok "repository link: $LINK_ID"
}

deploy_gitsync() {
  ensure_connection
  ensure_repo_link
  local role_arn; role_arn="$(aws iam get-role --role-name "$SYNC_ROLE_NAME" --query Role.Arn --output text)" \
    || die "role $SYNC_ROLE_NAME not found, run: $0 bootstrap"
  clear_failed_stack "$STACK"

  # Git sync only updates an existing stack, so create it once from the same
  # deployment-file.yaml (template, parameters, tags). Git sync owns it afterwards.
  if [[ "$(stack_status "$STACK")" == NONE ]]; then
    if sync_config_exists; then                            # left over from a failed first sync
      aws codeconnections delete-sync-configuration --sync-type CFN_STACK_SYNC --resource-name "$STACK"
      ok "removed stale Git sync configuration"
    fi
    local params tags
    mapfile -t params < <(deployment_section parameters)
    mapfile -t tags < <(deployment_section tags)
    echo "  Creating $STACK from deployment-file.yaml (NAT + ALB + instances take ~10 min)..."
    aws cloudformation deploy --stack-name "$STACK" \
      --template-file "$REPO_DIR/$(sed -nE 's/^template-file-path:[[:space:]]*([^[:space:]#]+).*/\1/p' "$REPO_DIR/deployment-file.yaml")" \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides "${params[@]}" --tags "${tags[@]}" --no-fail-on-empty-changeset
    ok "$STACK: $(stack_status "$STACK")"
  fi

  if sync_config_exists; then
    ok "Git sync already configured for $STACK (every push to $BRANCH redeploys it)"
  else
    aws codeconnections create-sync-configuration --sync-type CFN_STACK_SYNC \
      --resource-name "$STACK" --branch "$BRANCH" --config-file deployment-file.yaml \
      --repository-link-id "$LINK_ID" --role-arn "$role_arn" >/dev/null
    ok "Git sync configured: $GITHUB_OWNER/$GITHUB_REPO@$BRANCH -> deployment-file.yaml -> $STACK"
  fi

  # Watch the first sync (it should find nothing to change). Up to 20 min if it does update the stack.
  echo "  Waiting for the first Git sync..."
  local s="" st="" last="" i
  for (( i = 0; i < 120; i++ )); do
    s="$(aws codeconnections get-resource-sync-status --sync-type CFN_STACK_SYNC --resource-name "$STACK" \
      --query "LatestSync.Status" --output text 2>/dev/null || echo PENDING)"
    st="$(stack_status "$STACK")"
    [[ "$s/$st" != "$last" ]] && echo "  $(date +%H:%M:%S) sync: $s   stack: $st" && last="$s/$st"
    if [[ "$s" == "FAILED" ]]; then
      aws codeconnections get-resource-sync-status --sync-type CFN_STACK_SYNC --resource-name "$STACK" \
        --query "LatestSync.Events[].[Time,Event]" --output table || true
      die "Git sync failed (the stack itself is fine; fix the cause, push, and check: $0 status)"
    fi
    [[ "$s" == "SUCCEEDED" && "$st" == *_COMPLETE && "$st" != *ROLLBACK* ]] && break
    (( i >= 30 )) && [[ "$s" == PENDING || "$s" == None ]] && { warn "no sync attempt yet; the next push to $BRANCH will trigger one"; break; }
    sleep 10
  done
  wait_stack "$STACK" 5
}

deploy_cli() {
  sync_config_exists && die "$STACK is managed by Git sync; use MODE=gitsync, or run teardown first"
  clear_failed_stack "$STACK"
  aws cloudformation deploy --stack-name "$STACK" \
    --template-file "$REPO_DIR/infra/template.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides ProjectName="$PROJECT" Environment="$ENVIRONMENT" Owner="$OWNER" CostCenter="$COST_CENTER" \
      StudentFullName="$STUDENT" AppRepoUrl="$REPO_URL" AppRepoRef="$APP_REF" \
      InstanceType=t3.micro CpuCredits=unlimited MinSize=2 MaxSize=6 TargetCpu=50 \
    --tags "${TAGS[@]}" ManagedBy=cloudformation-cli --no-fail-on-empty-changeset
}

do_deploy() {
  step "Deploy app stack $STACK (MODE=$MODE)"
  case "$MODE" in
    gitsync) deploy_gitsync ;;
    cli)     deploy_cli ;;
    *)       die "MODE must be gitsync or cli" ;;
  esac
  ok "$STACK: $(stack_status "$STACK")"
}

do_verify() {
  step "Verify: waiting for healthy targets (UserData installs the app, ~3-5 min)"
  [[ "$(stack_status "$STACK")" == *_COMPLETE ]] || die "stack $STACK is not deployed"
  local tg alb healthy=0 i
  tg="$(out TargetGroupArn)"; alb="$(out AlbDnsName)"
  for (( i = 0; i < 60; i++ )); do
    healthy="$(aws elbv2 describe-target-health --target-group-arn "$tg" \
      --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)"
    echo "  $(date +%H:%M:%S) healthy targets: $healthy"
    [[ "$healthy" -ge 2 ]] && break
    sleep 15
  done
  [[ "$healthy" -ge 2 ]] || warn "fewer than 2 healthy targets; check /var/log/onward-userdata.log via Session Manager"

  curl -fsS --max-time 10 "$alb/health" >/dev/null && ok "$alb/health responds" || warn "$alb/health did not respond yet"

  for c in outputs balance health private egress; do
    step "Proof: demo.sh $c"
    demo "$c" || warn "demo.sh $c failed"
  done

  step "Done"
  echo "  Open the app:        $alb"
  echo "  Load token:          $0 demo token      (paste it into the 'Generate load' button, never commit it)"
  echo "  Scale-out demo:      $0 demo load   then  $0 demo scale   (repeat every minute)"
  echo "  Self-healing demo:   $0 demo kill-one   /   $0 demo kill-az"
  echo "  Clean up afterwards: $0 teardown"
}

do_status() {
  step "Status"
  echo "  $BOOT_STACK: $(stack_status "$BOOT_STACK")"
  echo "  $STACK: $(stack_status "$STACK")"
  if sync_config_exists; then
    aws codeconnections get-resource-sync-status --sync-type CFN_STACK_SYNC --resource-name "$STACK" \
      --query "{latest:LatestSync.Status,lastSuccess:LatestSuccessfulSync.Status,commit:LatestSync.Target.Revision.Sha}" --output table || true
  fi
  if [[ "$(stack_status "$STACK")" != NONE ]]; then
    demo outputs
    demo health
  fi
}

do_teardown() {
  step "Teardown (region $REGION)"
  if sync_config_exists; then
    aws codeconnections delete-sync-configuration --sync-type CFN_STACK_SYNC --resource-name "$STACK"
    ok "deleted Git sync configuration (pushes no longer redeploy)"
  fi
  if [[ "$(stack_status "$STACK")" != NONE ]]; then
    echo "  deleting $STACK (NAT gateway and ALB take a few minutes)..."
    aws cloudformation delete-stack --stack-name "$STACK"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK"
    ok "deleted $STACK"
  fi
  local link; link="$(aws codeconnections list-repository-links \
    --query "RepositoryLinks[?OwnerId=='$GITHUB_OWNER' && RepositoryName=='$GITHUB_REPO'].RepositoryLinkId | [0]" --output text 2>/dev/null || true)"
  if [[ -n "$link" && "$link" != "None" ]]; then
    aws codeconnections delete-repository-link --repository-link-id "$link" && ok "deleted repository link" \
      || warn "repository link still in use, left in place"
  fi
  if [[ "$(stack_status "$BOOT_STACK")" != NONE ]]; then
    aws cloudformation delete-stack --stack-name "$BOOT_STACK"
    aws cloudformation wait stack-delete-complete --stack-name "$BOOT_STACK"
    ok "deleted $BOOT_STACK"
  fi
  if [[ "${DELETE_CONNECTION:-no}" == "yes" ]]; then
    local arn; arn="$(aws codeconnections list-connections --provider-type-filter GitHub \
      --query "Connections[?ConnectionName=='$CONN_NAME'].ConnectionArn | [0]" --output text)"
    if [[ -n "$arn" && "$arn" != "None" ]]; then
      aws codeconnections delete-connection --connection-arn "$arn"; ok "deleted connection"
    fi
  fi
  ok "teardown complete"
}

# ---------------------------------------------------------------- main
CMD="${1:-all}"
case "$CMD" in
  all)       do_preflight; do_validate; do_bootstrap; do_deploy; do_verify ;;
  preflight) do_preflight ;;
  validate)  sync_repo; do_validate ;;
  bootstrap) sync_repo; do_bootstrap ;;
  deploy)    do_preflight; do_deploy ;;
  verify)    sync_repo; do_verify ;;
  status)    sync_repo; do_status ;;
  demo)      sync_repo; demo "${2:-outputs}" ;;
  teardown)
    read -r -p "Delete $STACK, its Git sync config and $BOOT_STACK in $REGION? [y/N] " a
    if [[ "$a" == [yY]* ]]; then do_teardown; else echo "cancelled"; fi ;;
  -h|--help|help) sed -n '2,27p' "$0" ;;
  *) sed -n '2,27p' "$0"; exit 1 ;;
esac
