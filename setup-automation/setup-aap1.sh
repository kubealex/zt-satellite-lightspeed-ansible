#!/bin/bash

# This script runs as root on aap1 (via setup-automation/main.yml). AAP
# itself, and the aap1-user OS account, are already baked into the
# aap1-* golden image - this script wires up the Satellite -> EDA
# webhook pipeline (self-hosted rulebook repo, EDA credentials,
# Project, Event Stream, Activation), the registry.redhat.io pre-auth
# and vulnerability-remediation repo Module 4 needs, and the two
# scripts Module 4's Steps 4/5 walk the participant through running.
# Idempotent: every step here is safe to run again on every
# (re)provision.
#
# See docs/EDA_WEBHOOK_SETUP.md for the full manual/CLI walkthrough this
# script automates, including troubleshooting notes.

# The large payloads this script installs (the vulnerability finder, the
# remediation playbook, the Containerfile, and Module 4's two /root
# helper scripts) ship alongside it as real files, in
# setup-automation/files-aap1/, copied here by setup-automation/main.yml.
#
# This script has no `set -e`, so a missing payload would fail silently
# and we would go on to git-commit and push a repo with files missing.
# Module 4 would then hand the participant a broken
# ~/vulnerability-remediation. Fail up front, before anything on this
# host has been touched.
PAYLOAD_DIR=/tmp/setup-scripts/files-aap1
for _f in setup-as-aap1-user.sh \
          Containerfile find_and_remediate.yml vulnerability_remediation.py \
          create-controller-project.sh wire-rulebook.sh; do
  if [ ! -s "$PAYLOAD_DIR/$_f" ]; then
    echo "==> SETUP-AAP1: FAILED - missing or empty payload $PAYLOAD_DIR/$_f" >&2
    exit 1
  fi
  # The test above runs as root, which bypasses permission bits, so it
  # cannot catch the case that matters: a payload delivered unreadable
  # to aap1-user, who consumes three of these inside the sudo block
  # below. Checking as that user covers the file mode and traversal on
  # every parent directory at once.
  if ! sudo -u aap1-user test -r "$PAYLOAD_DIR/$_f"; then
    echo "==> SETUP-AAP1: FAILED - $PAYLOAD_DIR/$_f not readable by aap1-user" >&2
    exit 1
  fi
done
unset _f

systemctl stop dnf-automatic-install.timer
systemctl disable dnf-automatic-install.timer
systemctl mask dnf-automatic-install.timer

systemctl stop dnf-automatic.timer
systemctl disable dnf-automatic.timer

sed -i 's/^apply_updates.*/apply_updates = no/' /etc/dnf/automatic.conf
sed -i 's/^download_updates.*/download_updates = no/' /etc/dnf/automatic.conf

# AAP application admin password from the aap1-* golden image, not the
# aap1-user OS account password. It matches Satellite's admin password.
#
# Changing it here is not enough. The same literal is hardcoded in
# files-aap1/create-controller-project.sh, files-aap1/wire-rulebook.sh,
# the module .adocs, and the solve scripts, none of which can reference
# this variable.
AAP_ADMIN_PASSWORD="bc31c9a6-9ff0-11ec-9587-00155d1b0702"

