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

cat > Containerfile <<'EOF'
# Custom Execution Environment: adds `uv` (needed by
# vulnerability_remediation.py's `#!/usr/bin/env -S uv run --script`
# shebang) on top of AAP's supported base EE image.
FROM registry.redhat.io/ansible-automation-platform-27/ee-supported-rhel9:latest

RUN pip3 install --no-cache-dir uv
EOF

cat > find_and_remediate.yml <<'EOF'
---
- name: Find CVE remediations for the affected host
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - name: Run vulnerability_remediation.py scoped to the affected host
      ansible.builtin.command:
        cmd: >-
          python3 vulnerability_remediation.py
          --satellite https://satellite.lab
          --username {{ satellite_username }}
          --host {{ host_name }}
          --insecure
        chdir: "{{ playbook_dir }}"
      register: scan_result
      changed_when: false
    - name: Parse the JSON report
      ansible.builtin.set_fact:
        remediations: "{{ scan_result.stdout | from_json }}"
    - name: Collect every package that needs installing on this host
      ansible.builtin.set_fact:
        packages_to_install: >-
          {{ remediations
             | selectattr("packages_to_install_on_host", "defined")
             | map(attribute="packages_to_install_on_host")
             | select("truthy")
             | sum(start=[]) }}
    - name: Hand the affected host + package list to the next play
      ansible.builtin.add_host:
        name: "{{ host_name }}"
        groups: affected_hosts
        packages_to_install: "{{ packages_to_install }}"

- name: Install the fixed packages on the affected host
  hosts: affected_hosts
  become: true
  gather_facts: false
  tasks:
    - name: Install/upgrade each package that remediates a found CVE
      ansible.builtin.dnf:
        name: "{{ item }}"
        state: present
      loop: "{{ hostvars[inventory_hostname].packages_to_install }}"
      register: install_results
      when: hostvars[inventory_hostname].packages_to_install | length > 0
EOF

cat > vulnerability_remediation.py <<'PYSCRIPT_EOF'
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "requests>=2.31",
# ]
# ///
"""
vulnerability_remediation.py

A custom script written for this lab that:
  1. Logs in to this lab's Red Hat Satellite server.
  2. Queries CVEs from Red Hat Lightspeed > Vulnerability (the CVE
     dashboard) - IMPORTANT: this data comes from the Red Hat Lightspeed
     Vulnerability service running ON-PREMISES, as part of Satellite
     itself. It is not the hosted console.redhat.com cloud service - the
     API this script calls (``/insights_cloud/api/vulnerability/v1/...``)
     is served locally by Satellite, using vulnerability/CVE data that
     was synced into Satellite ahead of time (see `setup-satellite.sh`'s
     `cvemap.xml` download). No traffic leaves this lab network.
  3. Filters for CVEs at a given severity (default: Important).
  4. For each matching CVE, finds the exact erratum + RPM package(s) that
     fix it, and flags whether that erratum is actually installable
     today.
  5. When scoped to one host (`--host`), narrows that down to exactly
     the packages that host needs, in a form Ansible's `dnf` module can
     consume directly - this is what Module 4's rulebook/Job Template
     pipeline acts on.

How it talks to Satellite
--------------------------
Two Satellite APIs are used, both under the same authenticated session:

  * Foreman/Katello REST API (``/api``, ``/katello/api``) - documented,
    stable, supports HTTP Basic Auth. Used to enumerate hosts and to look
    up errata (and their exact packages) for a given CVE.

  * The **on-premises** Red Hat Lightspeed / Insights vulnerability API
    (``/insights_cloud/api/vulnerability/v1/...``) that powers the
    "Red Hat Lightspeed > Vulnerability" page in the Satellite web UI.
    Despite the URL path containing "insights_cloud", this endpoint is
    served entirely by Satellite itself, on `satellite.lab`, from
    locally-synced vulnerability data - not by any external Red Hat
    cloud service. It only accepts session-cookie auth (the same auth
    you get from the normal web login form), so the script logs in
    exactly like a browser would (fetches the CSRF token, POSTs
    credentials) rather than using HTTP Basic Auth for that part.

Usage
-----
This script is a self-contained `uv` script (PEP 723 inline metadata), so
`uv` resolves and installs its one dependency (`requests`) into an ephemeral
environment on first run - no venv or `pip install` needed:

    uv run vulnerability_remediation.py \\
        --satellite https://satellite.example.com \\
        --username admin \\
        [--password '...']         # omit to be prompted / read from env
        [--severity Important]     # repeatable; default: Important,Critical
        [--status "Not Reviewed"]  # repeatable; default: all statuses
        [--insecure]               # skip TLS verification (self-signed certs)
        [--host compliance5.lab]   # show exactly which packages install on this host
        [--text]                   # print the human-readable report (default: JSON)
        [--output[=PATH]]          # write to a file instead of stdout (omit PATH
                                    # for an auto-generated timestamped filename)
        [--verbose]                # with --host, show the full report instead of
                                    # the minimal {cve_id, errata_id, packages_to_install_on_host}

Or, since it's executable and has a `uv run --script` shebang, just:

    ./vulnerability_remediation.py --satellite ... --username ...

The password can also be supplied via the SATELLITE_PASSWORD environment
variable to avoid putting it on the command line / shell history.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import sys
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

import requests
import urllib3

DEFAULT_SEVERITIES = ["Critical", "Important"]

# CVE severity values ("impact" attribute) as rated by Red Hat's own
# security response process: https://access.redhat.com/security/updates/classification
# "None" covers CVEs Red Hat hasn't assigned a severity rating to (e.g. not
# yet triaged, or not applicable to any Red Hat product).
VALID_SEVERITIES = ["Critical", "Important", "Moderate", "Low", "None"]


def validate_severities(names: Iterable[str]) -> list[str]:
    """Normalize/validate human-readable --severity values against the known
    set. Raises ValueError with the full list of valid names on a typo."""
    lookup = {v.lower(): v for v in VALID_SEVERITIES}
    result = []
    for name in names:
        key = name.strip().lower()
        if key not in lookup:
            raise ValueError(f"Unknown CVE severity {name!r}. Valid values: {', '.join(VALID_SEVERITIES)}")
        result.append(lookup[key])
    return result

# CVE status values as defined by Red Hat's vulnerability service (Red Hat
# Lightspeed / Insights). ID order matches Red Hat's documented lifecycle:
# https://docs.redhat.com/.../vuln-refining-data_vuln-overview (section 3.9 "CVE status")
STATUS_NAME_TO_ID = {
    "not reviewed": 0,
    "in-review": 1,
    "in review": 1,
    "on-hold": 2,
    "on hold": 2,
    "scheduled for patch": 3,
    "resolved": 4,
    "no action - risk accepted": 5,
    "risk accepted": 5,
    "resolved via mitigation": 6,
    "mitigated": 6,
}
STATUS_ID_TO_NAME = {
    0: "Not Reviewed",
    1: "In-Review",
    2: "On-Hold",
    3: "Scheduled for Patch",
    4: "Resolved",
    5: "No Action - Risk Accepted",
    6: "Resolved via Mitigation",
}


def resolve_status_ids(names: Iterable[str]) -> list[int]:
    """Translate human-readable --status values to the numeric status_id
    values the API expects. Raises ValueError with the full list of valid
    names if anything doesn't match."""
    ids = []
    for name in names:
        key = name.strip().lower()
        if key not in STATUS_NAME_TO_ID:
            valid = ", ".join(STATUS_ID_TO_NAME[i] for i in sorted(STATUS_ID_TO_NAME))
            raise ValueError(f"Unknown CVE status {name!r}. Valid values: {valid}")
        ids.append(STATUS_NAME_TO_ID[key])
    return ids


