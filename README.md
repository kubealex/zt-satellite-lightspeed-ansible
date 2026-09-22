# zt-satellite-lightspeed-ansible

Index of the Ansible playbooks and scripts referenced by name in this lab's
modules ([content/modules/ROOT/pages/](content/modules/ROOT/pages/)), grouped
by the module and step that uses each one.

## Module 3 - Configure the Satellite Webhook

| File | Step | Purpose |
| --- | --- | --- |
| [setup-automation/files-satellite/create-webhook-template.yml](setup-automation/files-satellite/create-webhook-template.yml) | Step 1 | Registers a custom JSON webhook template with Satellite (its two built-in templates for this event either error out or emit non-JSON). |
| [setup-automation/files-satellite/satellite-remote-execution-host-job-json.erb](setup-automation/files-satellite/satellite-remote-execution-host-job-json.erb) | Step 1 | The ERB template body itself. Not run directly; read by `create-webhook-template.yml` and POSTed to Satellite as the webhook template. |
| [setup-automation/files-satellite/create-webhook.yml](setup-automation/files-satellite/create-webhook.yml) | Step 2 | Fetches the Basic Auth secret and the Event Stream's live URL from `aap1.lab`, then creates the Satellite webhook that points at it. |
| [setup-automation/files-aap1/verify-webhook.yml](setup-automation/files-aap1/verify-webhook.yml) | Step 3 | Read-only. Reports the Event Stream's `events_received` counter and the Activation's own log tail, to confirm the pipeline actually fired. |

## Module 4 - Close the Loop: Automatically Remediate Found CVEs

| File | Step | Purpose |
| --- | --- | --- |
| [setup-automation/files-aap1/Containerfile](setup-automation/files-aap1/Containerfile) | Step 1 | Custom Execution Environment: adds `uv` on top of AAP's supported base EE image. |
| [setup-automation/files-aap1/find_and_remediate.yml](setup-automation/files-aap1/find_and_remediate.yml) | Step 1 | The Job Template's own playbook. Runs `vulnerability_remediation.py` unscoped to discover every host with an installable remediation, re-runs it per host to get exact packages, then installs them via `ansible.builtin.dnf` on every affected host (fleet-wide, not just whichever host fired the webhook). |
| [setup-automation/files-aap1/vulnerability_remediation.py](setup-automation/files-aap1/vulnerability_remediation.py) | Step 1 | Logs in to Satellite, queries the on-premises Red Hat Lightspeed Vulnerability API for CVEs and the Katello content API for the errata/packages that fix them. With `--host`, narrows that down to exactly what one host needs. |
| [setup-automation/files-aap1/create-satellite-credential.yml](setup-automation/files-aap1/create-satellite-credential.yml) | Step 2 | Creates the Controller credential type + credential that injects Satellite admin credentials into the Job Template, so the rulebook never has to know them. |
| [setup-automation/files-aap1/create-controller-project.yml](setup-automation/files-aap1/create-controller-project.yml) | Step 3 | Creates the SCM credential (reusing Module 3's deploy key), the Controller Project pointing at the self-hosted `vulnerability-remediation` repo, and the Job Template (with the custom EE, and both the Satellite and Machine credentials attached). |
| [setup-automation/files-aap1/wire-rulebook.yml](setup-automation/files-aap1/wire-rulebook.yml) | Step 4 | Creates the AAP Controller credential in EDA, publishes the updated rulebook to the self-hosted repo, resyncs the EDA Project, and recreates the Activation. |
