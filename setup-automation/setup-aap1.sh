#!/bin/bash

# This script runs as root on aap1 (via setup-automation/main.yml). AAP
# itself, and the aap1-user OS account, are already baked into the
# aap1-* golden image - this script wires up the Satellite -> EDA
# webhook pipeline (self-hosted rulebook repo, EDA credentials,
# Project, Event Stream, Activation), the registry.redhat.io pre-auth
# and vulnerability-remediation repo Module 4 needs, and the two
# scripts Module 4's Steps 4/5 walk the participant through running.
# Idempotent: every step here is safe to run again on every
# (re)provision.
#
# See docs/EDA_WEBHOOK_SETUP.md for the full manual/CLI walkthrough this
# script automates, including troubleshooting notes.

# The large payloads this script installs (the vulnerability finder, the
# remediation playbook, the Containerfile, and Module 4's two /root
# helper scripts) ship alongside it as real files, in
# setup-automation/files-aap1/, copied here by setup-automation/main.yml.
#
# This script has no `set -e`, so a missing payload would fail silently
# and we would go on to git-commit and push a repo with files missing.
# Module 4 would then hand the participant a broken
# ~/vulnerability-remediation. Fail up front, before anything on this
# host has been touched.
PAYLOAD_DIR=/tmp/setup-scripts/files-aap1
for _f in Containerfile find_and_remediate.yml vulnerability_remediation.py \
          create-controller-project.sh wire-rulebook.sh; do
  if [ ! -s "$PAYLOAD_DIR/$_f" ]; then
    echo "==> SETUP-AAP1: FAILED - missing or empty payload $PAYLOAD_DIR/$_f" >&2
    exit 1
  fi
  # The test above runs as root, which bypasses permission bits, so it
  # cannot catch the case that matters: a payload delivered unreadable
  # to aap1-user, who consumes three of these inside the sudo block
  # below. Checking as that user covers the file mode and traversal on
  # every parent directory at once.
  if ! sudo -u aap1-user test -r "$PAYLOAD_DIR/$_f"; then
    echo "==> SETUP-AAP1: FAILED - $PAYLOAD_DIR/$_f not readable by aap1-user" >&2
    exit 1
  fi
done
unset _f

systemctl stop dnf-automatic-install.timer
systemctl disable dnf-automatic-install.timer
systemctl mask dnf-automatic-install.timer

systemctl stop dnf-automatic.timer
systemctl disable dnf-automatic.timer

sed -i 's/^apply_updates.*/apply_updates = no/' /etc/dnf/automatic.conf
sed -i 's/^download_updates.*/download_updates = no/' /etc/dnf/automatic.conf

# AAP application admin password from the aap1-* golden image, not the
# aap1-user OS account password. It matches Satellite's admin password.
#
# Changing it here is not enough. The same literal is hardcoded in
# files-aap1/create-controller-project.sh, files-aap1/wire-rulebook.sh,
# the module .adocs, and the solve scripts, none of which can reference
# this variable.
AAP_ADMIN_PASSWORD="bc31c9a6-9ff0-11ec-9587-00155d1b0702"

# Pre-authenticate root's podman against registry.redhat.io so Module 4
# (Step 2, building the custom Execution Environment) never has to ask
# the participant for their own Red Hat registry credentials by hand.
# REGISTRY_PULL_TOKEN is the full base64 "auth" value from a registry
# service account (username and password already combined), passed
# through by setup-automation/main.yml.
#
# Write the credential directly to root's DEFAULT podman auth file
# ($HOME/.config/containers/auth.json, i.e. /root/.config/containers/
# auth.json - this is what podman falls back to when $XDG_RUNTIME_DIR
# isn't set, which is the common case for a non-interactive root shell).
# An earlier version of this wrote to a /tmp file, pointed `podman
# login --authfile` at that SAME /tmp file, then deleted it - so the
# credential never reached podman's real default location at all and
# every later `podman build`/`pull` as root still prompted for auth.
# Also set REGISTRY_AUTH_FILE in /root/.bashrc as a second, explicit
# guarantee that works even if some other login shell's $XDG_RUNTIME_DIR
# happens to be set and would otherwise take precedence.
# Declare aap1.lab itself as an insecure registry (HTTPS with
# certificate verification skipped) in registries.conf.d, rather than
# relying solely on the one-off `podman push/build --tls-verify=false`
# CLI flag. Without this, some internal podman operations (e.g. the
# cross-repository blob-reuse ping that happens on push) don't reliably
# honor that per-command flag and fall back to plain HTTP on port 80
# instead, which nothing listens on ("connect: connection refused"),
# even though the actual registry (served over HTTPS on 443 by envoy)
# works fine.
mkdir -p /etc/containers/registries.conf.d
cat > /etc/containers/registries.conf.d/aap1-insecure.conf <<'EOF'
[[registry]]
location = "aap1.lab"
insecure = true
EOF