@dataclass
class Erratum:
    errata_id: str
    title: str
    type: str
    severity: str
    packages: list[str]
    hosts_available_count: int
    hosts_applicable_count: int
    # Populated only when --host is given: the subset of `packages` that
    # would actually be installed/upgraded on that specific host (i.e. the
    # target host already has an older version of that package installed).
    # None means "not computed" (no --host given); [] means "computed, and
    # none of this erratum's packages apply to that host".
    packages_to_install_on_host: list[str] | None = None

    @property
    def is_installable_anywhere(self) -> bool:
        return self.hosts_applicable_count > 0


@dataclass
class CveResult:
    cve_id: str
    severity: str
    status: str
    cvss3_score: str | None
    description: str
    systems_affected: int
    affected_systems: list[str] = field(default_factory=list)
    errata: list[Erratum] = field(default_factory=list)

    @property
    def has_remediation(self) -> bool:
        return any(e.is_installable_anywhere for e in self.errata)


def base_package_name(nvra: str) -> str:
    """Strip version-release.arch off an RPM NVRA string, e.g.
    'kernel-5.14.0-284.18.1.el9_2.x86_64' -> 'kernel'."""
    return nvra.rsplit("-", 2)[0]


def _version_release(nvra: str) -> tuple[str, str]:
    """Split an NVRA into (version, release) - name and arch are dropped.
    E.g. 'kernel-5.14.0-284.18.1.el9_2.x86_64' -> ('5.14.0', '284.18.1.el9_2')."""
    _name, version, release_arch = nvra.rsplit("-", 2)
    release, _arch = release_arch.rsplit(".", 1)
    return version, release


