#!/bin/sh
echo "Solving module-03" >> /tmp/progress.log

# This module's real work (creating the webhook template and webhook)
# only makes sense on satellite.lab, so solve-satellite.sh is correct
# here - there's no corresponding solve-aap1.sh because nothing needs to
# be CREATED on aap1.lab in this module (that already happened in
# setup-automation/setup-aap1.sh).
set -e

# Steps 1 and 2 of module-03.adoc (the custom JSON webhook template, and
# the webhook pointing at aap1's EDA Event Stream) are exactly what
# these two playbooks do - setup-automation/setup-satellite.sh already
# pre-populated them under /root (self-contained and idempotent), so
# re-run them here rather than duplicating the same API logic a second
# time in this file.
#
# create-webhook.yml is also where this module's two cross-host lookups
# live: the Basic Auth secret file and the Event Stream's current URL,
# both read from aap1.lab. satellite.lab needs them to build its own
# webhook, and there's no shared filesystem between hosts to pass that
# data any other way.
ansible-playbook /root/create-webhook-template.yml
ansible-playbook /root/create-webhook.yml

# Trigger a remote execution job so the webhook actually fires once, to
# verify the pipeline end-to-end.
hammer job-invocation create \
  --job-template "Run Command - Ansible Default" \
  --search-query "name = rhel1.lab" \
  --inputs "command=echo webhook-test"

echo "Solved module-03" >> /tmp/progress.log
