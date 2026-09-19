#!/bin/sh
echo "Solving module-02" >> /tmp/progress.log

# Pull the Event Stream URL + Basic Auth credentials that
# setup-automation/setup-aap1.sh already generated on aap1.lab.
EDA_SECRET=$(ssh -o StrictHostKeyChecking=no aap1-user@aap1.lab "cat ~/.eda_webhook_basic_auth.json")
EVENT_STREAM_URL=$(echo "$EDA_SECRET" | python3 -c "import sys,json;print(json.load(sys.stdin)['event_stream_url'])")
WEBHOOK_USER=$(echo "$EDA_SECRET" | python3 -c "import sys,json;print(json.load(sys.stdin)['username'])")
WEBHOOK_PASS=$(echo "$EDA_SECRET" | python3 -c "import sys,json;print(json.load(sys.stdin)['password'])")

# Create the custom JSON webhook template. Satellite's built-in
# templates don't work for this event type: "Webhook Template - Payload
# Default" throws undefined method '#id', and "Remote Execution Host
# Job" only emits human-readable comments, not JSON.
cat > /tmp/satellite-remote-execution-host-job-json.erb <<'EOF'
<%#
name: Satellite Remote Execution Host Job JSON
description: JSON payload for actions.remote_execution.run_host_job_succeeded.event.foreman
snippet: false
model: WebhookTemplate
-%>
<%=
payload({
  host_name: @object.host_name,
  host_id: @object.host_id,
  job_invocation_id: @object.job_invocation_id,
  task_label: @object.task.label,
  task_state: @object.task.state,
  task_result: @object.task.result,
  task_started_at: @object.task.started_at,
  task_ended_at: @object.task.ended_at
})
-%>
EOF

hammer webhook-template create \
  --name "Satellite Remote Execution Host Job JSON" \
  --file /tmp/satellite-remote-execution-host-job-json.erb \
  --snippet false

# Create the webhook itself, pointing at aap1's EDA Event Stream.
# NOTE: the --event value has no ".event.foreman" suffix on input, even
# though `hammer webhook info` displays it with that suffix afterward.
hammer webhook create \
  --name "AAP Event Driven Ansible Webhook" \
  --target-url "$EVENT_STREAM_URL" \
  --http-method POST \
  --http-content-type "application/json" \
  --event "actions.remote_execution.run_host_job_succeeded" \
  --webhook-template "Satellite Remote Execution Host Job JSON" \
  --user "$WEBHOOK_USER" \
  --password "$WEBHOOK_PASS" \
  --verify-ssl false \
  --enabled true

# Trigger a remote execution job so the webhook actually fires once, to
# verify the pipeline end-to-end.
hammer job-invocation create \
  --job-template "Run Command - Ansible Default" \
  --search-query "name = rhel1.lab" \
  --inputs "command=echo webhook-test"

echo "Solved module-02" >> /tmp/progress.log
