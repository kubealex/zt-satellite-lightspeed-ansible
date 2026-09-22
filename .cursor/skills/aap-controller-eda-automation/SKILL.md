---
name: aap-controller-eda-automation
description: >-
  Automate Ansible Automation Platform (AAP) Controller and Event-Driven
  Ansible (EDA) objects (credentials, projects, job templates, execution
  environments, rulebooks, activations) via their REST APIs from plain
  ansible.builtin.uri, without the ansible.controller/ansible.eda
  collections. Use whenever writing or debugging playbooks/scripts that
  create or wire up AAP Controller or EDA resources, registering a
  custom Execution Environment, launching Job Templates from EDA
  rulebooks, or hitting container-networking errors ("Connection
  refused"/"Network is unreachable") from Controller job/project-sync
  containers trying to reach the host they run on.
---

# AAP Controller and EDA automation

## Why ansible.builtin.uri, not ansible.controller / ansible.eda

Those collections ship inside AAP's *execution environment* container
images, not on the control node's own filesystem. A
`module_defaults: {group/ansible.controller.controller: ...}` block (or
the EDA equivalent) fails at parse time, before any task runs, if the
collection isn't installed where the playbook runs:

```
ERROR! Error loading module_defaults: could not resolve the
module_defaults group ansible.controller.controller
```

Call the REST API directly with `ansible.builtin.uri` instead. Set shared
auth once via `module_defaults`:

```yaml
module_defaults:
  ansible.builtin.uri:
    url_username: admin
    url_password: "{{ aap_admin_password }}"
    force_basic_auth: true
    validate_certs: false
    body_format: json
```

Controller API base: `https://<host>/api/controller/v2`. EDA API base:
`https://<host>/api/eda/v1`.

## Idempotent create-or-converge pattern

Every object-creating task follows the same shape: look up by exact
name, `POST` if absent, `PATCH` in place if present. Re-running always
converges instead of failing on a duplicate name.

```yaml
- name: Look up the credential
  ansible.builtin.uri:
    url: "{{ controller_api }}/credentials/?name={{ credential_name | urlencode }}"
  register: r_cred

- name: Create it
  when: r_cred.json.count == 0
  ansible.builtin.uri:
    url: "{{ controller_api }}/credentials/"
    method: POST
    body: {name: "{{ credential_name }}", organization: "{{ org_id }}", credential_type: "{{ type_id }}", inputs: {...}}
    status_code: [200, 201]
  register: r_cred_created

- name: Update it in place if it is already there
  when: r_cred.json.count > 0
  ansible.builtin.uri:
    url: "{{ controller_api }}/credentials/{{ r_cred.json.results[0].id }}/"
    method: PATCH
    body: {inputs: {...}}
    status_code: [200]
```

Controller's `?name=` filter is an exact match. **EDA's `?name=` is a
substring match** (`?name=Def` also returns `Default`) - re-filter the
results yourself:

```yaml
- name: Pin to the exactly-named object
  ansible.builtin.set_fact:
    org_id: "{{ r_org.json.results | selectattr('name', 'equalto', org_name) | map(attribute='id') | first | default('') }}"
```

The REST API takes ids, not names, for every foreign key (organization,
credential_type, project, execution_environment, etc.) - the lookups the
collection modules did implicitly have to be explicit here.

Fail loudly before doing anything destructive:

```yaml
- name: Fail clearly if a prerequisite is missing
  ansible.builtin.assert:
    that: r_org.json.count > 0
    fail_msg: >-
      No organization named "{{ organization_name }}". Provisioning did
      not complete.
```

## Credential types with injectors

A custom credential type's `injectors` block is what makes a secret
*usable without being known* by the job: at launch time Controller
resolves the injector templates and hands the result to the job as an
extra var / env var.

```yaml
- name: Create a custom credential type
  ansible.builtin.uri:
    url: "{{ controller_api }}/credential_types/"
    method: POST
    body:
      name: My API Credentials
      kind: cloud
      inputs:
        fields:
          - {id: username, type: string, label: Username}
          - {id: password, type: string, label: Password, secret: true}
        required: [username, password]
      injectors:
        extra_vars: {my_username: "{{ username }}"}
        env: {MY_PASSWORD: "{{ password }}"}
    status_code: [200, 201]
```

If this is defined with `ansible.controller.credential_type` (a
templating module, not `uri`), those `{{ username }}`/`{{ password }}`
values need `!unsafe` - they're *Controller's own* templates, resolved
by Controller at job launch time, not by Ansible while creating the
type. Without `!unsafe`, Ansible tries to resolve them immediately and
fails on an undefined variable. With plain `ansible.builtin.uri`, the
body is a literal dict and this doesn't apply.

## The integer-body quoting trap

Two places where a body needs a *real* JSON integer, not a
Jinja-rendered string, and `uri`'s normal dict body silently produces
the wrong thing:

**Attaching a credential to a Job Template** (`POST
/job_templates/<id>/credentials/`) takes a plain `{"id": N}`, and that
field is a strict `IntegerField`:

```
Status code was 400: {"msg": "\"id\" field must be an integer."}
```

A dict body renders `"{{ item }}"` as the *string* `"3"`, which that
field rejects (`| int` in the dict doesn't help - Ansible still renders
the whole `"{{ ... }}"` expression to a string first). Write the body as
a **pre-formatted JSON string** instead, where the ints stay unquoted:

```yaml
- name: Attach a credential
  ansible.builtin.uri:
    url: "{{ controller_api }}/job_templates/{{ jt_id }}/credentials/"
    method: POST
    body: '{"id": {{ item | int }} }'
    status_code: [201, 204]
```

That association is also **not idempotent** - re-POSTing the same id, or
any credential of a type already attached, fails:

```
400 {"error": "Cannot assign multiple Machine credentials."}
```

Guard it by checking what's already attached first (`GET
/job_templates/<id>/credentials/`) and only POST ids not already there.

**EDA Activation creation** has the same trap for `eda_credentials`
(a list of ints) and `source_mappings` (a JSON string containing ints).
Build the whole body with `to_json` so every int stays a real int all
the way through, including inside the nested `source_mappings` string:

```yaml
- name: Assemble the source mapping
  ansible.builtin.set_fact:
    source_mappings: >-
      {{ [{'source_name': source_name, 'event_stream_id': event_stream_id | int,
           'event_stream_name': event_stream_name, 'rulebook_hash': rulebook_hash}] | to_json }}

- name: Create the Activation
  ansible.builtin.uri:
    url: "{{ eda_api }}/activations/"
    method: POST
    body: >-
      {{ {'name': activation_name, 'rulebook_id': rulebook_id | int,
          'eda_credentials': [cred_id | int], 'source_mappings': source_mappings,
          'is_enabled': true} | to_json }}
```

## Rulebooks: one rule, multiple actions - never a second rule behind it

`ansible-rulebook`'s drools engine fires **at most one rule per event**
(first matching rule wins, then the event is consumed). A catch-all
`condition: true` logging rule listed first will swallow every event,
and any remediation rule behind it never fires. If an event needs to do
two things, give one rule two `actions`, not two rules:

```yaml
rules:
  - name: Log and remediate
    condition: event.payload.task_result == "success"
    actions:
      - debug: {msg: "Received: {{ event }}"}
      - run_job_template:
          name: "My Job Template"
          organization: "Default"
          job_args: {extra_vars: {host_name: "{{ event.payload.host_name }}"}}
```

`ask_variables_on_launch: true` is required on the Job Template for
`run_job_template`'s `extra_vars` to actually reach the job - without
it, Controller silently ignores any extra vars supplied at launch.

## EDA project sync: rulebooks/ subdirectory is mandatory

A rulebook file sitting at the repo root is **silently not picked up**.
`import_state` reports `completed` with a non-fatal `import_error` and
zero rulebooks found. Rulebooks must live under `rulebooks/` (or
`extensions/eda/rulebooks/`) in the project root.

Recreating an Activation after a rulebook change is a delete-then-create,
and EDA activation deletion is **asynchronous** - the `DELETE` returns
immediately while the pod tears down in the background. Disable it
first, then poll until it's actually gone before creating the
replacement, or the create races the delete:

```yaml
- name: Disable it
  ansible.builtin.uri: {url: ".../activations/{{ id }}/disable/", method: POST, body: {}}
- name: Delete it
  ansible.builtin.uri: {url: ".../activations/{{ id }}/", method: DELETE}
- name: Wait until it is really gone
  ansible.builtin.uri: {url: ".../activations/?name={{ name | urlencode }}"}
  register: r_gone
  until: r_gone.json.results | selectattr('name', 'equalto', name) | list | length == 0
  retries: 60
  delay: 2
```

## Building and registering a custom Execution Environment

```bash
podman build -t my-ee -f Containerfile .
podman tag my-ee:latest <hub-host>/my-ee:latest
podman login --tls-verify=false -u admin -p "$PASS" <hub-host>
podman push --tls-verify=false <hub-host>/my-ee:latest
```

Then register it (same lookup-or-create pattern):

```yaml
- name: Register the EE
  ansible.builtin.uri:
    url: "{{ controller_api }}/execution_environments/"
    method: POST
    body: {name: "My EE", image: "<hub-host>/my-ee:latest", pull: missing}
```

If `podman push` fails with `connect: connection refused` on port 80
even though the registry works fine over HTTPS on 443, some internal
podman operations (the cross-repository blob-reuse ping during push)
don't reliably honor a one-off `--tls-verify=false` flag and fall back
to plain HTTP. Fix it once, for every operation, by declaring the
registry insecure in `registries.conf.d` instead of relying on the CLI
flag:

```bash
mkdir -p /etc/containers/registries.conf.d
cat > /etc/containers/registries.conf.d/my-registry-insecure.conf <<'EOF'
[[registry]]
location = "<hub-host>"
insecure = true
EOF
```

## Container networking: the host is not reachable the way you'd guess

Controller's Project sync and Job Template runs happen inside an
**isolated Execution Environment container**, not on the host's own
network namespace. If a Project's `scm_url` (or anything else a job
container needs to reach) points at the host itself, none of the
obvious addresses necessarily work, and each failure mode looks
different:

- **`localhost`**, or any hostname that's a static loopback alias on the
  host (check with `getent hosts <name>`) - resolves to the
  **container's own** loopback, not the host's. Fails with `connect to
  host ... port 22: Connection refused` (nothing listens there inside
  the container).
- **The host's own real, outward-facing IP** (`ip -4 addr show scope
  global`) - can fail with `Network is unreachable` if the host itself
  is a masqueraded VM on a virtualization platform, one network layer
  removed from the container's own network.
- **podman's default bridge gateway** (`podman network inspect podman`,
  typically `10.88.0.1`) - works if the container uses that default
  bridge network and the target service listens on all interfaces
  (`ss -tlnp`, look for `0.0.0.0`/`[::]`). Does **not** work for rootless
  podman using `slirp4netns` networking, which uses a different,
  per-container network entirely.
- **`host.containers.internal`** - podman's special alias for reaching
  the host from inside a rootless `slirp4netns` container. Requires
  `allow_host_loopback=true` in that container's slirp4netns options; if
  AAP's Controller launches its job containers with
  `DEFAULT_CONTAINER_RUN_OPTIONS` in `controller/etc/settings.py` and
  that flag isn't already set, add it and restart the task service:

  ```bash
  sed -i 's/slirp4netns:enable_ipv6=true"/slirp4netns:enable_ipv6=true,allow_host_loopback=true"/' \
    /home/<aap-user>/aap/controller/etc/settings.py
  sudo -iu <aap-user> env XDG_RUNTIME_DIR=/run/user/$(id -u <aap-user>) \
    systemctl --user restart automation-controller-task.service
  ```

Don't assume any single one of these is "the" answer - confirm which
networking mode that specific AAP install's job containers actually use
before picking an address, and test with a throwaway container:

```bash
podman run --rm <ee-image> bash -c "timeout 3 bash -c 'echo > /dev/tcp/<candidate-ip>/22' && echo REACHABLE || echo NOT_REACHABLE"
```

## Session timeout

Default `SESSION_COOKIE_AGE` is 1800 seconds (30 minutes), often too
short for a demo/lab session:

```yaml
- name: Extend the session timeout
  ansible.builtin.uri:
    url: "{{ controller_api }}/settings/system/"
    method: PATCH
    body: {SESSION_COOKIE_AGE: 28800}
```
