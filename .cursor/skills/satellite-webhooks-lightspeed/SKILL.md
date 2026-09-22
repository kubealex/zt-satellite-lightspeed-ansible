---
name: satellite-webhooks-lightspeed
description: >-
  Configure Red Hat Satellite webhooks (custom ERB templates, event
  names, target URLs) and query Satellite's on-premises Red Hat
  Lightspeed Vulnerability service and Katello content API for CVE and
  errata data. Use whenever writing or debugging Satellite webhook
  automation, integrating Satellite with an external system via
  webhooks, or writing a script that reads CVE/vulnerability data from
  Satellite (Lightspeed Vulnerability API or Katello errata API).
---

# Satellite webhooks and Lightspeed Vulnerability data

## Custom webhook templates are usually required

Satellite's built-in webhook templates frequently don't work for a
given event type:

- "Webhook Template - Payload Default" can throw `undefined method
  '#id'` for events whose payload object doesn't support the method the
  default template calls.
- "Remote Execution Host Job" only emits human-readable comments, not
  JSON, so nothing downstream can parse it.

Write a custom ERB template instead and register it via the API
(`POST /api/webhook_templates`, body `{webhook_template: {name, template,
snippet: false}}`). The `<%# ... -%>` header comment block sets the
template's own metadata (`name`, `description`, `model: WebhookTemplate`):

```erb
<%#
name: My Custom Webhook JSON
description: JSON payload for some.event.foreman
snippet: false
model: WebhookTemplate
-%>
<%=
payload({
  host_name: @object.host_name,
  host_id: @object.host_id,
  task_result: @object.task.result,
})
-%>
```

Re-running the create is safe if you `PUT` to the existing template's id
when one with that name already exists, instead of failing on a
duplicate name the way `hammer webhook-template create` does.

## The event name has two spellings

`hammer webhook create --event` (and the API's `event` field) takes the
event name **without** its `.event.foreman` suffix on input, e.g.
`actions.remote_execution.run_host_job_succeeded` - but `hammer webhook
info` (and the API on read) **displays it with that suffix** afterward.
Don't hardcode a guess; ask Satellite for its own spelling and fall back
to the short form:

```yaml
- name: Ask Satellite which webhook events it knows about
  ansible.builtin.uri:
    url: "{{ satellite_api }}/webhooks/events"
    status_code: [200, 404]
  register: r_events

- name: Use Satellite's own spelling
  ansible.builtin.set_fact:
    webhook_event: >-
      {{ (r_events.json | default([], true) | select('search', 'run_host_job_succeeded') | list | first)
         | default('actions.remote_execution.run_host_job_succeeded', true) }}
```

## A webhook's target URL can go stale

If the webhook points at an external system's dynamically-generated
endpoint (e.g. an AAP EDA Event Stream URL, which embeds a UUID), that
URL can drift if the credential behind it is touched again later. A
stale URL fails with `{"detail":"bad uuid specified"}`. Fetch the target
URL live, every time the webhook is created or repaired, rather than
caching it:

```yaml
- name: Ask the target system for its current URL
  ansible.builtin.uri:
    url: "{{ target_api }}/event-streams/?name={{ name | urlencode }}"
  register: r_stream
- ansible.builtin.set_fact:
    target_url: "{{ r_stream.json.results[0].url }}"
```

Making the webhook's create task idempotent (`PUT`/`PATCH` in place if
one with that name already exists) doubles as the repair for this: a
freshly fetched URL just overwrites whatever the stale one was carrying.

## Reading vulnerability data: two different APIs, two different auth methods

Satellite exposes CVE/vulnerability data through two separate APIs that
need to be cross-referenced together:

- **Red Hat Lightspeed Vulnerability API**
  (`/insights_cloud/api/vulnerability/v1/...`) - powers the "Red Hat
  Lightspeed > Vulnerability" page in the Satellite web UI. Despite the
  URL path containing `insights_cloud`, when Satellite is self-hosting
  this service it is served **entirely on-premises**, from CVE data
  already synced into Satellite - it is *not* the hosted
  `console.redhat.com` cloud service, and nothing about a query to it
  leaves the network it's running on. It **only accepts session-cookie
  auth**, not HTTP Basic Auth. Log in the same way the web UI's login
  form does: `GET /users/login` for a CSRF token, then `POST
  /users/login` with `authenticity_token`, `login[login]`,
  `login[password]`.

  ```python
  session = requests.Session()
  page = session.get(f"{base_url}/users/login")
  csrf_token = re.search(r'name="csrf-token" content="([^"]+)"', page.text).group(1)
  session.post(f"{base_url}/users/login", data={
      "authenticity_token": csrf_token, "login[login]": username,
      "login[password]": password, "commit": "Log in",
  })
  # session now carries the cookie for every subsequent Lightspeed call
  ```

- **Katello content API** (`/katello/api/errata`,
  `/api/hosts/<id>/packages`, `/api/hosts?search=...applicable_errata=...`)
  - documented, stable, supports HTTP Basic Auth. Use it to find the
    exact erratum + RPM package(s) that fix a given CVE, to list a
    host's installed packages, and to check whether a specific erratum
    is actually applicable to a specific host (accounts for content
    view/lifecycle environment and version comparison, not just "is
    some package with this name installed").

## Katello API pagination: total vs subtotal

`/katello/api/errata` (and similar list endpoints) return both a
`total` (size of the entire *unfiltered* collection) and a `subtotal`
(count matching your `search` filter). Paginating against `total`
instead of `subtotal` makes the loop run almost forever once a filtered
query's real result set is much smaller than the whole collection:

```python
matched = payload.get("subtotal", payload.get("total", len(results)))
if page * per_page >= matched:
    break
```

## Deciding whether an erratum would actually change a host

An erratum "ships" a package doesn't mean applying it would install
anything new on a given host - the host might already be at or past
that version. Compare NVRAs (name-version-release.arch) with RPM's own
version-comparison rules (`rpmvercmp`: compare `~`, then digit-runs vs
letter-runs segment by segment, numeric segments compare numerically
after stripping leading zeros) rather than a plain string compare, which
gets multi-digit version segments wrong (`"9" > "10"` as strings, but
not as versions).