def _rpmvercmp(a: str, b: str) -> int:
    """Minimal reimplementation of RPM's version-comparison algorithm
    (rpmvercmp): compares two version or release strings segment by segment
    (digit runs vs letter runs), the same way `dnf`/`rpm` decide whether one
    build is newer than another. Returns -1, 0, or 1."""
    if a == b:
        return 0
    ai = bi = 0
    while ai < len(a) or bi < len(b):
        while ai < len(a) and not (a[ai].isalnum() or a[ai] == "~"):
            ai += 1
        while bi < len(b) and not (b[bi].isalnum() or b[bi] == "~"):
            bi += 1

        a_tilde = ai < len(a) and a[ai] == "~"
        b_tilde = bi < len(b) and b[bi] == "~"
        if a_tilde or b_tilde:
            if not a_tilde:
                return 1
            if not b_tilde:
                return -1
            ai += 1
            bi += 1
            continue

        if ai >= len(a) or bi >= len(b):
            break

        a_start = ai
        is_num = a[ai].isdigit()
        test = str.isdigit if is_num else str.isalpha
        while ai < len(a) and test(a[ai]):
            ai += 1
        a_seg = a[a_start:ai]

        b_start = bi
        while bi < len(b) and test(b[bi]):
            bi += 1
        b_seg = b[b_start:bi]

        if not b_seg:
            return 1 if is_num else -1

        if is_num:
            a_seg = a_seg.lstrip("0") or "0"
            b_seg = b_seg.lstrip("0") or "0"
            if len(a_seg) != len(b_seg):
                return 1 if len(a_seg) > len(b_seg) else -1

        if a_seg != b_seg:
            return 1 if a_seg > b_seg else -1

    if ai < len(a):
        return 1
    if bi < len(b):
        return -1
    return 0


def installed_is_up_to_date(installed_nvra: str, target_nvra: str) -> bool:
    """True if the installed package is already at or newer than the
    version/release the erratum would install (so applying the erratum
    would not touch it)."""
    installed_ver, installed_rel = _version_release(installed_nvra)
    target_ver, target_rel = _version_release(target_nvra)
    version_cmp = _rpmvercmp(installed_ver, target_ver)
    if version_cmp != 0:
        return version_cmp > 0
    return _rpmvercmp(installed_rel, target_rel) >= 0