if [ -n "${REGISTRY_PULL_TOKEN:-}" ]; then
  mkdir -p /root/.config/containers
  cat > /root/.config/containers/auth.json <<EOF
{
  "auths": {
    "registry.redhat.io": {
      "auth": "${REGISTRY_PULL_TOKEN}"
    }
  }
}
EOF
  if ! grep -q "^export REGISTRY_AUTH_FILE=" /root/.bashrc 2>/dev/null; then
    echo 'export REGISTRY_AUTH_FILE=/root/.config/containers/auth.json' >> /root/.bashrc
  fi
fi

# Passwordless root-to-root SSH between the lab's hosts is already baked
# into the golden images (e.g. satellite.lab's root can already SSH into
# aap1.lab's root with no password) - but aap1-user is a separate OS
# account on the aap1 image, so it never inherited that same trust.
# Module 3's solve script (and its Step 1/3 instructions) need
# satellite.lab's root to SSH into aap1-user@aap1.lab with no password
# prompt, so copy whatever key(s) already let root in, into aap1-user's
# authorized_keys too. This is idempotent: re-running just re-appends
# any keys not already present.
if [ -f /root/.ssh/authorized_keys ]; then
  install -d -m 700 -o aap1-user -g aap1-user /home/aap1-user/.ssh
  touch /home/aap1-user/.ssh/authorized_keys
  comm -23 \
    <(sort -u /root/.ssh/authorized_keys) \
    <(sort -u /home/aap1-user/.ssh/authorized_keys) \
    >> /home/aap1-user/.ssh/authorized_keys
  chmod 600 /home/aap1-user/.ssh/authorized_keys
  chown aap1-user:aap1-user /home/aap1-user/.ssh/authorized_keys
fi

# Everything below runs as aap1-user, since the self-hosted git repo,
# deploy key, and EDA API calls (as aap1-user's own SSH session) all
# assume that user's $HOME. --preserve-env carries AAP_ADMIN_PASSWORD
# through to the sudo'd shell; the heredoc itself is single-quoted so
# none of its own $(...) / $VAR usage is touched by the outer shell.
export AAP_ADMIN_PASSWORD
sudo -u aap1-user --preserve-env=AAP_ADMIN_PASSWORD -H bash -s "$PAYLOAD_DIR" <<'AAPUSER_EOF'
set -e
# This heredoc is single-quoted, so $PAYLOAD_DIR from the outer script
# does not expand in here. `bash -s` passes it in as $1 instead, which
# keeps the path defined in exactly one place.
PAYLOAD_DIR="$1"
: "${PAYLOAD_DIR:?AAPUSER block: PAYLOAD_DIR argument not passed}"
# The outer 'sh -x .../setup-aap1.sh > setup-aap1.log 2>&1' invocation
# (see setup-automation/main.yml) only traces this outer script's own
# lines - it never sees inside this heredoc, since that content is fed
# to a separate bash process via stdin, not read by the outer shell as
# script text. Turn tracing on again here so the log file actually
# captures every command this block runs, and add an ERR trap so a
# failure is unmistakable (with a line number) instead of the log just
# silently stopping mid-step.
set -x
trap 'echo "==> FAILED at line $LINENO (exit code $?)" >&2' ERR