# Pre-authenticate root's podman against registry.redhat.io so Module 4
# (Step 2, building the custom Execution Environment) never has to ask
# the participant for their own Red Hat registry credentials by hand.
# REGISTRY_PULL_TOKEN is the full base64 "auth" value from a registry
# service account (username and password already combined), passed
# through by setup-automation/main.yml.
#
# Write the credential directly to root's DEFAULT podman auth file
# ($HOME/.config/containers/auth.json, i.e. /root/.config/containers/
# auth.json - this is what podman falls back to when $XDG_RUNTIME_DIR
# isn't set, which is the common case for a non-interactive root shell).
# An earlier version of this wrote to a /tmp file, pointed `podman
# login --authfile` at that SAME /tmp file, then deleted it - so the
# credential never reached podman's real default location at all and
# every later `podman build`/`pull` as root still prompted for auth.
# Also set REGISTRY_AUTH_FILE in /root/.bashrc as a second, explicit
# guarantee that works even if some other login shell's $XDG_RUNTIME_DIR
# happens to be set and would otherwise take precedence.
# Declare aap1.lab itself as an insecure registry (HTTPS with
# certificate verification skipped) in registries.conf.d, rather than
# relying solely on the one-off `podman push/build --tls-verify=false`
# CLI flag. Without this, some internal podman operations (e.g. the
# cross-repository blob-reuse ping that happens on push) don't reliably
# honor that per-command flag and fall back to plain HTTP on port 80
# instead, which nothing listens on ("connect: connection refused"),
# even though the actual registry (served over HTTPS on 443 by envoy)
# works fine.
mkdir -p /etc/containers/registries.conf.d
cat > /etc/containers/registries.conf.d/aap1-insecure.conf <<'EOF'
[[registry]]
location = "aap1.lab"
insecure = true
EOF

if [ -n "${REGISTRY_PULL_TOKEN:-}" ]; then
  mkdir -p /root/.config/containers
  cat > /root/.config/containers/auth.json <<EOF
{
  "auths": {
    "registry.redhat.io": {
      "auth": "${REGISTRY_PULL_TOKEN}"
    }
  }
}
EOF
  if ! grep -q "^export REGISTRY_AUTH_FILE=" /root/.bashrc 2>/dev/null; then
    echo 'export REGISTRY_AUTH_FILE=/root/.config/containers/auth.json' >> /root/.bashrc
  fi
fi

# Passwordless root-to-root SSH between the lab's hosts is already baked
# into the golden images (e.g. satellite.lab's root can already SSH into
# aap1.lab's root with no password) - but aap1-user is a separate OS
# account on the aap1 image, so it never inherited that same trust.
# Module 3's solve script (and its Step 1/3 instructions) need
# satellite.lab's root to SSH into aap1-user@aap1.lab with no password
# prompt, so copy whatever key(s) already let root in, into aap1-user's
# authorized_keys too. This is idempotent: re-running just re-appends
# any keys not already present.
if [ -f /root/.ssh/authorized_keys ]; then
  install -d -m 700 -o aap1-user -g aap1-user /home/aap1-user/.ssh
  touch /home/aap1-user/.ssh/authorized_keys
  comm -23 \
    <(sort -u /root/.ssh/authorized_keys) \
    <(sort -u /home/aap1-user/.ssh/authorized_keys) \
    >> /home/aap1-user/.ssh/authorized_keys
  chmod 600 /home/aap1-user/.ssh/authorized_keys
  chown aap1-user:aap1-user /home/aap1-user/.ssh/authorized_keys
fi

# Everything below runs as aap1-user, since the self-hosted git repo,
# deploy key, and EDA API calls (as aap1-user's own SSH session) all
# assume that user's $HOME. --preserve-env carries AAP_ADMIN_PASSWORD
# through to the sudo'd shell; the heredoc itself is single-quoted so
# none of its own $(...) / $VAR usage is touched by the outer shell.
export AAP_ADMIN_PASSWORD
sudo -u aap1-user --preserve-env=AAP_ADMIN_PASSWORD -H \
  bash "$PAYLOAD_DIR/setup-as-aap1-user.sh" "$PAYLOAD_DIR"

# Building and registering a custom Execution Environment is a routine
# AAP administration task, not something this lab is trying to teach,
# so it happens here during setup instead of as a participant step in
# Module 4. The aap1-* golden image normally already has
# aap1.lab/ee-vuln-finder:latest built and cached in local podman
# storage (baked in ahead of time), so the build step below is only a
# fallback for an older image that predates that, skipped entirely
# when the image is already present.
cd /home/aap1-user/vulnerability-remediation
if ! podman image exists aap1.lab/ee-vuln-finder:latest; then
  podman build -t ee-vuln-finder -f Containerfile .
  podman tag ee-vuln-finder:latest aap1.lab/ee-vuln-finder:latest
