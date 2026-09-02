#!/bin/bash

# Unregister Satellite server from itself.
subscription-manager unregister

# Delete Satellite from its inventory.
hammer host delete --name satellite.lab

# TODO: Delete any activation keys created for this lab, e.g.:
# hammer activation-key delete --name "<Activation Key Name>" --organization "Acme Org"

# Get the latest CVE map from Red Hat and copy it to the Foreman directory so that it can be used by the Foreman CVE plugin to determine which CVEs are applicable to the registered hosts.
curl -o cvemap.xml https://security.access.redhat.com/data/meta/v1/cvemap.xml
cp cvemap.xml /var/lib/foreman/

# TODO: Add any additional lab-specific reset/setup steps here.