class SatelliteClient:
    """Thin wrapper around the Satellite APIs used by this script."""

    def __init__(self, base_url: str, username: str, password: str, verify: bool = True):
        self.base_url = base_url.rstrip("/")
        self.session = requests.Session()
        self.session.verify = verify
        self._username = username
        self._password = password

    # -- auth -----------------------------------------------------------
    def login(self) -> None:
        """Log in via the same web form the Satellite UI uses.

        This establishes a session cookie, which is required by the
        internal Lightspeed vulnerability API. It also lets every other
        call in this script reuse a single authenticated session.
        """
        login_page = self.session.get(f"{self.base_url}/users/login")
        login_page.raise_for_status()
        match = re.search(r'name="csrf-token" content="([^"]+)"', login_page.text)
        if not match:
            raise RuntimeError("Could not find CSRF token on the Satellite login page")
        csrf_token = match.group(1)

        response = self.session.post(
            f"{self.base_url}/users/login",
            data={
                "authenticity_token": csrf_token,
                "login[login]": self._username,
                "login[password]": self._password,
                "commit": "Log in",
            },
            headers={"Referer": f"{self.base_url}/users/login"},
        )
        response.raise_for_status()
        if "/users/login" in response.url:
            raise RuntimeError(
                "Login failed - check the Satellite URL, username, and password"
            )

    # -- Red Hat Lightspeed / Insights vulnerability API -----------------
    def fetch_cves(
        self, limit: int = 100, status_ids: list[int] | None = None
    ) -> list[dict[str, Any]]:
        """Return every CVE affecting managed hosts, as reported by the
        Red Hat Lightspeed > Vulnerability page. By default this includes
        CVEs in *any* status (Not Reviewed, In-Review, On-Hold, Scheduled
        for Patch, Resolved, No Action - Risk Accepted, Resolved via
        Mitigation); pass `status_ids` to filter to a subset."""
        cves: list[dict[str, Any]] = []
        offset = 0
        while True:
            params = {
                "offset": offset,
                "limit": limit,
                "sort": "-public_date",
                "affecting_host_type": "rpmdnf",
            }
            if status_ids:
                params["status_id"] = ",".join(str(i) for i in status_ids)
            resp = self.session.get(
                f"{self.base_url}/insights_cloud/api/vulnerability/v1/vulnerabilities/cves",
                params=params,
                headers={"Accept": "application/json"},
            )
            resp.raise_for_status()
            payload = resp.json()
            cves.extend(payload.get("data", []))
            total = payload.get("meta", {}).get("total_items", len(cves))
            offset += limit
            if offset >= total:
                break
        return cves

    def fetch_affected_systems(self, cve_id: str, limit: int = 100) -> list[str]:
        """Return the hostnames of every managed host affected by this CVE,
        as shown on the CVE's detail page under Red Hat Lightspeed >
        Vulnerability."""
        names: list[str] = []
        offset = 0
        while True:
            resp = self.session.get(
                f"{self.base_url}/insights_cloud/api/vulnerability/v1/cves/{cve_id}/affected_systems",
                params={"offset": offset, "limit": limit},
                headers={"Accept": "application/json"},
            )
            resp.raise_for_status()
            payload = resp.json()
            names.extend(
                row["attributes"]["display_name"] for row in payload.get("data", [])
            )
            total = payload.get("meta", {}).get("total_items", len(names))
            offset += limit
            if offset >= total:
                break
        return names

    # -- Katello content API --------------------------------------------
    def find_errata_for_cve(self, cve_id: str, per_page: int = 100) -> list[Erratum]:
        """Return every erratum (across all repos Satellite knows about)
        that remediates the given CVE, including its exact package list."""
        results: list[Erratum] = []
        page = 1
        while True:
            resp = self.session.get(
                f"{self.base_url}/katello/api/errata",
                params={"search": f"cve = {cve_id}", "per_page": per_page, "page": page},
                headers={"Accept": "application/json"},
            )
            resp.raise_for_status()
            payload = resp.json()
            for row in payload.get("results", []):
                results.append(
                    Erratum(
                        errata_id=row["errata_id"],
                        title=row.get("title") or row.get("name") or "",
                        type=row.get("type", ""),
                        severity=row.get("severity") or "None",
                        packages=row.get("packages", []),
                        hosts_available_count=row.get("hosts_available_count", 0) or 0,
                        hosts_applicable_count=row.get("hosts_applicable_count", 0) or 0,
                    )
                )
            # NOTE: "total" is the size of the *entire* unfiltered collection;
            # "subtotal" is the count matching our search filter. Must use
            # subtotal here or pagination loops (almost) forever.
            matched = payload.get("subtotal", payload.get("total", len(results)))
            if page * per_page >= matched:
                break
            page += 1
        return results

    # -- Foreman host API -------------------------------------------------
    def resolve_host(self, host_identifier: str) -> tuple[int, str]:
        """Resolve a hostname or numeric Foreman host id to (id, canonical
        hostname). The canonical hostname is what the Lightspeed API's
        ``affected_systems`` list uses, so results can be matched exactly
        even if the caller passed a numeric id."""
        resp = self.session.get(
            f"{self.base_url}/api/hosts/{host_identifier}",
            headers={"Accept": "application/json"},
        )
        resp.raise_for_status()
        data = resp.json()
        return data["id"], data["name"]

    def get_installed_package_names(self, host_id: int, per_page: int = 1000) -> dict[str, str]:
        """Return {base_package_name: installed_nvra} for everything installed
        on the given host."""
        installed: dict[str, str] = {}
        page = 1
        while True:
            resp = self.session.get(
                f"{self.base_url}/api/hosts/{host_id}/packages",
                params={"per_page": per_page, "page": page},
                headers={"Accept": "application/json"},
            )
            resp.raise_for_status()
            payload = resp.json()
            for row in payload.get("results", []):
                nvra = row.get("nvra") or row["name"]
                installed[base_package_name(nvra)] = nvra
            matched = payload.get("subtotal", payload.get("total", len(installed)))
            if page * per_page >= matched:
                break
            page += 1
        return installed

    def is_erratum_applicable_to_host(self, errata_id: str, host_id: int) -> bool:
        """True if Satellite considers this erratum applicable to this host
        (accounts for version comparison, content view/lifecycle env, etc -
        not just "is some package with this name installed")."""
        resp = self.session.get(
            f"{self.base_url}/api/hosts",
            params={"search": f"id = {host_id} and applicable_errata = {errata_id}"},
            headers={"Accept": "application/json"},
        )
        resp.raise_for_status()
        # "subtotal" is the count matching our search filter; "total" is the
        # whole host inventory and is always > 0.
        return resp.json().get("subtotal", 0) > 0


def resolve_packages_for_host(
    client: SatelliteClient, erratum: Erratum, host_id: int, installed: dict[str, str]
) -> list[str]:
    """Given a host's installed packages (base name -> NVRA), return the
    subset of `erratum.packages` that would actually be installed/upgraded
    if this erratum were applied to that host right now.

    A package is only included if it's installed AND its installed version
    is older than what the erratum ships - otherwise (e.g. it was already
    manually updated) applying the erratum wouldn't touch it.
    """
    if not client.is_erratum_applicable_to_host(erratum.errata_id, host_id):
        return []
    to_install = []
    for pkg in erratum.packages:
        installed_nvra = installed.get(base_package_name(pkg))
        if installed_nvra is None:
            continue  # not installed on this host at all
        if installed_is_up_to_date(installed_nvra, pkg):
            continue  # already at or past the version this erratum ships
        to_install.append(pkg)
    return to_install


_verbose_logging = False


def log(message: str) -> None:
    """Status/progress output. Silent by default; enabled with --verbose.
    Always goes to stderr (never stdout), so it never ends up mixed into
    piped/redirected report output either way."""
    if _verbose_logging:
        print(message, file=sys.stderr)