echo "==> 0. Extend the AAP session timeout so the web UI stops logging participants out"
# SESSION_COOKIE_AGE is in seconds; default is 1800 (30 minutes), which
# is too short for a lab session. 28800 is 8 hours.
curl -sk -u "admin:$AAP_ADMIN_PASSWORD" -X PATCH "https://localhost/api/controller/v2/settings/system/" \
  -H "Content-Type: application/json" -d '{"SESSION_COOKIE_AGE": 28800}' > /dev/null

export EDA_API="https://localhost/api/eda/v1"
export EDA_AUTH="admin:$AAP_ADMIN_PASSWORD"
export REPO_URL="ssh://aap1-user@localhost/home/aap1-user/git/satellite-webhook.git"
mkdir -p /tmp/eda-setup

eda_get() {
  curl -sk -u "$EDA_AUTH" -X GET "$EDA_API$1"
}

eda_send() {
  local method="$1" path="$2" payload_file="$3"
  curl -sk -u "$EDA_AUTH" -X "$method" "$EDA_API$path" \
    -H "Content-Type: application/json" -d @"$payload_file"
}

jq_field() {
  python3 -c '
import sys, json
raw = sys.stdin.read()
data = json.loads(raw)
expr = sys.argv[1]
try:
    print(eval("data" + expr))
except (KeyError, IndexError, TypeError):
    sys.stderr.write("jq_field: field " + expr + " not found in response:\n" + raw + "\n")
    sys.exit(1)
' "$1"
}

# ensure_id <endpoint-path> <exact-name> - prints the id if a resource
# with that exact name already exists, or an empty string if it doesn't.
ensure_id() {
  eda_get "$1?name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$2")" \
    | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')"
}

echo "==> 1. Ensure self-hosted rulebook repo + deploy key exist"
mkdir -p ~/git
if [ ! -d ~/git/satellite-webhook.git ]; then
  git init --bare ~/git/satellite-webhook.git
  git -C ~/git/satellite-webhook.git symbolic-ref HEAD refs/heads/main
fi

if [ ! -f ~/.ssh/eda_project_deploy_key ]; then
  ssh-keygen -t ed25519 -f ~/.ssh/eda_project_deploy_key -N "" -C "eda-project-sync"
fi
if ! grep -qF "$(cat ~/.ssh/eda_project_deploy_key.pub)" ~/.ssh/authorized_keys 2>/dev/null; then
  cat ~/.ssh/eda_project_deploy_key.pub >> ~/.ssh/authorized_keys
fi
chmod 600 ~/.ssh/authorized_keys ~/.ssh/eda_project_deploy_key
ssh -n -o StrictHostKeyChecking=accept-new -i ~/.ssh/eda_project_deploy_key aap1-user@localhost true

mkdir -p ~/satellite-webhook && cd ~/satellite-webhook
if [ ! -d .git ]; then
  git init
  git remote add aap "$REPO_URL"
fi
git config user.name "aap1-user"
git config user.email "aap1-user@aap1.lab"

# EDA requires rulebooks to live in an 'extensions/eda/rulebooks/' or
# 'rulebooks/' directory within the project root - a rulebook file
# sitting at the repo root is silently not picked up (the project sync
# still reports import_state: completed, but with a non-fatal
# import_error and zero rulebooks found).
mkdir -p rulebooks
cat > rulebooks/satellite-webhook.yml <<'EOF'
---
- name: Satellite Remote Execution Webhook
  hosts: all
  sources:
    - ansible.eda.webhook:
        host: 127.0.0.1
        port: 5000
      name: satellite_webhook
  rules:
    - name: Log Satellite remote execution success
      condition: true
      action:
        debug:
          msg: "Received Satellite webhook: {{ event }}"
EOF

# 'git diff --quiet' alone only detects changes to already-tracked
# files - it misses a brand-new untracked file entirely (e.g. this
# rulebooks/ path on a repo whose working clone still has an older,
# already-committed version at a different location). Stage first,
# then check the staged diff so new files are caught too.
git add rulebooks/satellite-webhook.yml
if ! git diff --cached --quiet; then
  git commit -m "Add satellite webhook rulebook"
