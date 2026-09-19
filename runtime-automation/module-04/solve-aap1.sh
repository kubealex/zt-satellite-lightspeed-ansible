#!/bin/sh
echo "Solving module-04" >> /tmp/progress.log

# This entire module runs natively on aap1.lab (no satellite.lab action
# needed at all - EE build, Controller Project/Job Template, EDA
# credential, and the rulebook/Activation update are all aap1-side).
# runtime-automation/main.yml already runs this file directly as root on
# aap1 (it's in the "aap1" node loop), so no SSH hop is needed here,
# unlike module-03's solve-satellite.sh (Configure the Satellite
# Webhook) which genuinely does need one
# (satellite.lab has its own real work: creating the webhook template
# and webhook).
#
# root's podman was already logged into registry.redhat.io by
# setup-automation/setup-aap1.sh during provisioning, so the base image
# in Containerfile can be pulled here without any credentials of its
# own. vulnerability_remediation.py itself (a custom script that queries
# Satellite's on-premises Red Hat Lightspeed Vulnerability service for
# CVEs and cross-references its Katello errata API for fixes) was also
# already pre-populated by that same setup script.
set -e

# The vulnerability-remediation repo (Containerfile, find_and_remediate.yml,
# vulnerability_remediation.py) was already self-hosted on aap1.lab by
# setup-automation/setup-aap1.sh during provisioning - just verify it is
# there rather than re-creating it.
sudo -u aap1-user test -f /home/aap1-user/vulnerability-remediation/vulnerability_remediation.py

# Build + push the custom EE (assumes registry.redhat.io login already done)
cd /home/aap1-user/vulnerability-remediation
podman build -t ee-vuln-finder -f Containerfile .
podman tag ee-vuln-finder:latest aap1.lab/ee-vuln-finder:latest
podman login --tls-verify=false -u admin -p "bc31c9a6-9ff0-11ec-9587-00155d1b0702" aap1.lab
podman push --tls-verify=false aap1.lab/ee-vuln-finder:latest

export CTRL_API="https://localhost/api/controller/v2"
export CTRL_AUTH="admin:bc31c9a6-9ff0-11ec-9587-00155d1b0702"

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

# Steps 4 and 5 of module-04.adoc (Controller Project/Job Template, EDA
# Controller credential, rulebook update, Activation recreation) are
# exactly what these two scripts do - setup-automation/setup-aap1.sh
# already pre-populated them as /root/*.sh (self-contained and
# idempotent), so re-run them here too rather than duplicating ~150
# lines of the same curl/python3 logic a second time in this file.
/root/create-controller-project.sh
/root/wire-rulebook.sh

echo "Solved module-04" >> /tmp/progress.log