fi
podman login --tls-verify=false -u admin -p "$AAP_ADMIN_PASSWORD" aap1.lab
podman push --tls-verify=false aap1.lab/ee-vuln-finder:latest

# Controller runs containerized/rootless as aap1-user, and launches every
# job/project-sync Execution Environment via podman with slirp4netns
# networking (DEFAULT_CONTAINER_RUN_OPTIONS in controller/etc/settings.py).
# slirp4netns's default subnet (10.0.2.0/24) both collides with aap1's real
# enp1s0 address AND, without allow_host_loopback=true, blocks the EE from
# reaching this host's sshd at all. That matters because Module 4's
# Controller Project pulls the self-hosted vulnerability-remediation git
# repo over ssh to aap1's own sshd (via podman's host.containers.internal
# alias). Enable allow_host_loopback so that project sync can succeed, then
# restart the controller-task service so it picks up the change. Idempotent.
CTRL_SETTINGS=/home/aap1-user/aap/controller/etc/settings.py
if [ -f "$CTRL_SETTINGS" ] && ! grep -q 'allow_host_loopback=true' "$CTRL_SETTINGS"; then
  sed -i 's/slirp4netns:enable_ipv6=true"/slirp4netns:enable_ipv6=true,allow_host_loopback=true"/' "$CTRL_SETTINGS"
  chown aap1-user:aap1-user "$CTRL_SETTINGS"
  sudo -iu aap1-user env XDG_RUNTIME_DIR=/run/user/$(id -u aap1-user) \
    systemctl --user restart automation-controller-task.service || true
  # Give the task container a moment to come back before we hit the API.
  for i in $(seq 1 30); do
    curl -sk -o /dev/null -u "admin:$AAP_ADMIN_PASSWORD" \
      "https://localhost/api/controller/v2/ping/" && break
    sleep 2
  done
fi

export CTRL_API="https://localhost/api/controller/v2"
export CTRL_AUTH="admin:$AAP_ADMIN_PASSWORD"
EE_ID=$(curl -sk -u "$CTRL_AUTH" "$CTRL_API/execution_environments/?name=Vulnerability%20Finder%20EE" \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['id'] if r else '')")
if [ -z "$EE_ID" ]; then
  EE_ID=$(curl -sk -u "$CTRL_AUTH" -X POST "$CTRL_API/execution_environments/" \
    -H "Content-Type: application/json" \
    -d '{"name": "Vulnerability Finder EE", "image": "aap1.lab/ee-vuln-finder:latest", "pull": "missing"}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
fi
echo "EE_ID=$EE_ID"

# Pre-populate the two scripts Module 4 (Steps 3 and 4) walks the
# participant through running. Both are fully self-contained and
# idempotent (same "look it up by name, create if missing" pattern used
# throughout this file), so they don't depend on any shell variables
# from earlier steps in the participant's own terminal session - only
# on resources that already exist by the time each step runs. Writing
# these here (rather than having the participant paste large heredocs
# that write intermediate helper files, e.g. a Python payload builder
# or the rulebook YAML, by hand) removes that copy/paste risk the same
# way Step 1's Containerfile/find_and_remediate.yml/
# vulnerability_remediation.py pre-population already does - Module 4
# only explains what each script does and runs it, it never creates one
# from scratch in front of the participant.
cp "$PAYLOAD_DIR/create-controller-project.sh" /root/create-controller-project.sh
chmod +x /root/create-controller-project.sh

cp "$PAYLOAD_DIR/wire-rulebook.sh" /root/wire-rulebook.sh
chmod +x /root/wire-rulebook.sh