fi
git branch -M main
GIT_SSH_COMMAND="ssh -i ~/.ssh/eda_project_deploy_key -o IdentitiesOnly=yes" git push aap main

echo "==> 2. Ensure SCM (Source Control) credential"
SCM_CRED_ID=$(ensure_id "/eda-credentials/" "Self-hosted repo deploy key")
if [ -z "$SCM_CRED_ID" ]; then
  SCM_CRED_TYPE_ID=$(eda_get "/credential-types/?name=Source%20Control" | jq_field "['results'][0]['id']")
  cat > /tmp/eda-setup/build_scm_cred.py <<'PYEOF'
import json, os
print(json.dumps({
    "name": "Self-hosted repo deploy key",
    "credential_type_id": int(os.environ["SCM_CRED_TYPE_ID"]),
    "organization_id": 1,
    "inputs": {"ssh_key_data": open(os.path.expanduser("~/.ssh/eda_project_deploy_key")).read()},
}))
PYEOF
  SCM_CRED_TYPE_ID="$SCM_CRED_TYPE_ID" python3 /tmp/eda-setup/build_scm_cred.py > /tmp/eda-setup/scm_cred.json
  SCM_CRED_ID=$(eda_send POST "/eda-credentials/" /tmp/eda-setup/scm_cred.json | jq_field "['id']")
fi
echo "SCM_CRED_ID=$SCM_CRED_ID"

echo "==> 3. Ensure EDA Project (and sync)"
PROJECT_ID=$(ensure_id "/projects/" "Satellite Webhook Rulebooks")
if [ -z "$PROJECT_ID" ]; then
  cat > /tmp/eda-setup/build_project.py <<'PYEOF'
import json, os
print(json.dumps({
    "name": "Satellite Webhook Rulebooks",
    "url": os.environ["REPO_URL"],
    "eda_credential_id": int(os.environ["SCM_CRED_ID"]),
    "organization_id": 1,
}))
PYEOF
  REPO_URL="$REPO_URL" SCM_CRED_ID="$SCM_CRED_ID" python3 /tmp/eda-setup/build_project.py > /tmp/eda-setup/project.json
  PROJECT_ID=$(eda_send POST "/projects/" /tmp/eda-setup/project.json | jq_field "['id']")
else
  cat > /tmp/eda-setup/sync_project.json <<EOF
{"name": "Satellite Webhook Rulebooks"}
EOF
  eda_send POST "/projects/$PROJECT_ID/sync/" /tmp/eda-setup/sync_project.json > /dev/null
fi
echo "PROJECT_ID=$PROJECT_ID"

for i in $(seq 1 20); do
  STATE=$(eda_get "/projects/$PROJECT_ID/" | jq_field "['import_state']")
  echo "import_state=$STATE"
  [ "$STATE" = "completed" ] && break
  [ "$STATE" = "failed" ] && { echo "Project sync failed"; eda_get "/projects/$PROJECT_ID/" | jq_field "['import_error']"; exit 1; }
  sleep 2
done

echo "==> 4. Look up the synced rulebook"
RULEBOOK_ID=$(eda_get "/rulebooks/?project_id=$PROJECT_ID" | python3 -c '
import sys, json
raw = sys.stdin.read()
data = json.loads(raw)
matches = [r["id"] for r in data["results"] if r["name"] == "satellite-webhook.yml"]
if not matches:
    sys.stderr.write(
        "No rulebook named satellite-webhook.yml found in project '"$PROJECT_ID"'.\n"
        "Full /rulebooks/?project_id='"$PROJECT_ID"' response:\n" + raw + "\n"
    )
    sys.exit(1)
print(matches[0])
')
echo "RULEBOOK_ID=$RULEBOOK_ID"

echo "==> 5. Ensure Basic Auth (Basic Event Stream) credential"
BASIC_AUTH_SECRET_FILE=~/.eda_webhook_basic_auth.json

# EDA credential secrets are write-only via the API - once created,
# there is no way to read the password back out. So: decide the
# username/password and persist them to the LOCAL secret file FIRST,
# before ever creating/touching the remote credential. That way, if
# this script crashes between creating the remote credential and
# saving the secret locally, a re-run reuses the same already-saved
# local secret instead of permanently losing access to whatever
# password the (already-created) remote credential holds.
if [ -f "$BASIC_AUTH_SECRET_FILE" ]; then
  WEBHOOK_USER=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$BASIC_AUTH_SECRET_FILE')))['username'])")
  WEBHOOK_PASS=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('$BASIC_AUTH_SECRET_FILE')))['password'])")
  echo "Reusing existing local secret file ($BASIC_AUTH_SECRET_FILE)"
