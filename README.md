# zt-satellite-lightspeed-ansible

A Showroom/Antora lab that demonstrates a closed-loop vulnerability remediation
pipeline: Red Hat Satellite's on-premises Red Hat Lightspeed Vulnerability
service finds CVEs, a Satellite webhook notifies AAP's Event-Driven Ansible
(EDA) whenever a remote execution job succeeds, and EDA launches a Controller
Job Template that finds and installs the fixed RPMs across every affected
host.

This document indexes every Ansible playbook and shell script in the repo,
and explains how they fit together, so the pattern is easy to reuse for a
different lab.

## Lab environment

Four VMs, defined in [config/instances.yaml](config/instances.yaml):

| VM | Role |
| --- | --- |
| `satellite.lab` | Red Hat Satellite. Content, remote execution, webhooks, and the on-premises Lightspeed Vulnerability service. |
| `aap1.lab` | Ansible Automation Platform: Controller, EDA, and Hub (the private container registry the custom Execution Environment is pushed to). |
| `rhel1.lab`, `rhel2.lab` | Managed content hosts, seeded with deliberately vulnerable packages so there are real CVEs to find and fix. |

## How provisioning works

Two separate Ansible-runner invocations drive this lab, both defined at the
repo root:

- **[setup-automation/main.yml](setup-automation/main.yml)** runs once, when
  the lab is first provisioned. For each host, it copies over
  `setup-automation/setup-<host>.sh` (if one exists) plus that host's payload
  directory `setup-automation/files-<host>/` (if one exists), then runs the
  script as root. This is where every AAP/EDA/Satellite object the lab needs
  gets created, so the participant-facing modules only have to explain and
  run things, never build them from scratch.
- **[runtime-automation/main.yml](runtime-automation/main.yml)** runs once per
  module, per host, whenever the lab platform triggers a given
  `module_stage` (in this repo, always `solve`) for a given module directory.
  It copies over and runs `<module_dir>/<module_stage>-<host>.sh` if one
  exists. These scripts are the automated, non-interactive equivalent of
  whatever the module's own instructions ask the participant to do, used to
  validate that the module's content actually works end to end.

Both entry points are silent no-ops for any host/module combination that has
no matching script, so a lab-wide re-run is always safe.

## setup-automation: provisioning scripts

| Script | Host | What it does |
| --- | --- | --- |
| [setup-automation/setup-satellite.sh](setup-automation/setup-satellite.sh) | `satellite.lab` | Resets Satellite to a clean slate, syncs the Red Hat CVE map, registers `rhel1.lab`/`rhel2.lab`, seeds them with deliberately vulnerable packages, uploads an initial Insights report, and pre-populates the two Module 3 playbooks below into `/root/`. |
| [setup-automation/setup-aap1.sh](setup-automation/setup-aap1.sh) | `aap1.lab` | Disables `dnf-automatic`, pre-authenticates `podman` against `registry.redhat.io` and declares `aap1.lab` an insecure (self-signed) registry, copies root's SSH trust into `aap1-user`, runs [setup-as-aap1-user.sh](setup-automation/files-aap1/setup-as-aap1-user.sh) (below) as `aap1-user`, builds/pushes/registers the custom Execution Environment, patches Controller's `slirp4netns` networking so its job containers can reach `aap1.lab`'s own `sshd`, and pre-populates the Module 4 playbooks below into `/root/`. |
| [setup-automation/setup-rhel1.sh](setup-automation/setup-rhel1.sh), [setup-rhel2.sh](setup-automation/setup-rhel2.sh) | `rhel1.lab`, `rhel2.lab` | Minimal: remove `tmux`, disable `dnf-automatic`. |
| [setup-automation/files-aap1/setup-as-aap1-user.sh](setup-automation/files-aap1/setup-as-aap1-user.sh) | `aap1.lab` (as `aap1-user`) | Creates the self-hosted `satellite-webhook` git repo and its deploy key; creates the EDA Source Control credential, Project, Basic Auth credential, Event Stream, and Rulebook Activation (all idempotent, looked up by name); creates the self-hosted `vulnerability-remediation` git repo and pushes the three files below into it. |

### setup-automation/files-aap1/ (copied to aap1.lab)

