#!/bin/bash

# This script runs as root on aap1 (via setup-automation/main.yml). AAP
# itself, and the aap1-user OS account, are already baked into the
# aap1-* golden image - this script only wires up the Satellite -> EDA
# webhook pipeline (self-hosted rulebook repo, EDA credentials, Project,
# Event Stream, Activation) idempotently, every time the lab is
# (re)provisioned.
#
# See docs/EDA_WEBHOOK_SETUP.md for the full manual/CLI walkthrough this
# script automates, including troubleshooting notes.

# TODO: set this to the actual AAP application admin password for this
# lab's aap1 image (NOT the aap1-user OS account password).
AAP_ADMIN_PASSWORD="bc31c9a6-9ff0-11ec-9587-00155d1b0702"

# Everything below runs as aap1-user, since the self-hosted git repo,
# deploy key, and EDA API calls (as aap1-user's own SSH session) all
# assume that user's $HOME. --preserve-env carries AAP_ADMIN_PASSWORD
# through to the sudo'd shell; the heredoc itself is single-quoted so
# none of its own $(...) / $VAR usage is touched by the outer shell.
export AAP_ADMIN_PASSWORD
sudo -u aap1-user --preserve-env=AAP_ADMIN_PASSWORD -H bash <<'AAPUSER_EOF'
set -e
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

if ! git diff --quiet 2>/dev/null || [ -z "$(git log -1 2>/dev/null)" ]; then
  git add rulebooks/satellite-webhook.yml
  git commit -m "Add satellite webhook rulebook" || true
  git branch -M main
fi
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
BASIC_CRED_ID=$(ensure_id "/eda-credentials/" "Satellite Webhook Basic Auth")
BASIC_AUTH_SECRET_FILE=~/.eda_webhook_basic_auth.json
if [ -z "$BASIC_CRED_ID" ]; then
  BASIC_CRED_TYPE_ID=$(eda_get "/credential-types/?name=Basic%20Event%20Stream" | jq_field "['results'][0]['id']")
  WEBHOOK_USER="satellite-webhook"
  WEBHOOK_PASS=$(python3 -c "import secrets; print(secrets.token_urlsafe(24))")
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
  python3 -c "import json,os; json.dump({'username': os.environ['WEBHOOK_USER'], 'password': os.environ['WEBHOOK_PASS']}, open(os.path.expanduser('$BASIC_AUTH_SECRET_FILE'), 'w'))"
  chmod 600 "$BASIC_AUTH_SECRET_FILE"
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

echo "==> Done. Event Stream URL for Satellite's webhook target-url:"
echo "$EVENT_STREAM_URL"
echo "==> SETUP-AAP1: SUCCESS"
AAPUSER_EOF