else
  WEBHOOK_USER="satellite-webhook"
  WEBHOOK_PASS=$(python3 -c "import secrets; print(secrets.token_urlsafe(24))")
  WEBHOOK_USER="$WEBHOOK_USER" WEBHOOK_PASS="$WEBHOOK_PASS" \
    python3 -c "import json,os; json.dump({'username': os.environ['WEBHOOK_USER'], 'password': os.environ['WEBHOOK_PASS']}, open(os.path.expanduser('$BASIC_AUTH_SECRET_FILE'), 'w'))"
  chmod 600 "$BASIC_AUTH_SECRET_FILE"
  echo "Generated new local secret file ($BASIC_AUTH_SECRET_FILE)"
fi

BASIC_CRED_ID=$(ensure_id "/eda-credentials/" "Satellite Webhook Basic Auth")
if [ -z "$BASIC_CRED_ID" ]; then
  BASIC_CRED_TYPE_ID=$(eda_get "/credential-types/?name=Basic%20Event%20Stream" | jq_field "['results'][0]['id']")
  cat > /tmp/eda-setup/build_basic_cred.py <<'PYEOF'
import json, os
print(json.dumps({
    "name": "Satellite Webhook Basic Auth",
    "credential_type_id": int(os.environ["BASIC_CRED_TYPE_ID"]),
    "organization_id": 1,
    "inputs": {
        "username": os.environ["WEBHOOK_USER"],
        "password": os.environ["WEBHOOK_PASS"],
    },
}))
PYEOF
  BASIC_CRED_TYPE_ID="$BASIC_CRED_TYPE_ID" WEBHOOK_USER="$WEBHOOK_USER" WEBHOOK_PASS="$WEBHOOK_PASS" \
    python3 /tmp/eda-setup/build_basic_cred.py > /tmp/eda-setup/basic_cred.json
  BASIC_CRED_ID=$(eda_send POST "/eda-credentials/" /tmp/eda-setup/basic_cred.json | jq_field "['id']")
fi
echo "BASIC_CRED_ID=$BASIC_CRED_ID (credentials saved to $BASIC_AUTH_SECRET_FILE)"

echo "==> 6. Ensure Event Stream"
EVENT_STREAM_ID=$(ensure_id "/event-streams/" "Satellite Remote Execution Webhook")
if [ -z "$EVENT_STREAM_ID" ]; then
  cat > /tmp/eda-setup/build_event_stream.py <<'PYEOF'
import json, os
print(json.dumps({
    "name": "Satellite Remote Execution Webhook",
    "eda_credential_id": int(os.environ["BASIC_CRED_ID"]),
    "organization_id": 1,
}))
PYEOF
  BASIC_CRED_ID="$BASIC_CRED_ID" python3 /tmp/eda-setup/build_event_stream.py > /tmp/eda-setup/event_stream.json
  EVENT_STREAM_ID=$(eda_send POST "/event-streams/" /tmp/eda-setup/event_stream.json | jq_field "['id']")
fi
EVENT_STREAM_URL=$(eda_get "/event-streams/$EVENT_STREAM_ID/" | jq_field "['url']")
echo "EVENT_STREAM_ID=$EVENT_STREAM_ID"
echo "EVENT_STREAM_URL=$EVENT_STREAM_URL"
python3 -c "import json,os; d=json.load(open(os.path.expanduser('$BASIC_AUTH_SECRET_FILE'))); d['event_stream_url']='$EVENT_STREAM_URL'; json.dump(d, open(os.path.expanduser('$BASIC_AUTH_SECRET_FILE'), 'w'))" 2>/dev/null || true

