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

# CAUTION: the block below is one big single-quoted "bash -c" string. Do not use
# an apostrophe anywhere inside it - not even in a comment - or it will close the
# quote early and the rest of the block will be parsed as stray commands
# (symptom: "drools: line N" errors and an unterminated RULEBOOK_EOF).
#
# This file used to be a heredoc inside setup-aap1.sh, where that mistake broke
# provisioning. It now breaks only this script, at Module 4 runtime, in front of
# a participant. Running `bash -n` on this file catches it earlier than either.
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
    # NOTE: this is deliberately ONE rule with TWO actions, not two rules.
    # The ansible-rulebook drools engine fires at most ONE rule per event
    # (first matching rule wins, then the event is consumed), so a separate
    # catch-all "condition: true" logging rule listed first would swallow
    # every event and the remediation rule below it would never fire. Running
    # both the debug log and the job-template launch as two actions of a
    # single success-scoped rule is the correct way to make both happen.
    - name: Log Satellite remote execution success and remediate CVEs
      condition: event.payload.task_result == "success"
      actions:
        - debug:
            msg: "Received Satellite webhook: {{ event }}"
        - run_job_template:
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
if [ -n "$ACTIVATION_ID" ]; then
  # EDA activation deletion is asynchronous: the DELETE returns immediately
  # while the running pod is torn down in the background. Disable it first
  # to speed teardown, then wait until it is actually gone before creating
  # the replacement - otherwise the POST below races the delete and fails
  # with "activation with this name already exists".
  curl -sk -u "$EDA_AUTH" -X POST "$EDA_API/activations/$ACTIVATION_ID/disable/" \
    -H "Content-Type: application/json" -d '{}' > /dev/null 2>&1 || true
  curl -sk -u "$EDA_AUTH" -X DELETE "$EDA_API/activations/$ACTIVATION_ID/" > /dev/null
  for i in $(seq 1 60); do
    STILL=$(curl -sk -u "$EDA_AUTH" "$EDA_API/activations/?name=Satellite%20Webhook%20Activation" \
      | python3 -c "import sys,json; print(len(json.load(sys.stdin)['results']))")
    [ "$STILL" = "0" ] && break
    echo "waiting for old activation to be deleted..."
    sleep 2
  done
fi

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
