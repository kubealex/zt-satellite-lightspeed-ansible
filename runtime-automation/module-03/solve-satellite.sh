#!/bin/sh
echo "Solving module-03" >> /tmp/progress.log

# Most of this module's setup happens on aap1.lab, not satellite.lab -
# SSH over and run it there. Mirrors the steps in module-03.adoc.
#
# PREREQUISITE (not automated here, see module-03.adoc Step 1's NOTE and
# Step 2's registry login): vulnerability_remediation.py must already be
# present at ~/vulnerability-remediation/vulnerability_remediation.py on
# aap1.lab (as aap1-user), and `podman login registry.redhat.io` must
# already be authenticated on aap1.lab, before this script can build the
# custom Execution Environment.
ssh -o StrictHostKeyChecking=no root@aap1.lab /bin/bash <<'REMOTE_EOF'
set -e

sudo -u aap1-user bash -c '
set -e
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

cat > Containerfile <<CFEOF
FROM registry.redhat.io/ansible-automation-platform-27/ee-supported-rhel9:latest
RUN pip3 install --no-cache-dir uv
CFEOF

cat > find_and_remediate.yml <<PBEOF
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
      when: hostvars[inventory_hostname].packages_to_install | length > 0
PBEOF

git add Containerfile find_and_remediate.yml vulnerability_remediation.py
git commit -m "Add vulnerability finder + remediation playbook" || true
git branch -M main
GIT_SSH_COMMAND="ssh -i ~/.ssh/eda_project_deploy_key -o IdentitiesOnly=yes" git push controller main
'

# Build + push the custom EE (assumes registry.redhat.io login already done)
cd /home/aap1-user/vulnerability-remediation
podman build -t ee-vuln-finder -f Containerfile .
podman tag ee-vuln-finder:latest aap1.lab/ee-vuln-finder:latest
podman login --tls-verify=false -u admin -p "bc31c9a6-9ff0-11ec-9587-00155d1b0702" aap1.lab
podman push --tls-verify=false aap1.lab/ee-vuln-finder:latest

export CTRL_API="https://localhost/api/controller/v2"
export CTRL_AUTH="admin:bc31c9a6-9ff0-11ec-9587-00155d1b0702"
export EDA_API="https://localhost/api/eda/v1"
export EDA_AUTH="admin:bc31c9a6-9ff0-11ec-9587-00155d1b0702"