echo "==> 7. Ensure Rulebook Activation"
DE_ID=$(eda_get "/decision-environments/?name=Default%20Decision%20Environment" | jq_field "['results'][0]['id']")
RULEBOOK_HASH=$(eda_get "/rulebooks/$RULEBOOK_ID/" \
  | python3 -c "import sys,json,hashlib; print(hashlib.sha256(json.load(sys.stdin)['rulesets'].encode()).hexdigest())")

ACTIVATION_ID=$(ensure_id "/activations/" "Satellite Webhook Activation")
if [ -z "$ACTIVATION_ID" ]; then
  cat > /tmp/eda-setup/build_activation.py <<'PYEOF'
import json, os
source_mappings = json.dumps([{
    "source_name": "satellite_webhook",
    "event_stream_id": int(os.environ["EVENT_STREAM_ID"]),
    "event_stream_name": "Satellite Remote Execution Webhook",
    "rulebook_hash": os.environ["RULEBOOK_HASH"],
}])
print(json.dumps({
    "name": "Satellite Webhook Activation",
    "rulebook_id": int(os.environ["RULEBOOK_ID"]),
    "decision_environment_id": int(os.environ["DE_ID"]),
    "organization_id": 1,
    "eda_credentials": [int(os.environ["BASIC_CRED_ID"])],
    "is_enabled": True,
    "source_mappings": source_mappings,
}))
PYEOF
  EVENT_STREAM_ID="$EVENT_STREAM_ID" RULEBOOK_HASH="$RULEBOOK_HASH" RULEBOOK_ID="$RULEBOOK_ID" \
    DE_ID="$DE_ID" BASIC_CRED_ID="$BASIC_CRED_ID" \
    python3 /tmp/eda-setup/build_activation.py > /tmp/eda-setup/activation.json
  ACTIVATION_ID=$(eda_send POST "/activations/" /tmp/eda-setup/activation.json | jq_field "['id']")
fi
echo "ACTIVATION_ID=$ACTIVATION_ID"

for i in $(seq 1 20); do
  STATUS=$(eda_get "/activations/$ACTIVATION_ID/" | jq_field "['status']")
  echo "status=$STATUS"
  [ "$STATUS" = "running" ] && break
  sleep 3
done

echo "==> 8. Ensure the vulnerability finder + remediation playbook repo (Module 4)"
# Self-hosted the same way as the satellite-webhook repo above, reusing
# the same deploy key. Pre-populating this here (rather than having the
# participant paste an ~800-line script and a playbook by hand in
# Module 4) removes the biggest source of copy/paste errors in that
# module - Module 4 only explains what each file does and runs commands
# against them, it never creates them.
mkdir -p ~/git
if [ ! -d ~/git/vulnerability-remediation.git ]; then
  git init --bare ~/git/vulnerability-remediation.git
  git -C ~/git/vulnerability-remediation.git symbolic-ref HEAD refs/heads/main
fi

mkdir -p ~/vulnerability-remediation && cd ~/vulnerability-remediation
if [ ! -d .git ]; then
  git init
  git remote add controller ssh://aap1-user@localhost/home/aap1-user/git/vulnerability-remediation.git
fi
git config user.name "aap1-user"
git config user.email "aap1-user@aap1.lab"

cp "$PAYLOAD_DIR/Containerfile" Containerfile

cp "$PAYLOAD_DIR/find_and_remediate.yml" find_and_remediate.yml

cp "$PAYLOAD_DIR/vulnerability_remediation.py" vulnerability_remediation.py
chmod +x vulnerability_remediation.py

git add Containerfile find_and_remediate.yml vulnerability_remediation.py
if ! git diff --cached --quiet; then
  git commit -m "Add vulnerability finder + remediation playbook"
fi
git branch -M main
GIT_SSH_COMMAND="ssh -i ~/.ssh/eda_project_deploy_key -o IdentitiesOnly=yes" git push controller main

echo "==> Done. Event Stream URL for Satellite's webhook target-url:"
echo "$EVENT_STREAM_URL"
echo "==> SETUP-AAP1: SUCCESS"
AAPUSER_EOF

