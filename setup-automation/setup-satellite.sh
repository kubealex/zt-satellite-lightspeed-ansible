#!/bin/bash

# Unregister Satellite server from itself.
subscription-manager unregister

# Delete Satellite from its inventory.
hammer host delete --name satellite.lab

# Delete the key this script creates below. `hammer activation-key
# create` rejects a duplicate name, so this keeps re-provisioning
# idempotent.
hammer activation-key delete --name "RHEL10" --organization "Acme Org" || true

# Module 3 creates these two, and hammer rejects duplicate names here
# too. Delete the webhook first. It references the template.
hammer webhook delete --name "AAP Event Driven Ansible Webhook" || true
hammer webhook-template delete --name "Satellite Remote Execution Host Job JSON" || true

# Get the latest CVE map from Red Hat and copy it to the Foreman directory so that it can be used by the Foreman CVE plugin to determine which CVEs are applicable to the registered hosts.
curl -o cvemap.xml https://security.access.redhat.com/data/meta/v1/cvemap.xml
cp cvemap.xml /var/lib/foreman/

# The rest of this script builds the lab environment. It registers the
# two RHEL hosts, installs the deliberately vulnerable packages, and
# uploads an initial insights report.

# Create an Activation Key for RHEL 10 content, which will be used by the RHEL 10 client system to register to Satellite and receive the RHEL 10 content.
hammer activation-key create --name "RHEL10" --organization "Acme Org" --lifecycle-environment "Library" --content-view "Default Organization View"

# Create a host registration script.
SAT_HOST_REGISTRATION_SCRIPT=$(hammer host-registration generate-command \
  --organization "Acme Org" \
  --location "Vancouver" \
  --activation-keys "RHEL10" \
  --insecure true \
  --force true \
  --setup-insights true \
  --setup-remote-execution true)

ssh root@rhel1.lab bash -c "$SAT_HOST_REGISTRATION_SCRIPT"
ssh root@rhel2.lab bash -c "$SAT_HOST_REGISTRATION_SCRIPT"

# Trigger vulnerability - install packages with known CVEs
# openssl-3.5.1-4.el10_1 is vulnerable to RHSA-2026:1472 (CVE-2025-11187, CVE-2025-15467, CVE-2025-15468, CVE-2026-22795, CVE-2026-22796)
ssh root@rhel1.lab "dnf install -y openssl-3.5.1-4.el10_1 openssl-libs-3.5.1-4.el10_1 --allowerasing 2>/dev/null || true"

ssh root@rhel2.lab "dnf install -y openssl-3.5.1-4.el10_1 openssl-libs-3.5.1-4.el10_1 --allowerasing 2>/dev/null || true"
ssh root@rhel2.lab "dnf downgrade -y vim-minimal vim-common 2>/dev/null || true"

# Trigger vulnerability - downgrade packages with known CVEs
ssh root@rhel1.lab "dnf downgrade -y gnutls 2>/dev/null || true"
ssh root@rhel1.lab "dnf install -y tar-1.35-8.el10_1 --allowerasing 2>/dev/null || dnf downgrade -y tar 2>/dev/null || true"

# upload insights data
ssh root@rhel1.lab "insights-client"
ssh root@rhel2.lab "insights-client"