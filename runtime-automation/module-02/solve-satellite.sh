#!/bin/sh
echo "Solving module-02" >> /tmp/progress.log

# This module is a pure Satellite Web UI walkthrough (Red Hat Lightspeed
# -> Vulnerability) - there's nothing to change on satellite.lab itself.
# The Lightspeed Vulnerability API only accepts session-cookie auth (the
# same login flow vulnerability_remediation.py uses in Module 4), not
# HTTP Basic Auth, so a simple curl check here isn't representative of
# what the UI page actually shows. Instead, just confirm CVE data exists
# at all via the documented Katello errata API (Basic Auth-friendly),
# which is what ultimately backs the fixes shown on that page.
hammer erratum list --search "severity = Critical or severity = Important" >> /tmp/progress.log 2>&1

echo "Solved module-02" >> /tmp/progress.log