EE_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/execution_environments/?name=Vulnerability%20Finder%20EE" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
if [ -z "$EE_ID" ]; then
  EE_ID=$(curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/execution_environments/" \
    -H "Content-Type: application/json" \
    -d '{"name": "Vulnerability Finder EE", "image": "aap1.lab/ee-vuln-finder:latest", "pull": "missing"}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
fi

CRED_TYPE_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/credential_types/?name=Satellite%20API%20Credentials" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
if [ -z "$CRED_TYPE_ID" ]; then
  CRED_TYPE_ID=$(curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/credential_types/" \
    -H "Content-Type: application/json" \
    -d '{"name": "Satellite API Credentials", "kind": "cloud", "inputs": {"fields": [{"id": "username", "type": "string", "label": "Username"}, {"id": "password", "type": "string", "label": "Password", "secret": true}], "required": ["username", "password"]}, "injectors": {"extra_vars": {"satellite_username": "{{ username }}"}, "env": {"SATELLITE_PASSWORD": "{{ password }}"}}}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
fi

CRED_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/credentials/?name=Satellite%20Admin%20(API)" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
if [ -z "$CRED_ID" ]; then
  CRED_ID=$(curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/credentials/" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"Satellite Admin (API)\", \"organization\": 1, \"credential_type\": $CRED_TYPE_ID, \"inputs\": {\"username\": \"admin\", \"password\": \"bc31c9a6-9ff0-11ec-9587-00155d1b0702\"}}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
fi

SCM_CRED_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/credentials/?name=Self-hosted%20repo%20deploy%20key%20(Controller)" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
if [ -z "$SCM_CRED_ID" ]; then
  SCM_CRED_TYPE_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/credential_types/?name=Source%20Control" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['id'])")
  DEPLOY_KEY=$(sudo -u aap1-user cat /home/aap1-user/.ssh/eda_project_deploy_key)
  SCM_CRED_ID=$(DEPLOY_KEY="$DEPLOY_KEY" SCM_CRED_TYPE_ID="$SCM_CRED_TYPE_ID" python3 -c "
import json, os
print(json.dumps({'name': 'Self-hosted repo deploy key (Controller)', 'organization': 1, 'credential_type': int(os.environ['SCM_CRED_TYPE_ID']), 'inputs': {'ssh_key_data': os.environ['DEPLOY_KEY']}}))
" | curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/credentials/" -H "Content-Type: application/json" -d @- \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
fi

PROJECT_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/projects/?name=Vulnerability%20Package%20Finder" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$(curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/projects/" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"Vulnerability Package Finder\", \"organization\": 1, \"scm_type\": \"git\", \"scm_url\": \"ssh://aap1-user@localhost/home/aap1-user/git/vulnerability-remediation.git\", \"credential\": $SCM_CRED_ID}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
fi
curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/projects/$PROJECT_ID/update/" > /dev/null
sleep 15

INVENTORY_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/inventories/?page_size=1" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['id'])")

JT_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/job_templates/?name=Vulnerability%20Package%20Finder%20and%20Remediator" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
if [ -z "$JT_ID" ]; then
  JT_ID=$(curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/job_templates/" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"Vulnerability Package Finder and Remediator\", \"job_type\": \"run\", \"inventory\": $INVENTORY_ID, \"project\": $PROJECT_ID, \"playbook\": \"find_and_remediate.yml\", \"execution_environment\": $EE_ID, \"ask_variables_on_launch\": true}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
fi
curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/job_templates/$JT_ID/credentials/" -H "Content-Type: application/json" -d "{\"id\": $CRED_ID}" > /dev/null

CTRL_CRED_TYPE_ID=$(curl -sk -u "$EDA_AUTH" "$EDA_API/credential-types/?name=Red%20Hat%20Ansible%20Automation%20Platform" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
CTRL_CRED_ID=$(curl -sk -u "$EDA_AUTH" "$EDA_API/eda-credentials/?name=AAP%20Controller" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
if [ -z "$CTRL_CRED_ID" ]; then
  CTRL_CRED_ID=$(CTRL_CRED_TYPE_ID="$CTRL_CRED_TYPE_ID" python3 -c "
import json, os
print(json.dumps({'name': 'AAP Controller', 'credential_type_id': int(os.environ['CTRL_CRED_TYPE_ID']), 'organization_id': 1, 'inputs': {'host': 'https://localhost/api/controller/', 'username': 'admin', 'password': 'bc31c9a6-9ff0-11ec-9587-00155d1b0702', 'verify_ssl': False}}))
" | curl -sk -u "$EDA_AUTH" -X POST "$EDA_API/eda-credentials/" -H "Content-Type: application/json" -d @- \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
fi

sudo -u aap1-user bash -c '
cd ~/satellite-webhook
cat > rulebooks/satellite-webhook.yml <<RBEOF
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
RBEOF
git add rulebooks/satellite-webhook.yml
git commit -m "Launch the vulnerability finder/remediator job template on success" || true
GIT_SSH_COMMAND="ssh -i ~/.ssh/eda_project_deploy_key -o IdentitiesOnly=yes" git push aap main
'

PROJECT_ID2=$(curl -sk -u "$EDA_AUTH" "$EDA_API/projects/?name=Satellite%20Webhook%20Rulebooks" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['id'])")
curl -sk -u "$EDA_AUTH" -X POST "$EDA_API/projects/$PROJECT_ID2/sync/" \
  -H "Content-Type: application/json" -d '{"name": "Satellite Webhook Rulebooks"}' > /dev/null
sleep 10

RULEBOOK_ID=$(curl -sk -u "$EDA_AUTH" "$EDA_API/rulebooks/?project_id=$PROJECT_ID2" \
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
REMOTE_EOF

# Trigger a job on rhel1.lab to fire the whole pipeline
hammer job-invocation create \
  --job-template "Run Command - Ansible Default" \
  --search-query "name = rhel1.lab" \
  --inputs "command=echo trigger-remediation"

echo "Solved module-03" >> /tmp/progress.log