| File | Type | Purpose |
| --- | --- | --- |
| [setup-as-aap1-user.sh](setup-automation/files-aap1/setup-as-aap1-user.sh) | shell | See table above. |
| [Containerfile](setup-automation/files-aap1/Containerfile) | Containerfile | Custom Execution Environment: adds `uv` on top of AAP's supported base EE image. |
| [find_and_remediate.yml](setup-automation/files-aap1/find_and_remediate.yml) | playbook | The Job Template's own playbook. Runs `vulnerability_remediation.py` unscoped to discover every host with an installable remediation, re-runs it per host to get exact packages, then installs them via `ansible.builtin.dnf` on every affected host (fleet-wide, not just whichever host fired the webhook). |
| [vulnerability_remediation.py](setup-automation/files-aap1/vulnerability_remediation.py) | Python script | Logs in to Satellite, queries the on-premises Red Hat Lightspeed Vulnerability API for CVEs and the Katello content API for the errata/packages that fix them. With `--host`, narrows that down to exactly what one host needs. |
| [create-satellite-credential.yml](setup-automation/files-aap1/create-satellite-credential.yml) | playbook | Module 4 Step 2. Creates the Controller credential type + credential that injects Satellite admin credentials into the Job Template, so the rulebook never has to know them. |
| [create-controller-project.yml](setup-automation/files-aap1/create-controller-project.yml) | playbook | Module 4 Step 3. Creates the SCM credential (reusing Module 3's deploy key), the Controller Project pointing at the self-hosted repo, and the Job Template (with the custom EE, and both the Satellite and Machine credentials attached). |
| [wire-rulebook.yml](setup-automation/files-aap1/wire-rulebook.yml) | playbook | Module 4 Step 4. Creates the AAP Controller credential in EDA, publishes the updated rulebook (below) to the self-hosted repo, resyncs the EDA Project, and recreates the Activation. |
| [satellite-webhook-rulebook.yml](setup-automation/files-aap1/satellite-webhook-rulebook.yml) | rulebook | Not run directly. Copied into the self-hosted repo by `wire-rulebook.yml`. On a successful remote execution job, logs the event and launches the remediation Job Template, both as actions of one rule (ansible-rulebook fires only the first matching rule per event). |
| [verify-webhook.yml](setup-automation/files-aap1/verify-webhook.yml) | playbook | Module 3 Step 3. Read-only: reports the Event Stream's `events_received` counter and the Activation's own log tail, to confirm the pipeline actually fired. |

### setup-automation/files-satellite/ (copied to satellite.lab)

| File | Type | Purpose |
| --- | --- | --- |
| [create-webhook-template.yml](setup-automation/files-satellite/create-webhook-template.yml) | playbook | Module 3 Step 1. Registers a custom JSON webhook template with Satellite (its two built-in templates for this event either error out or emit non-JSON). |
| [create-webhook.yml](setup-automation/files-satellite/create-webhook.yml) | playbook | Module 3 Step 2. Fetches the Basic Auth secret and the Event Stream's live URL from `aap1.lab`, then creates the Satellite webhook that points at it. |
| `satellite-remote-execution-host-job-json.erb` | ERB template | Not run directly. Read by `create-webhook-template.yml` and POSTed to Satellite as the webhook template body. |

## runtime-automation: per-module validation scripts

| Script | Module | What it does |
| --- | --- | --- |
| [runtime-automation/module-02/solve-satellite.sh](runtime-automation/module-02/solve-satellite.sh) | Module 2 (Explore Detected CVEs) | Confirms CVE data exists via the Katello errata API. Module 2 is a pure Web UI walkthrough; there's nothing to create. |
| [runtime-automation/module-03/solve-satellite.sh](runtime-automation/module-03/solve-satellite.sh) | Module 3 (Configure the Satellite Webhook) | Runs `create-webhook-template.yml` and `create-webhook.yml`, then triggers a remote execution job so the webhook fires once. |
| [runtime-automation/module-04/solve-aap1.sh](runtime-automation/module-04/solve-aap1.sh) | Module 4 (Close the Loop) | Verifies the pre-populated `vulnerability-remediation` repo and EE, then runs `create-satellite-credential.yml`, `create-controller-project.yml`, and `wire-rulebook.yml`. |
| [runtime-automation/module-05/solve-satellite.sh](runtime-automation/module-05/solve-satellite.sh) | Module 5 (Verify the Closed Loop) | The only one that hops across all three hosts in a strict order (check `rhel1.lab`'s package versions, trigger a job on `satellite.lab`, poll the remediation Job Template on `aap1.lab`, check `rhel1.lab` again), since `runtime-automation` has no built-in cross-host sequencing. |

## Other files worth knowing about

- **[docs/EDA_WEBHOOK_SETUP.md](docs/EDA_WEBHOOK_SETUP.md)** - a manual, raw-API
  CLI walkthrough of everything the playbooks above automate, including
  troubleshooting notes. Point of reference if a call ever needs to be made
  by hand, or if you're porting this pattern somewhere the `ansible.controller`
  / `ansible.eda` collections aren't installed (this lab doesn't use them, on
  purpose - see the next section).
- **[content/modules/ROOT/pages/](content/modules/ROOT/pages/)** - the five
  participant-facing module pages (`module-01.adoc` through `module-05.adoc`),
  in AsciiDoc.
- **[config/instances.yaml](config/instances.yaml)** - VM definitions (image,
  sizing, network routes).
- **[lab-metadata.yml](lab-metadata.yml)**, **[ui-config.yml](ui-config.yml)**,
  **[site.yml](site.yml)** - Showroom/Antora lab metadata, tab/terminal
  configuration, and the Antora site build config, respectively.

## Patterns worth reusing

A few decisions recur across most of the playbooks and scripts above, and are
worth carrying over if you're duplicating this approach for a different
integration:

- **`ansible.builtin.uri` over collection-specific modules.** Every playbook
  here calls Controller/EDA/Satellite's REST APIs directly through
  `ansible.builtin.uri`, rather than `ansible.controller.*`, `ansible.eda.*`,
  or `theforeman.foreman.*`. Those collections aren't guaranteed to be
  installed on the control node they'd need to run on (they ship inside AAP's
  *execution environment* images, not on `aap1.lab`'s own control node
  filesystem), and referencing one in a `module_defaults` block fails at
  parse time, before any task runs, if it's missing. `ansible-core` alone is
  always available.
