#!/bin/sh
echo "Solving module-04" >> /tmp/progress.log

# This entire module runs natively on aap1.lab (no satellite.lab action
# needed at all - Controller Project/Job Template, EDA credential, and
# the rulebook/Activation update are all aap1-side).
# runtime-automation/main.yml already runs this file directly as root on
# aap1 (it's in the "aap1" node loop), so no SSH hop is needed here,
# unlike module-03 (Configure the Satellite Webhook), which runs on
# satellite.lab and reaches over to aap1.lab for two read-only lookups.
#
# vulnerability_remediation.py itself (a custom script that queries
# Satellite's on-premises Red Hat Lightspeed Vulnerability service for
# CVEs and cross-references its Katello errata API for fixes) was
# already pre-populated by setup-automation/setup-aap1.sh.
set -e

# The vulnerability-remediation repo (Containerfile, find_and_remediate.yml,
# vulnerability_remediation.py) was already self-hosted on aap1.lab by
# setup-automation/setup-aap1.sh during provisioning - just verify it is
# there rather than re-creating it.
sudo -u aap1-user test -f /home/aap1-user/vulnerability-remediation/vulnerability_remediation.py

# The custom EE was already built, pushed, and registered with
# Controller by setup-automation/setup-aap1.sh (either pre-baked into
# the aap1-* golden image, or built there as a fallback) - nothing to
# do here for it.

# Steps 2, 3 and 4 of module-04.adoc (the Satellite API credential type
# and credential; the Controller Project/Job Template; the EDA
# Controller credential, rulebook update and Activation recreation) are
# exactly what these three playbooks do - setup-automation/setup-aap1.sh
# already pre-populated them under /root (self-contained and
# idempotent), so re-run them here too rather than duplicating ~170
# lines of the same API logic a second time in this file.
ansible-playbook /root/create-satellite-credential.yml
ansible-playbook /root/create-controller-project.yml
ansible-playbook /root/wire-rulebook.yml

echo "Solved module-04" >> /tmp/progress.log
