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

# The remediation playbook's second play (install the fixed RPMs) runs
# ON the affected host over SSH with become, so the Job Template needs a
# Machine credential - without one the EE cannot connect and every host
# fails with "Permission denied (publickey)". Reuse the lab's own SSH key
# (the IdentityFile root already uses to reach every managed host, per
# /root/.ssh/config) as that credential, connecting as root.
MACHINE_CRED_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/credentials/?name=Managed%20Hosts%20SSH" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
if [ -z "$MACHINE_CRED_ID" ]; then
  MACHINE_CRED_TYPE_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/credential_types/?namespace=ssh" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['id'])")
  LAB_SSH_KEY_FILE=$(awk '/IdentityFile/{print $2; exit}' /root/.ssh/config | sed "s|^~|$HOME|")
  [ -f "$LAB_SSH_KEY_FILE" ] || LAB_SSH_KEY_FILE=$(ls /root/.ssh/*.pem 2>/dev/null | head -1)
  MACHINE_CRED_ID=$(LAB_SSH_KEY_FILE="$LAB_SSH_KEY_FILE" MACHINE_CRED_TYPE_ID="$MACHINE_CRED_TYPE_ID" python3 -c "
import json, os
print(json.dumps({
    'name': 'Managed Hosts SSH',
    'organization': 1,
    'credential_type': int(os.environ['MACHINE_CRED_TYPE_ID']),
    'inputs': {'username': 'root', 'ssh_key_data': open(os.environ['LAB_SSH_KEY_FILE']).read()},
}))
" | curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/credentials/" -H "Content-Type: application/json" -d @- \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
fi
echo "MACHINE_CRED_ID=$MACHINE_CRED_ID"

# Controller's Project sync runs inside an Execution Environment
# container that this containerized/rootless AAP launches via aap1-user's
# podman with slirp4netns networking (see DEFAULT_CONTAINER_RUN_OPTIONS in
# controller/etc/settings.py). From inside that container the ONLY way to
# reach this host's sshd - where the self-hosted git repo lives - is
# podman's "host.containers.internal" alias, and only because setup-aap1.sh
# added allow_host_loopback=true to those slirp4netns options. Neither the
# host's real IP (10.0.2.x, which collides with slirp4netns's own subnet ->
# "Network is unreachable") nor podman's bridge gateway (10.88.0.1, unused
# by these rootless slirp4netns containers -> "Connection refused") work
# here. The EDA Project earlier in this file legitimately uses "localhost"
# because EDA's own Project sync does not run inside such a container.
GIT_HOST="host.containers.internal"
SCM_URL="ssh://aap1-user@${GIT_HOST}/home/aap1-user/git/vulnerability-remediation.git"
PROJECT_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/projects/?name=Vulnerability%20Package%20Finder" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$(curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/projects/" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"Vulnerability Package Finder\", \"organization\": 1, \"scm_type\": \"git\", \"scm_url\": \"$SCM_URL\", \"credential\": $SCM_CRED_ID}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
else
  # Self-heal: an already-existing project (e.g. from an earlier attempt)
  # may carry a stale, unreachable scm_url - force it to the correct value
  # and SCM credential so idempotent re-runs actually converge.
  curl -sk -u "$CTRL_AUTH" -X PATCH "$CTRL_API/projects/$PROJECT_ID/" \
    -H "Content-Type: application/json" \
    -d "{\"scm_url\": \"$SCM_URL\", \"credential\": $SCM_CRED_ID}" > /dev/null
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

# Attach BOTH credentials: the Satellite API cred (for the scan play on
# localhost) and the Machine cred (for the install play over SSH on the
# affected host). A Job Template can hold one credential of each type.
curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/job_templates/$JT_ID/credentials/" \
  -H "Content-Type: application/json" -d "{\"id\": $CRED_ID}"
curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/job_templates/$JT_ID/credentials/" \
  -H "Content-Type: application/json" -d "{\"id\": $MACHINE_CRED_ID}"
