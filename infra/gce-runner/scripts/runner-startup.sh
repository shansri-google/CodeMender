#!/usr/bin/env bash
# Rendered by Terraform templatefile(). Dollar-brace placeholders are Terraform
# vars; bash variables deliberately use $VAR without braces to avoid clashing.
#
# Lifecycle of one VM:
#   boot -> install deps -> fetch GitHub token from Secret Manager (via the
#   VM's attached SA) -> mint a 1h registration token -> register as an
#   EPHEMERAL runner -> run exactly one job -> delete self -> MIG recreates.
set -euo pipefail
exec > >(tee -a /var/log/codemender-runner.log | logger -t codemender-runner) 2>&1

GITHUB_REPO="${github_repo}"
PROJECT_ID="${project_id}"
SECRET_ID="${github_pat_secret_id}"
RUNNER_LABELS="${runner_labels}"
RUNNER_HOME=/opt/actions-runner

md() { curl -sf -H "Metadata-Flavor: Google" "http://169.254.169.254/computeMetadata/v1/$1"; }
INSTANCE_NAME=$(md instance/name)
ZONE=$(basename "$(md instance/zone)")

echo "==> [$INSTANCE_NAME/$ZONE] bootstrapping ephemeral runner for $GITHUB_REPO"

# 1. OS dependencies the workflow needs (git for checkout, jq for the fix
#    loop, python for pytest). Only step that needs tcp/80 (apt mirrors).
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl jq git tar python3 python3-pip python3-venv

# 2. Unprivileged user. actions/runner refuses to run as root by default.
id -u runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner

# 3. Pull the GitHub token from Secret Manager using the attached SA.
#    Goes through the PSC endpoint, never the public internet.
ACCESS_TOKEN=$(md "instance/service-accounts/default/token" | jq -r .access_token)
GH_PAT=$(curl -sf \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://secretmanager.googleapis.com/v1/projects/$PROJECT_ID/secrets/$SECRET_ID/versions/latest:access" \
  | jq -r .payload.data | base64 -d)
unset ACCESS_TOKEN

# 4. Exchange it for a short-lived (1h) registration token, then drop the PAT.
REG_TOKEN=$(curl -sf -X POST \
  -H "Authorization: Bearer $GH_PAT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GITHUB_REPO/actions/runners/registration-token" \
  | jq -r .token)
unset GH_PAT
[ -n "$REG_TOKEN" ] && [ "$REG_TOKEN" != "null" ] || { echo "!! failed to obtain registration token"; exit 1; }

# 5. Install the latest actions/runner release.
RUNNER_VERSION=$(curl -sf https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name | ltrimstr("v")')
mkdir -p "$RUNNER_HOME" && cd "$RUNNER_HOME"
curl -sfL -o runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz"
tar xzf runner.tar.gz && rm -f runner.tar.gz
./bin/installdependencies.sh
chown -R runner:runner "$RUNNER_HOME"

# 6. Register. --ephemeral => GitHub deregisters the runner after ONE job.
sudo -u runner ./config.sh \
  --unattended --ephemeral --replace \
  --url "https://github.com/$GITHUB_REPO" \
  --token "$REG_TOKEN" \
  --name "$INSTANCE_NAME" \
  --labels "$RUNNER_LABELS" \
  --work _work
unset REG_TOKEN

echo "==> runner registered; waiting for a job"

# 7. Blocks until exactly one job has completed (or the runner is removed).
sudo -u runner ./run.sh || echo "!! runner exited non-zero (job failure or cancellation)"

# 8. Self-destruct. The MIG notices the missing instance and recreates a
#    pristine VM, so nothing the agent did during `cm fix` can persist.
echo "==> job finished; deleting $INSTANCE_NAME"
gcloud compute instances delete "$INSTANCE_NAME" --zone "$ZONE" --quiet