def build_report(
    client: SatelliteClient,
    severities: Iterable[str],
    host: str | None = None,
    statuses: Iterable[str] | None = None,
) -> tuple[list[CveResult], str | None]:
    """Returns (results, resolved_host_name). resolved_host_name is the
    canonical hostname Satellite knows the given --host by (which may differ
    in case, or may have been given as a numeric id) - use it instead of the
    raw --host argument when matching against affected_systems."""
    wanted = {s.lower() for s in validate_severities(severities)}
    status_ids = resolve_status_ids(statuses) if statuses else None

    host_id: int | None = None
    host_name: str | None = None
    installed: dict[str, str] = {}
    if host:
        log(f"Resolving host '{host}' and its installed packages ...")
        host_id, host_name = client.resolve_host(host)
        installed = client.get_installed_package_names(host_id)
        log(f"  {host_name} (id {host_id}) has {len(installed)} package(s) installed")

    log("Fetching CVEs from Red Hat Lightspeed > Vulnerability ...")
    raw_cves = client.fetch_cves(status_ids=status_ids)
    if status_ids:
        log(
            f"  found {len(raw_cves)} CVE(s) affecting managed hosts "
            f"with status in ({', '.join(STATUS_ID_TO_NAME[i] for i in status_ids)})"
        )
    else:
        log(f"  found {len(raw_cves)} CVE(s) affecting managed hosts (all statuses)")

    matches = [c for c in raw_cves if c["attributes"]["impact"].lower() in wanted]
    log(
        f"  {len(matches)} CVE(s) match requested severity "
        f"({', '.join(sorted({s.title() for s in wanted}))})"
    )

    results: list[CveResult] = []
    for cve in matches:
        attrs = cve["attributes"]
        cve_id = cve["id"]
        log(f"Looking up remediation for {cve_id} ({attrs['impact']}) ...")
        errata = client.find_errata_for_cve(cve_id)
        affected_systems = client.fetch_affected_systems(cve_id)

        if host_id is not None:
            # Scoped to one host: only that host is relevant here, not
            # every other host this CVE happens to affect.
            affected_systems = [s for s in affected_systems if s == host_name]
            for erratum in errata:
                erratum.packages_to_install_on_host = resolve_packages_for_host(
                    client, erratum, host_id, installed
                )

        results.append(
            CveResult(
                cve_id=cve_id,
                severity=attrs["impact"],
                status=attrs.get("status") or STATUS_ID_TO_NAME.get(attrs.get("status_id"), "Unknown"),
                cvss3_score=attrs.get("cvss3_score"),
                description=attrs.get("description", "").strip(),
                systems_affected=attrs.get("systems_affected", 0),
                affected_systems=affected_systems,
                errata=errata,
            )
        )
    return results, host_name


def human_report_text(results: list[CveResult], host: str | None = None) -> str:
    lines: list[str] = []
    lines.append("\n" + "=" * 78)
    lines.append("VULNERABILITY REMEDIATION REPORT")
    if host:
        lines.append(f"Scoped to host: {host}")
    lines.append("=" * 78)

    if not results:
        lines.append("No CVEs matched the requested severity filter.")
        return "\n".join(lines)

    for cve in results:
        lines.append(f"\n{cve.cve_id}  [{cve.severity}]  status: {cve.status}  CVSS3: {cve.cvss3_score or 'n/a'}")
        lines.append(f"  Affects {len(cve.affected_systems)} host(s): {', '.join(cve.affected_systems) or 'n/a'}")
        lines.append(f"  {cve.description[:200]}")

        if not cve.errata:
            lines.append("  ** NO ERRATUM FOUND IN SATELLITE - notify sysadmins **")
            continue

        for erratum in cve.errata:
            status = (
                "installable"
                if erratum.is_installable_anywhere
                else "NOT YET APPLICABLE/INSTALLABLE ANYWHERE"
            )
            lines.append(f"  - {erratum.errata_id} ({erratum.type}, {erratum.severity}) [{status}]")
            lines.append(f"    {erratum.title}")

            if erratum.packages_to_install_on_host is None:
                # No --host given: this is the erratum's full shipped manifest,
                # not a prediction for any particular host.
                lines.append(f"    Ships {len(erratum.packages)} package(s) (full manifest, not host-specific):")
                for pkg in erratum.packages:
                    lines.append(f"      package: {pkg}")
            elif not erratum.packages_to_install_on_host:
                lines.append(f"    Not applicable to {host} - nothing would be installed")
            else:
                to_install = erratum.packages_to_install_on_host
                lines.append(
                    f"    Will install {len(to_install)} of {len(erratum.packages)} shipped package(s) on {host}:"
                )
                for pkg in to_install:
                    lines.append(f"      package: {pkg}")

    missing = [c for c in results if not c.has_remediation]
    lines.append("\n" + "-" * 78)
    if missing:
        lines.append(f"{len(missing)} CVE(s) have NO installable remediation available yet:")
        for cve in missing:
            lines.append(f"  - {cve.cve_id} ({cve.severity})")
        lines.append("Action: notify sysadmins / trigger content view sync+promotion.")
    else:
        lines.append("Every matched CVE has at least one installable erratum available.")

    return "\n".join(lines)


