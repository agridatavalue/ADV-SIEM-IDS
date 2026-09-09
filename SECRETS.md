# Secrets and credentials to set before deploying

Nothing in this repository contains a working credential. Everything below has to
be supplied before a deployment will run. `deploy.sh` refuses to start while any
`CHANGEME` remains in the values file, but it cannot check the Kubernetes Secrets
you create out of band — those fail later, at pod start.

Enumerated from the manifests themselves (`grep secretKeyRef`), not from memory.

---

## 1. Chart values — `chart/values.yaml`

| Value | What it is | Notes |
| --- | --- | --- |
| `secrets.connector.nextPublicManagementApiKey` | consumer management API key | the UI sends it from the browser |
| `secrets.connector.edcApiAuthKey` | consumer management API key | **must equal** the line above |
| `secrets.connector.sovityJdbcPassword` | consumer database password | **must equal** `postgres.auth.password` |
| `secrets.provider.nextPublicManagementApiKey` | provider management API key | |
| `secrets.provider.edcApiAuthKey` | provider management API key | **must equal** the line above |
| `secrets.provider.sovityJdbcPassword` | provider database password | **must equal** `postgres.auth.password` |
| `postgres.auth.password` | password both databases are created with | **must equal both** `sovityJdbcPassword` values |

The management API key is the only thing protecting the connector's management API.
Anyone holding it can create assets, publish offers and negotiate contracts. The
value shipped by sovity's demo, `SomeOtherApiKey`, is public — treat it as no
protection at all.

Note that `nextPublicManagementApiKey` becomes a `NEXT_PUBLIC_*` variable, which
Next.js inlines into the JavaScript the browser downloads. It is therefore visible
to anyone who can load the UI. That is upstream's design, not something this chart
introduces, but it means **the UI must not be exposed publicly** unless the ingress
in front of it authenticates users first.

**Three places must agree on the database password.** Get it wrong and the
connectors sit in CrashLoopBackOff with
`password authentication failed for user "db-user"`.

Non-secret but also marked `CHANGEME`, since only your cluster knows them:

| Value | Find it with |
| --- | --- |
| `ingress.className` | `kubectl get ingressclass` |
| `ingress.consumerHost` / `providerHost` | your DNS |
| `ingress.tls.consumerSecretName` / `providerSecretName` | names of the TLS Secrets in section 2 |
| `postgres.persistence.storageClass` | `kubectl get storageclass` |

---

## 2. Kubernetes Secrets you must create yourself

The chart creates `<appName>-secret`, `<appName>-provider-secret`,
`postgres-secret`, `postgres-provider-secret` and `ghcr-secret` from the values
above. These it does **not** create:

### TLS certificates — required when `ingress.tls.enabled: true`

```bash
kubectl -n ids create secret tls consumer-tls --cert=consumer.crt --key=consumer.key
kubectl -n ids create secret tls provider-tls --cert=provider.crt --key=provider.key
```

With cert-manager, set the issuer in `ingress.annotations` instead and it
populates these for you.

### Private registry, only if you mirror the images

The `ghcr.io/sovity` images are public, so nothing is needed by default. If you
pull them through a registry that requires authentication:

```bash
kubectl -n ids create secret docker-registry regcred \
  --docker-server=<registry> --docker-username=... --docker-password=...
```

By default `ghcrDockerConfigJson` in the values is empty and
`chart/templates/secrets/ghcr-secret.yaml` renders a valid `{"auths":{}}`, so the
kubelet pulls anonymously. To authenticate, either set `ghcrDockerConfigJson` to a
base64 docker config, or pre-create the Secret out of band under the name in
`imagePullSecret` and leave the value empty.

**Use single quotes** around any credential you pass on a command line. These
values commonly contain `#`, `$` or `!`; unquoted, the shell mangles them, and an
unquoted `#` silently truncates the rest of the value.

---

## 3. What these credentials reach

Be aware of the blast radius before reusing anything:

| Credential | Reaches |
| --- | --- |
| management API key | full control of the connector: assets, offers, negotiations, transfers |
| `postgres.auth.password` | the connectors' databases: assets, agreements, transfer history |

---

## 4. Do not commit any of this

`.gitignore` excludes `*/secret.yaml`, `*/secrets.yaml`, `.env` and `*.env`.
Check before committing:

```bash
git status
git diff --cached | grep -iE 'password|secret|key.*='
```

For anything beyond a short-lived staging deployment, prefer
[sealed-secrets](https://github.com/bitnami-labs/sealed-secrets),
[external-secrets](https://external-secrets.io/) or a vault over
`kubectl create secret` — those keep the values out of shell history and out of
whoever's laptop ran the command.

Filling real credentials into `chart/values.yaml` and committing it is the failure
mode this file exists to prevent. The `CHANGEME` markers are there to make the
requirement visible, not as slots to fill in and push. If you fork this repository
to hold your own configuration, make that fork private.

---

## 5. Quick checklist

- [ ] `chart/values.yaml`: no `CHANGEME` left (`grep -c CHANGEME chart/values.yaml` → 0)
- [ ] `postgres.auth.password` equals both `sovityJdbcPassword` values
- [ ] both `edcApiAuthKey` values equal their `nextPublicManagementApiKey`
- [ ] TLS Secrets created, names match `ingress.tls.*SecretName`
- [ ] `ingress.className` and `postgres.persistence.storageClass` match the cluster
- [ ] the UI is not reachable by anyone who should not hold the management API key
