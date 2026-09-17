# aap1 golden image — required fixes

## Summary

The `aap1-*` golden image (currently `aap1-091626`) has a stale GCP-internal
hostname baked into its AAP 2.7 containerized install. This breaks the
Postgres connection for most AAP components on every boot, and prevents the
gateway from ever binding port 443. This doc describes the root cause and
what needs to change before the next image bake.

## Root cause

The image was originally built/installed on GCP (looks like an Instruqt
environment: `tmm-instruqt-11-26-2021`). The AAP containerized installer's
inventory (`~/aap-install-2.7-8/inventory-growth`, on the `aap-user` account)
uses that GCP-internal hostname as the `inventory_hostname` for every
component group, and as every component's Postgres host:

```ini
[automationgateway]
aap1.us-central1-a.c.tmm-instruqt-11-26-2021.internal

[automationcontroller]
aap1.us-central1-a.c.tmm-instruqt-11-26-2021.internal

...

[all:vars]
gateway_pg_host=aap1.us-central1-a.c.tmm-instruqt-11-26-2021.internal
controller_pg_host=aap1.us-central1-a.c.tmm-instruqt-11-26-2021.internal
hub_pg_host=aap1.us-central1-a.c.tmm-instruqt-11-26-2021.internal
eda_pg_host=aap1.us-central1-a.c.tmm-instruqt-11-26-2021.internal
automationmetrics_pg_host=aap1.us-central1-a.c.tmm-instruqt-11-26-2021.internal
automationmetrics_controller_read_pg_host=aap1.us-central1-a.c.tmm-instruqt-11-26-2021.internal
```

That hostname obviously doesn't resolve once the image is deployed anywhere
else (e.g. our OpenShift/KubeVirt sandboxes). It's baked into podman
**secrets** (`controller_postgres`, `hub_settings`, `eda_*`, gateway/metrics
settings, `receptor.conf`, etc.) — these are read-only, mode-`0400` mounts,
so they can't be patched in a running container; the secret itself has to be
regenerated.

## Symptoms observed

- `automation-controller-web/task/rsyslog`, `automation-hub-api/content/worker-*`
  crash-loop with `psycopg.OperationalError: [Errno -2] Name or service not known`.
- `automation-gateway-proxy` (envoy) never binds port 443 — its control-plane
  discovery cluster (`STRICT_DNS`) also targets the stale hostname on port
  `8446`, and envoy's resolver does **not** consult `/etc/hosts`, so even a
  hosts-file workaround doesn't fix it.
- Separately, `cloud-init-local.service` / `cloud-init.service` /
  `cloud-config.service` fail on every boot with a `network_schema_version`
  `TypeError` — consistent with a GCE-oriented cloud-init image booting under
  KubeVirt's NoCloud datasource. This is likely why the stale hostname was
  never corrected on first boot (whatever re-templating step would normally
  run via cloud-init never gets the chance to).

## Fix applied (live, on the running sandbox VM — not yet baked into the image)

1. In `~/aap-install-2.7-8/inventory-growth`, replaced every occurrence of
   `aap1.us-central1-a.c.tmm-instruqt-11-26-2021.internal` with
   `localhost.localdomain`:
   - The bare hostname under each `[automation*]` / `[database]` group.
   - Every `*_pg_host=` variable.
   - (`ansible_connection=local` is already set, so changing the inventory
     hostname is safe — it's never used to actually SSH anywhere.)
   - Note: a plain `localhost` is **rejected** by the installer's preflight
     check (`Automation Gateway requires an FQDN ... when Automation Hub is
     present`) — it must contain a dot, hence `localhost.localdomain` (which
     already resolves to `127.0.0.1` via `/etc/hosts` on RHEL).
2. Re-ran the official installer from that directory:
   ```bash
   cd ~/aap-install-2.7-8
   ansible-playbook -i inventory-growth ansible.containerized_installer.install
   ```
   This regenerates the podman secrets and recreates every affected
   container — the supported way to do it, vs. hand-editing containers.
3. Manually `podman start`'d `automation-hub-api` / `automation-hub-content`
   once, since they'd already been down long enough that their restart
   policy had given up retrying (only needed because of the earlier
   crash-loop history on this particular already-broken instance — shouldn't
   be needed on a cleanly-booted, fixed image).

Result: all AAP containers stable, `curl https://localhost:443/` → `200`
(served by `envoy`), confirmed working end-to-end through the OpenShift route
after also fixing the route's TLS termination (see companion PR below).

## What developers should do to the golden image

- **Before re-snapshotting `aap1-*`:** either re-run the AAP installer with a
  corrected inventory (no GCP-internal hostname anywhere — use `localhost.localdomain`
  or the lab's real `fqdn`/`hostname` from `instances.yaml`'s cloud-init
  userdata, i.e. `aap1.lab`), or fix the install from scratch on a clean boot
  in the target (KubeVirt) environment so it never has the stale hostname to
  begin with.
- **Cloud-init**: worth investigating/fixing the `network_schema_version`
  crash independently — even though it wasn't the direct blocker here, a
  golden image whose cloud-init reliably fails on every boot is fragile and
  will likely cause other first-boot customization to silently not run in
  the future.
- **TLS cert for the route**: AAP's installer generates a fresh self-signed
  CA/cert for the gateway (`~/aap/tls/ca.cert` as `aap-user`) every time it
  installs. The `zt-satellite-lightspeed-ansible` catalog item's
  `config/instances.yaml` route for `aap1-https` needs `tls_termination: reencrypt`
  plus a `tls_destinationCACertificate` matching whatever CA the *rebuilt*
  image ends up with — see
  [rhpds/zt-satellite-lightspeed-ansible#1](https://github.com/rhpds/zt-satellite-lightspeed-ansible/pull/1)
  for the pattern (mirrors the existing `satellite-https` route). **This
  cert value will need to be re-extracted and updated again** after any
  golden-image rebuild that re-runs the AAP installer.