def results_to_dict(results: list[CveResult]) -> list[dict[str, Any]]:
    """Full machine-readable form of the report (every field), used when
    ``--verbose`` is given, or whenever ``--host`` wasn't used (there's no
    per-host data to slim down to in that case)."""
    return [
        {
            "cve_id": c.cve_id,
            "severity": c.severity,
            "status": c.status,
            "cvss3_score": c.cvss3_score,
            "description": c.description,
            "systems_affected": c.systems_affected,
            "affected_systems": c.affected_systems,
            "has_remediation": c.has_remediation,
            "errata": [
                {
                    "errata_id": e.errata_id,
                    "title": e.title,
                    "type": e.type,
                    "severity": e.severity,
                    "packages": e.packages,
                    "hosts_available_count": e.hosts_available_count,
                    "hosts_applicable_count": e.hosts_applicable_count,
                    "packages_to_install_on_host": e.packages_to_install_on_host,
                }
                for e in c.errata
            ],
        }
        for c in results
    ]


def results_to_minimal_dict(results: list[CveResult]) -> list[dict[str, Any]]:
    """Slim machine-readable form: just enough to act on
    ``packages_to_install_on_host`` (which CVE/erratum, which packages,
    which hosts are affected). This is the default JSON shape when
    ``--host`` is given; pass ``--verbose`` for the full report instead."""
    return [
        {
            "cve_id": c.cve_id,
            "affected_systems": c.affected_systems,
            "errata_id": e.errata_id,
            "packages_to_install_on_host": e.packages_to_install_on_host,
        }
        for c in results
        for e in c.errata
    ]


def report_to_dict(results: list[CveResult], host: str | None, verbose: bool) -> list[dict[str, Any]]:
    """Pick the full or minimal JSON shape based on --host/--verbose."""
    if host and not verbose:
        return results_to_minimal_dict(results)
    return results_to_dict(results)


def json_report_text(results: list[CveResult], host: str | None = None, verbose: bool = False) -> str:
    return json.dumps(report_to_dict(results, host, verbose))


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--satellite", required=True, help="Base URL, e.g. https://satellite.example.com")
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", help="Falls back to $SATELLITE_PASSWORD, then an interactive prompt")
    parser.add_argument(
        "--severity",
        action="append",
        dest="severities",
        help=(
            "CVE severity to include (repeatable). Default: Critical, Important. "
            "Valid values: " + ", ".join(VALID_SEVERITIES)
        ),
    )
    parser.add_argument("--insecure", action="store_true", help="Skip TLS certificate verification")
    parser.add_argument(
        "--status",
        action="append",
        dest="statuses",
        help=(
            "CVE status to include (repeatable). Default: all statuses. Valid values: "
            + ", ".join(STATUS_ID_TO_NAME[i] for i in sorted(STATUS_ID_TO_NAME))
        ),
    )
    parser.add_argument(
        "--host",
        help=(
            "Scope the report to one host: instead of each erratum's full shipped "
            "package manifest, show exactly which of those packages would actually "
            "be installed/upgraded on this host (accepts hostname or Foreman host id)."
        ),
    )
    parser.add_argument(
        "--text",
        action="store_true",
        help="Print the human-readable report instead of JSON (the default output is JSON, for piping into jq/scripts).",
    )
    parser.add_argument(
        "--output",
        nargs="?",
        const="",
        metavar="PATH",
        help=(
            "Write the report to a file instead of printing it to stdout. "
            "Omit PATH for an auto-generated, timestamped filename."
        ),
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help=(
            "Print status/progress messages to stderr as the script runs (silent by "
            "default). With --host, also switches JSON output to the full report "
            "instead of the minimal default {cve_id, errata_id, packages_to_install_on_host} "
            "(no effect on that with --text)."
        ),
    )
    return parser.parse_args(argv)