# Building and registering a custom Execution Environment is a routine
# AAP administration task, not something this lab is trying to teach,
# so it happens here during setup instead of as a participant step in
# Module 4. The aap1-* golden image normally already has
# aap1.lab/ee-vuln-finder:latest built and cached in local podman
# storage (baked in ahead of time), so the build step below is only a
# fallback for an older image that predates that, skipped entirely
# when the image is already present.
cd /home/aap1-user/vulnerability-remediation
if ! podman image exists aap1.lab/ee-vuln-finder:latest; then
  podman build -t ee-vuln-finder -f Containerfile .
  podman tag ee-vuln-finder:latest aap1.lab/ee-vuln-finder:latest
fi
podman login --tls-verify=false -u admin -p "$AAP_ADMIN_PASSWORD" aap1.lab
podman push --tls-verify=false aap1.lab/ee-vuln-finder:latest

# Controller runs containerized/rootless as aap1-user, and launches every
# job/project-sync Execution Environment via podman with slirp4netns
# networking (DEFAULT_CONTAINER_RUN_OPTIONS in controller/etc/settings.py).
# slirp4netns's default subnet (10.0.2.0/24) both collides with aap1's real
# enp1s0 address AND, without allow_host_loopback=true, blocks the EE from
# reaching this host's sshd at all. That matters because Module 4's
# Controller Project pulls the self-hosted vulnerability-remediation git
# repo over ssh to aap1's own sshd (via podman's host.containers.internal
# alias). Enable allow_host_loopback so that project sync can succeed, then
# restart the controller-task service so it picks up the change. Idempotent.
CTRL_SETTINGS=/home/aap1-user/aap/controller/etc/settings.py
if [ -f "$CTRL_SETTINGS" ] && ! grep -q 'allow_host_loopback=true' "$CTRL_SETTINGS"; then
  sed -i 's/slirp4netns:enable_ipv6=true"/slirp4netns:enable_ipv6=true,allow_host_loopback=true"/' "$CTRL_SETTINGS"
  chown aap1-user:aap1-user "$CTRL_SETTINGS"
  sudo -iu aap1-user env XDG_RUNTIME_DIR=/run/user/$(id -u aap1-user) \
    systemctl --user restart automation-controller-task.service || true
  # Give the task container a moment to come back before we hit the API.
  for i in $(seq 1 30); do
    curl -sk -o /dev/null -u "admin:$AAP_ADMIN_PASSWORD" \
      "https://localhost/api/controller/v2/ping/" && break
    sleep 2
  done
fi

export CTRL_API="https://localhost/api/controller/v2"
export CTRL_AUTH="admin:$AAP_ADMIN_PASSWORD"
EE_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/execution_environments/?name=Vulnerability%20Finder%20EE" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
if [ -z "$EE_ID" ]; then
  EE_ID=$(curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/execution_environments/" \
    -H "Content-Type: application/json" \
    -d '{"name": "Vulnerability Finder EE", "image": "aap1.lab/ee-vuln-finder:latest", "pull": "missing"}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
fi
echo "EE_ID=$EE_ID"

# Pre-populate the two scripts Module 4 (Steps 3 and 4) walks the
# participant through running. Both are fully self-contained and
# idempotent (same "look it up by name, create if missing" pattern used
# throughout this file), so they don't depend on any shell variables
# from earlier steps in the participant's own terminal session - only
# on resources that already exist by the time each step runs. Writing
# these here (rather than having the participant paste large heredocs
# that write intermediate helper files, e.g. a Python payload builder
# or the rulebook YAML, by hand) removes that copy/paste risk the same
# way Step 1's Containerfile/find_and_remediate.yml/
# vulnerability_remediation.py pre-population already does - Module 4
# only explains what each script does and runs it, it never creates one
# from scratch in front of the participant.
cp "$PAYLOAD_DIR/create-controller-project.sh" /root/create-controller-project.sh
chmod +x /root/create-controller-project.sh

cp "$PAYLOAD_DIR/wire-rulebook.sh" /root/wire-rulebook.sh
chmod +x /root/wire-rulebook.sh
