#!/bin/sh
echo "Solving module-05" >> /tmp/progress.log

# This module genuinely spans three hosts (rhel1.lab, satellite.lab,
# aap1.lab) with a STRICT ORDER that matters: check rhel1 -> trigger on
# satellite -> poll aap1 -> check rhel1 again. runtime-automation/main.yml
# runs every host's solve-{host}.sh for a module in parallel (there's no
# built-in cross-host sequencing), so splitting this into separate
# solve-rhel1.sh/solve-satellite.sh/solve-aap1.sh files would NOT
# preserve that ordering - they'd all fire at once, and rhel1's "before"
# check could easily run after the job already remediated it. Keeping
# the whole sequence in one script (hopping to the other hosts via ssh)
# is intentional here, unlike Module 4 (which has no such ordering
# dependency and is correctly a single native solve-aap1.sh instead).
#
# Step 1: check the deliberately-vulnerable package versions on rhel1.lab
# before triggering anything.
ssh -o StrictHostKeyChecking=no root@rhel1.lab \
  "rpm -q openssl openssl-libs libvpx gnutls tar" >> /tmp/progress.log 2>&1

# Step 2: trigger a remote execution job on Satellite - this is what
# fires the webhook wired up in Module 3/4.
hammer job-invocation create \
  --job-template "Run Command - Ansible Default" \
  --search-query "name = rhel1.lab" \
  --inputs "command=echo trigger-remediation"

# Step 3: watch the "Vulnerability Package Finder and Remediator" Job
# Template (launched automatically by the rulebook) start and finish.
ssh -o StrictHostKeyChecking=no root@aap1.lab /bin/bash <<'REMOTE_EOF'
set -e
export CTRL_API="https://localhost/api/controller/v2"
export CTRL_AUTH="admin:bc31c9a6-9ff0-11ec-9587-00155d1b0702"

JOB=""
for i in $(seq 1 30); do
  JOB=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/jobs/?job_template__name=Vulnerability%20Package%20Finder%20and%20Remediator&order_by=-id&page_size=1" \
    | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(json.dumps(r[0]) if r else '')")
  if [ -n "$JOB" ]; then
    STATUS=$(echo "$JOB" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
    echo "status=$STATUS"
    [ "$STATUS" = "successful" ] && break
    [ "$STATUS" = "failed" ] && { echo "$JOB" | python3 -m json.tool; break; }
  fi
  sleep 3
done
JOB_ID=$(echo "$JOB" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
curl -sk -u "$CTRL_AUTH" "$CTRL_API/jobs/$JOB_ID/stdout/?format=txt" | tail -60
REMOTE_EOF

# Step 4: confirm the packages were actually upgraded on rhel1.lab.
ssh -o StrictHostKeyChecking=no root@rhel1.lab \
  "rpm -q openssl openssl-libs libvpx gnutls tar" >> /tmp/progress.log 2>&1

echo "Solved module-05" >> /tmp/progress.log