def default_output_path(extension: str) -> str:
    return datetime.now().strftime(f"vulnerability-report-%Y-%m-%d_%H-%M-%S.{extension}")  # noqa: DTZ005 (local wall-clock time is intended)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    global _verbose_logging
    _verbose_logging = args.verbose

    password = args.password or os.environ.get("SATELLITE_PASSWORD")
    if not password:
        password = getpass.getpass(f"Password for {args.username}@{args.satellite}: ")

    if args.insecure:
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    client = SatelliteClient(args.satellite, args.username, password, verify=not args.insecure)

    log(f"Logging in to {args.satellite} as {args.username} ...")
    try:
        client.login()
    except (requests.RequestException, RuntimeError) as exc:
        print(f"Login failed: {exc}", file=sys.stderr)
        return 1
    log("Login successful.")

    severities = args.severities or DEFAULT_SEVERITIES
    try:
        results, host_name = build_report(client, severities, host=args.host, statuses=args.statuses)
    except requests.HTTPError as exc:
        print(f"Could not resolve host '{args.host}': {exc}", file=sys.stderr)
        return 1
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if args.text:
        text = human_report_text(results, host=host_name)
        extension = "txt"
    else:
        text = json_report_text(results, host=host_name, verbose=args.verbose)
        extension = "json"

    if args.output is None:
        print(text)
    else:
        path = args.output or default_output_path(extension)
        with open(path, "w") as fh:
            fh.write(text)
        log(f"Wrote report to {path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PYSCRIPT_EOF
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

# Pre-populate the two scripts Module 4 (Steps 4 and 5) walks the
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
cat > /root/create-controller-project.sh <<'CTRLPROJ_EOF'
#!/bin/bash
set -e
export CTRL_API="https://localhost/api/controller/v2"
export CTRL_AUTH="admin:bc31c9a6-9ff0-11ec-9587-00155d1b0702"

EE_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/execution_environments/?name=Vulnerability%20Finder%20EE" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
echo "EE_ID=$EE_ID"

CRED_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/credentials/?name=Satellite%20Admin%20(API)" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
echo "CRED_ID=$CRED_ID"

# Reuse the SAME deploy key from Module 3 as the SCM credential.
SCM_CRED_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/credentials/?name=Self-hosted%20repo%20deploy%20key%20(Controller)" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
if [ -z "$SCM_CRED_ID" ]; then
  SCM_CRED_TYPE_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/credential_types/?name=Source%20Control" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['id'])")
  DEPLOY_KEY=$(sudo -u aap1-user bash -c 'cat ~/.ssh/eda_project_deploy_key')
  SCM_CRED_ID=$(DEPLOY_KEY="$DEPLOY_KEY" SCM_CRED_TYPE_ID="$SCM_CRED_TYPE_ID" python3 -c "
import json, os
print(json.dumps({
    'name': 'Self-hosted repo deploy key (Controller)',
    'organization': 1,
    'credential_type': int(os.environ['SCM_CRED_TYPE_ID']),
    'inputs': {'ssh_key_data': os.environ['DEPLOY_KEY']},
}))
" | curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/credentials/" -H "Content-Type: application/json" -d @- \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
fi
echo "SCM_CRED_ID=$SCM_CRED_ID"

PROJECT_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/projects/?name=Vulnerability%20Package%20Finder" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$(curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/projects/" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"Vulnerability Package Finder\", \"organization\": 1, \"scm_type\": \"git\", \"scm_url\": \"ssh://aap1-user@localhost/home/aap1-user/git/vulnerability-remediation.git\", \"credential\": $SCM_CRED_ID}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
fi
echo "PROJECT_ID=$PROJECT_ID"

UPDATE_ID=$(curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/projects/$PROJECT_ID/update/" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "UPDATE_ID=$UPDATE_ID"
for i in $(seq 1 30); do
  STATUS=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/project_updates/$UPDATE_ID/" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
  echo "project update status=$STATUS"
  [ "$STATUS" = "successful" ] && break
  sleep 2
done

# Reuse an existing inventory - our playbook targets localhost for the
# scan, then dynamically adds the affected host via add_host, so it
# doesn't matter which inventory is attached.
INVENTORY_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/inventories/?page_size=1" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['id'])")
echo "INVENTORY_ID=$INVENTORY_ID"

JT_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/job_templates/?name=Vulnerability%20Package%20Finder%20and%20Remediator" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
if [ -z "$JT_ID" ]; then
  JT_ID=$(curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/job_templates/" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"Vulnerability Package Finder and Remediator\", \"job_type\": \"run\", \"inventory\": $INVENTORY_ID, \"project\": $PROJECT_ID, \"playbook\": \"find_and_remediate.yml\", \"execution_environment\": $EE_ID, \"ask_variables_on_launch\": true}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
fi
echo "JT_ID=$JT_ID"

curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/job_templates/$JT_ID/credentials/" \
  -H "Content-Type: application/json" -d "{\"id\": $CRED_ID}"
CTRLPROJ_EOF
chmod +x /root/create-controller-project.sh

cat > /root/wire-rulebook.sh <<'WIRE_RULEBOOK_EOF'
#!/bin/bash
set -e
export EDA_API="https://localhost/api/eda/v1"
export EDA_AUTH="admin:bc31c9a6-9ff0-11ec-9587-00155d1b0702"
mkdir -p /tmp/eda-setup

CTRL_CRED_TYPE_ID=$(curl -sk -u "$EDA_AUTH" "$EDA_API/credential-types/?name=Red%20Hat%20Ansible%20Automation%20Platform" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
CTRL_CRED_ID=$(curl -sk -u "$EDA_AUTH" "$EDA_API/eda-credentials/?name=AAP%20Controller" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
if [ -z "$CTRL_CRED_ID" ]; then
  CTRL_CRED_TYPE_ID="$CTRL_CRED_TYPE_ID" python3 -c "
import json, os
print(json.dumps({
    'name': 'AAP Controller',
    'credential_type_id': int(os.environ['CTRL_CRED_TYPE_ID']),
    'organization_id': 1,
    'inputs': {
        'host': 'https://localhost/api/controller/',
        'username': 'admin',
        'password': 'bc31c9a6-9ff0-11ec-9587-00155d1b0702',
        'verify_ssl': False,
    },
}))
" | curl -sk -u "$EDA_AUTH" -X POST "$EDA_API/eda-credentials/" -H "Content-Type: application/json" -d @- \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" > /tmp/eda-setup/ctrl_cred_id
  CTRL_CRED_ID=$(cat /tmp/eda-setup/ctrl_cred_id)
fi
echo "CTRL_CRED_ID=$CTRL_CRED_ID"

sudo -u aap1-user bash -c '
cd ~/satellite-webhook
cat > rulebooks/satellite-webhook.yml <<RULEBOOK_EOF
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

    - name: Find and remediate CVEs on the affected host
      condition: event.payload.task_result == "success"
      action:
        run_job_template:
          name: "Vulnerability Package Finder and Remediator"
          organization: "Default"
          job_args:
            extra_vars:
              host_name: "{{ event.payload.host_name }}"
RULEBOOK_EOF
git add rulebooks/satellite-webhook.yml
git commit -m "Launch the vulnerability finder/remediator job template on success" || true
GIT_SSH_COMMAND="ssh -i ~/.ssh/eda_project_deploy_key -o IdentitiesOnly=yes" git push aap main
'

PROJECT_ID=$(curl -sk -u "$EDA_AUTH" "$EDA_API/projects/?name=Satellite%20Webhook%20Rulebooks" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['id'])")
curl -sk -u "$EDA_AUTH" -X POST "$EDA_API/projects/$PROJECT_ID/sync/" \
  -H "Content-Type: application/json" -d '{"name": "Satellite Webhook Rulebooks"}' > /dev/null

for i in $(seq 1 20); do
  STATE=$(curl -sk -u "$EDA_AUTH" "$EDA_API/projects/$PROJECT_ID/" | python3 -c "import sys,json; print(json.load(sys.stdin)['import_state'])")
  echo "import_state=$STATE"
  [ "$STATE" = "completed" ] && break
  sleep 2
done

RULEBOOK_ID=$(curl -sk -u "$EDA_AUTH" "$EDA_API/rulebooks/?project_id=$PROJECT_ID" \
  | python3 -c "import sys,json; print([r['id'] for r in json.load(sys.stdin)['results'] if r['name']=='satellite-webhook.yml'][0])")
RULEBOOK_HASH=$(curl -sk -u "$EDA_AUTH" "$EDA_API/rulebooks/$RULEBOOK_ID/" \
  | python3 -c "import sys,json,hashlib; print(hashlib.sha256(json.load(sys.stdin)['rulesets'].encode()).hexdigest())")

BASIC_CRED_ID=$(curl -sk -u "$EDA_AUTH" "$EDA_API/eda-credentials/?name=Satellite%20Webhook%20Basic%20Auth" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['id'])")
EVENT_STREAM_ID=$(curl -sk -u "$EDA_AUTH" "$EDA_API/event-streams/?name=Satellite%20Remote%20Execution%20Webhook" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['id'])")
DE_ID=$(curl -sk -u "$EDA_AUTH" "$EDA_API/decision-environments/?name=Default%20Decision%20Environment" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['id'])")

ACTIVATION_ID=$(curl -sk -u "$EDA_AUTH" "$EDA_API/activations/?name=Satellite%20Webhook%20Activation" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
[ -n "$ACTIVATION_ID" ] && curl -sk -u "$EDA_AUTH" -X DELETE "$EDA_API/activations/$ACTIVATION_ID/"

EVENT_STREAM_ID="$EVENT_STREAM_ID" RULEBOOK_HASH="$RULEBOOK_HASH" RULEBOOK_ID="$RULEBOOK_ID" \
  DE_ID="$DE_ID" BASIC_CRED_ID="$BASIC_CRED_ID" CTRL_CRED_ID="$CTRL_CRED_ID" python3 -c "
import json, os
source_mappings = json.dumps([{
    'source_name': 'satellite_webhook',
    'event_stream_id': int(os.environ['EVENT_STREAM_ID']),
    'event_stream_name': 'Satellite Remote Execution Webhook',
    'rulebook_hash': os.environ['RULEBOOK_HASH'],
}])
print(json.dumps({
    'name': 'Satellite Webhook Activation',
    'rulebook_id': int(os.environ['RULEBOOK_ID']),
    'decision_environment_id': int(os.environ['DE_ID']),
    'organization_id': 1,
    'eda_credentials': [int(os.environ['BASIC_CRED_ID']), int(os.environ['CTRL_CRED_ID'])],
    'is_enabled': True,
    'source_mappings': source_mappings,
}))
" | curl -sk -u "$EDA_AUTH" -X POST "$EDA_API/activations/" -H "Content-Type: application/json" -d @-
WIRE_RULEBOOK_EOF
chmod +x /root/wire-rulebook.sh
