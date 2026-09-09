# ADV-SIEM-IDS

A Helm chart that deploys a pair of [sovity EDC-CE](https://github.com/sovity/edc-ce)
IDS connectors — one consumer, one provider — to a Kubernetes cluster.

Developed for the [AgriDataValue](https://agridatavalue.eu/) platform, where the
two connectors exchange agricultural datasets and models over the
[Dataspace Protocol](https://docs.internationaldataspaces.org/) (DSP). Nothing in
the chart is specific to agriculture: it is a general two-connector EDC deployment.

**Scope.** This repository contains the connectors only. The ADV platform
components that feed them — object-store importers, download APIs, ledger
publishers — are not part of this release.

---

## What you get

Two independent connectors, each with its own database and web UI:

| | Consumer | Provider |
| --- | --- | --- |
| Connector | `ghcr.io/sovity/edc-ce` | `ghcr.io/sovity/edc-ce` |
| UI | `ghcr.io/sovity/edc-ce-ui` | `ghcr.io/sovity/edc-ce-ui` |
| Database | PostgreSQL, own PVC | PostgreSQL, own PVC |
| Ingress | `ingress.consumerHost` | `ingress.providerHost` |

They are preconfigured as each other's counterparties, so a catalogue browse and a
contract negotiation work in both directions as soon as the chart is up.

Images are pinned **by digest** as well as tag. A tag can be republished under the
same name; a digest cannot, so pinning by digest is what actually guarantees the
running image does not change underneath you. Comment out a `digest` to follow the
tag instead.

---

## Requirements

- A Kubernetes cluster you can already reach with `kubectl` (1.25+)
- Helm 3
- An ingress controller, and a StorageClass that can provision `ReadWriteOnce`
  volumes
- Cluster egress to `ghcr.io` and `docker.io`, or internal mirrors of the four
  images

`./install-tools.sh` fetches `kubectl`, `helm` and `k9s` into `~/.local/bin`
without sudo, if you need them.

---

## Deploy

**Read [SECRETS.md](SECRETS.md) first.** It lists every credential and Kubernetes
Secret that must exist before a deployment will run, enumerated from the manifests,
with a checklist at the end.

`chart/values.yaml` ships with `CHANGEME` markers on every value that cannot be
guessed — they depend on your cluster and your secrets. Find the cluster-specific
ones with:

```bash
kubectl --context <ctx> get ingressclass    # ingress.className
kubectl --context <ctx> get storageclass    # postgres.persistence.storageClass
```

Then:

```bash
./deploy.sh --context <ctx> --namespace ids
./verify.sh --context <ctx>
```

`--context` is mandatory on every script. Defaulting to whatever
`kubectl config current-context` happens to be is how things land on the wrong
cluster, so nothing here guesses. `deploy.sh` prints the target API server and asks
for confirmation before it touches anything; `--yes` skips that for CI, and it
refuses outright while any `CHANGEME` remains.

Rather than editing `values.yaml` in place, consider keeping your real values in a
separate file that is not committed:

```bash
./deploy.sh --context <ctx> --values ../my-cluster-values.yaml
```

### Verify

`verify.sh` works through `kubectl port-forward`, not the ingress hostnames, so it
runs before DNS points at the cluster and from a machine that cannot resolve the
internal names. It checks that pods are Ready, that the Helm release is `deployed`,
that **each ingress backend names a port its Service actually exposes**, that the
management API rejects an unauthenticated call and accepts an authenticated one,
and that a full DSP contract negotiation reaches `FINALIZED` in both directions. It
deletes the offers it creates.

### Remove

```bash
./teardown.sh --context <ctx>                 # the release
./teardown.sh --context <ctx> --delete-data   # ALSO destroys the databases
```

It never deletes the cluster or the namespace — this is written to run against real
clusters hosting other things. The database PVCs carry
`helm.sh/resource-policy: keep` and survive by design; `--delete-data` is the only
way to remove them, and it destroys every asset, agreement and transfer record with
no undo.

---

## Fixes carried in this chart

The chart began as a straightforward sovity deployment and needed these before it
would install at all. `helm lint` passes despite every one of them, which is why
they are easy to miss:

| Problem | Effect |
| --- | --- |
| `POSTGRES_PASSWORD` resolved to null (the value was a YAML comment) | `helm install` fails |
| `ghcr-secret` `.dockerconfigjson` was null | `helm install` fails |
| Ingress backends named UI port 8080 while the Service publishes 11000 | ingress resolves to nothing |
| No `ingressClassName` | no controller claims the Ingress; it silently does nothing |
| PVC ignored `persistence.size` / `accessMode` (hardcoded 5Gi) | values had no effect |
| UI Deployments declared `containerPort: 80` while the image serves 8080 | mismatched port |
| `PGDATA` pointed at the volume root | real PVs arrive containing `lost+found`, and `initdb` refuses a non-empty directory — never reproduces on a local-path provisioner |
| Postgres ran as a bare `Pod` | no controller, so no rollout, no rescheduling |

The last four only surface on a real cluster, which is the case this chart is
written for.

---

## Branding

The sovity UI has **no whitelabel setting** — the only configuration it reads is
`NEXT_PUBLIC_BUILD_VERSION`, `BUILD_DATE`, `DEVTOOLS_ENABLED`, `MANAGEMENT_API_KEY`,
`MANAGEMENT_API_URL` and `USE_FAKE_BACKEND`. What it does do is serve its logo and
favicon as ordinary static files from `/app/public`, so those can be replaced by
mounting over them:

```yaml
branding:
  enabled: true
  logoFile: files/adv-logo-fitted.svg
  replaceFavicon: false
```

A ConfigMap built with `.Files.Get` is mounted with `subPath` over
`/app/public/sovity_logo.svg`. `subPath` matters: mounting the directory would hide
everything else the UI serves from there. A `checksum/branding` annotation on the
pod template forces a rollout when the file changes, because **subPath mounts do not
pick up later ConfigMap updates** — without it, editing the logo appears to do
nothing.

No image rebuild, and nothing to redo after a version upgrade. Point `logoFile` at
your own SVG in `chart/files/`, or set `branding.enabled: false` to keep sovity's.

Note the page hardcodes `width="115" height="32"` on the img — a 3.59:1 slot built
for sovity's wordmark. A logo is scaled to fit that box preserving its own ratio, so
**height is the binding constraint** and a squarish mark will not use the full width.

### What cannot be changed this way

Compiled into the Next.js bundles, not reachable by mounting files:

| | Where |
| --- | --- |
| "Get Managed EDC / Connector-as-a-Service" card | one i18n string, server chunk only |
| `(c) <year> sovity GmbH` footer | hardcoded JSX, **server and client** chunks |

The footer being in both means patching one chunk leaves the UI flipping back as
React hydrates. Changing either means patching minified chunks or forking
`sovity/edc-ce`. Note also that removing another party's copyright notice from AGPL
software is a licensing question, not only a technical one — adding your own
"deployed by" line alongside it is a different and safer thing.

---

## Limitations

Be clear about what this is scoped for before putting it in front of anything that
matters.

- **Identity is mocked.** `sovityDataspaceKind` stays `sovity-mock-iam`, which is
  correct while both connectors are yours and only talk to each other. Joining a
  real data space needs real participant credentials, and `sovityFqdnPublic` /
  `edcDspCallbackAddress` must become externally reachable URLs — counterparties
  call those from outside the cluster, so in-cluster service names will not do.
- **The management API key reaches the browser.** It is a `NEXT_PUBLIC_*` variable,
  so Next.js inlines it into the JavaScript the UI serves. Anyone who can load the
  UI holds full control of the connector. Put authentication in front of the
  ingress, or keep the UI internal.
- **One Postgres instance per connector**, on a `ReadWriteOnce` volume, with no
  backups. Fine for staging; use a managed database or add backups otherwise.
- **No NetworkPolicies, no PodSecurityContext**, and the DSP endpoints are open to
  anything that can route to them in-cluster.

---

## Licence

[Apache-2.0](LICENSE).

The chart deploys sovity EDC-CE images, which are licensed separately by their
authors — see [sovity/edc-ce](https://github.com/sovity/edc-ce). Apache-2.0 does not
grant rights to trademarks (§6): the AgriDataValue name and the marks in
`chart/files/` are not covered by this licence, so replace `branding.logoFile` with
your own asset rather than reusing them for your own deployment.