- **Idempotent by "look up by name, then POST or PATCH".** Nearly every
  object-creating task follows the same shape: look the object up by its
  exact name, then `POST` a new one if it's missing or `PATCH` the existing
  one in place if it's there. A second run always converges rather than
  failing on a duplicate name.
- **Fail loudly and early, not silently deep in a later step.** Most
  playbooks assert their prerequisites (an org, a credential type, a
  project) exist before doing anything, with a `fail_msg` that names the
  exact script that was supposed to create it. Several setup scripts also
  verify their own payload files exist and are readable *before* touching
  anything on the host.
- **Pre-populate files, never have the participant paste them.** Every large
  file a module needs (a Python script, a Containerfile, a playbook) is
  written to the host during provisioning and shipped as a real file in
  `files-<host>/`, not typed inline as a shell heredoc in a module page. The
  module only ever explains and runs it.
- **The one hardcoded password.** `bc31c9a6-9ff0-11ec-9587-00155d1b0702` is
  used as both Satellite's and AAP's admin password throughout this lab, and
  is hardcoded (not templated) in every file listed above that needs it, plus
  the module `.adoc` pages and the `runtime-automation` solve scripts.
  Changing it means finding every occurrence by hand; see the comment above
  `AAP_ADMIN_PASSWORD` in `setup-aap1.sh` for the full list.
- **Container networking is not host networking - expect a different address
  every time.** This was the single biggest source of debugging in this repo.
  Controller's Project sync and Job Template runs happen inside an isolated
  Execution Environment container, not on the host's own network namespace.
  `localhost` and any hostname that's a loopback alias on the host (like
  `aap1.lab` here) resolve to the *container's own* loopback, not the host's.
  The host's real, outward-facing IP can also fail ("Network is unreachable")
  if the host itself is a masqueraded VM one network layer removed from the
  container's bridge. What actually works depends on how that AAP install
  runs its containers - here it's rootless `slirp4netns`, reachable via
  podman's `host.containers.internal` alias, but only because `setup-aap1.sh`
  explicitly enables `allow_host_loopback=true` in Controller's own
  `slirp4netns` options and restarts its task service to pick that up (see
  the comment on `git_host` in `create-controller-project.yml`). If you're
  reusing this pattern against a different AAP install, do not assume any of
  `localhost`, the host's real IP, or podman's default bridge gateway is the
  right answer; check each one against how *that* install actually launches
  its job containers.
