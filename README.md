# Helm Chart

Helm Chart for Horse Messaging Server.

## Installation and namespace

```sh
helm upgrade --install horse . --namespace messaging --create-namespace
```

Every resource uses `deployment.namespace`. When it is empty (the default),
the chart uses `.Release.Namespace`, supplied by `--namespace`. If you set an
explicit override, create that namespace first. Keep the override and Helm
release namespace identical where possible.

For existing releases, use the namespace in which the resources already live.
Changing namespace is a migration, not an in-place move of Pods or PVCs.

## Persistent data path

`server.dataPath` defaults to an empty string, which resolves to
`<mount.path>/data`. The default remains `/etc/horse/data`; changing only
`mount.path` now moves the mount and the derived data path together.

```yaml
mount:
  path: /var/lib/horse
server:
  dataPath: "" # Resolves to /var/lib/horse/data on the PVC.
```

An explicit `server.dataPath` must be absolute and equal to or inside
`mount.path`. Both paths are normalized before checking directory boundaries:
`/etc/horse-backup/data` and `/etc/horse/../data` are outside `/etc/horse` and
are rejected during template rendering. Trailing slashes and internal `.`/`..`
segments that remain within the mount are normalized consistently.

Existing overrides that set `server.dataPath: /etc/horse/data` continue to work
with the default mount. If you change the mount, clear that override or update it
to a path within the new mount. Changing the relative data directory inside a PVC
does not move existing data; preserve that directory or migrate the data separately.

## Ports and ingress

The image has fixed listener ports; changing a Service port does not change an
application listener. Services use named container targets, and Ingresses use
named Service ports.

| Traffic | Container port | Service port | Ingress |
| --- | --- | --- | --- |
| Horse messaging | 2626 | `server.port` on the shared Service; 2626 on headless and per-pod Services | None |
| Jockey HTTP | 2627 | `jockey.port` | `jockey.enabled` and `jockey.ingress` |
| Node communication | 2628 | 2628 on headless and per-pod Services, cluster-internal only | None |
| WebSocket | 2680 | `server.websocketPort` | `websocket.ingress`, when the port is nonzero |

Declaring port 2628 in Kubernetes does not start a listener: the selected image
must implement node communication on that port. The local MessagingServer source
used during this review still advertised cluster peers on 2626, so both internal
ports are retained. Verify the running image's node protocol before removing either.

`jockey.enabled: false` removes the panel's ports and Ingresses.
`server.websocketPort: 0` disables WebSockets and removes their ports and Ingresses.
The node Service is internal, but ClusterIP is not a network access-control policy.

```yaml
jockey:
  ingress: false
websocket:
  ingress: true
  ingressHost: .ws.example.com
```

These switches are independent. An empty `websocket.ingressHost` reuses
`jockey.ingressHost`. Existing Ingress names and hostname patterns are preserved.
When upgrading an installation that used `jockey.ingress: false` to disable
everything, also set `websocket.ingress: false` to preserve that behavior.

## Configuration changes and Pod replacement

```yaml
deployment:
  restartOnConfigChange: true
  rollingUpdate: true
```

During `helm upgrade`, Helm hashes the rendered ConfigMap and Secret and puts
the checksums into the Pod template. A content change changes the template, so
the StatefulSet controller replaces Pods in ordinal order from highest to lowest.
Unchanged content produces unchanged hashes. Environment variables are read when
the container starts, so the new Pod receives the updated configuration.

With `rollingUpdate: false`, the chart explicitly uses `OnDelete`: even if a
checksum changes, existing Pods are not automatically replaced. With
`restartOnConfigChange: false`, configuration-only edits do not change the Pod
template. These checksums do not watch manual `kubectl` edits between Helm runs.
Readiness checks are intentionally unchanged; rolling replacement does not prove
that Horse has completed recovery or joined its cluster.

## Image version

The default tag is `8.2.27`, verified to match Docker Hub's `latest` digest on
2026-11-05. The old chart's `appVersion: 6.6.4` did not pin its `latest` image,
and Docker Hub did not contain an image tag named `6.6.4` at verification time.
An existing node may have an older cached `latest`; check the running image ID
before upgrading an existing installation.

An optional `image.digest` takes precedence over `image.tag` and renders
`repository@digest`. To pin the verified multi-platform 8.2.27 image exactly:

```yaml
image:
  tag: "8.2.27"
  digest: sha256:d413f3667ba041376cefba2c8d4f07f166b631d872a33955225b851447db0b7e
```

Clear or update the digest when changing versions. Chart version and application
version are independent: this chart is 7.0.0, with default application 8.2.27.

## Headless Service and StatefulSet DNS

The chart creates `<release>-headless` with `clusterIP: None` and sets the
StatefulSet's `spec.serviceName` to that Service. It selects all Horse Pods and
publishes their internal ports 2626 and 2628. `publishNotReadyAddresses: true`
allows DNS discovery during cluster startup.

Unlike a regular Service's virtual IP, a headless Service resolves to endpoint
Pod IPs. With release `horse`, namespace `messaging`, and cluster domain
`cluster.local`, stable Pod records are:

```text
horse-0.horse-headless.messaging.svc.cluster.local
horse-1.horse-headless.messaging.svc.cluster.local
horse-2.horse-headless.messaging.svc.cluster.local
```

The Pod IP can change after rescheduling; its DNS identity remains stable.
Set `cluster.dnsDomain` if Kubernetes uses a domain other than `cluster.local`.
The namespace component comes from the same `deployment.namespace` override or
Helm release namespace used by all chart resources.

The shared ClusterIP Service and per-pod Services remain available for client
connections and Ingress backends. Ingresses do not target the headless Service.

Horse builds peer addresses from `HORSE_HOSTNAME`, replacing `INDEX` with each
ordinal, and compares those addresses with `HOSTNAME` to skip its own node.
The chart sets both to the same fully qualified DNS form:

```text
HORSE_POD_NAME = metadata.name (Kubernetes downward API)
HOSTNAME = $(HORSE_POD_NAME).horse-headless.messaging.svc.cluster.local
HORSE_HOSTNAME = horse-INDEX.horse-headless.messaging.svc.cluster.local
```

Kubernetes expands `$(HORSE_POD_NAME)` in the subsequent environment entry when
starting the container. Only the application's `HOSTNAME` environment variable
is overridden; the Pod's OS hostname remains the normal StatefulSet short name.
This preserves Horse's self-exclusion rule without rebuilding the image.

These are internal DNS names. The current server also derives its advertised
`PublicHost` from `HOSTNAME`; external client access still needs separate public
address configuration in the server. A headless Service does not provide that.

### Upgrading an existing StatefulSet

This is a breaking chart change (7.0.0): Kubernetes cannot patch the existing
StatefulSet's `serviceName`. A normal in-place `helm upgrade` from the old layout
will fail. Do not use a blind force replacement or delete PVCs to work around it.

Plan a maintenance window and recreate the controller with the existing data:

1. Back up the data and record the existing release values, replicas, namespace,
   image IDs, and PVC names. Confirm PVC retention on scale-down and deletion is
   `Retain` (the old chart uses Kubernetes' default retention behavior).
2. Quiesce producers/consumers, scale the old StatefulSet to zero, and wait until
   all its Pods have stopped. This avoids mixing short-name and FQDN node identities.
3. Remove only the old StatefulSet controller, preserving the PVCs and Services.
   Then run `helm upgrade` with the same release name and resource namespace,
   the new chart, and the intended replica count and values.
4. The recreated StatefulSet keeps the original Pod and volume-claim names,
   allowing its Pods to mount their existing PVCs. Verify headless DNS records,
   unique node identities, cluster membership, and data recovery before resuming traffic.

Changing `mount.storage` does not resize existing PVCs; handle any storage expansion
separately. Fresh installations need no migration. Runtime DNS and multi-node
recovery must be checked on the target Kubernetes cluster; the local render tests
only validate manifest wiring and Horse's hostname comparison inputs.

See [Kubernetes DNS](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
and [dependent environment variables](https://kubernetes.io/docs/tasks/inject-data-application/define-interdependent-environment-variables/).
For config updates, see [Helm checksum rollouts](https://helm.sh/docs/howto/charts_tips_and_tricks/#automatically-roll-deployments).

## Resource settings and scaling

`deployment.resources` is wired to the container's requests and limits. Both
default to empty maps, imposing no CPU/memory requests or limits from this chart.
Namespace LimitRange defaults may still apply. To configure resources:

```yaml
deployment:
  resources:
    requests:
      cpu: "100m"
      memory: "128Mi"
    limits:
      cpu: "500m"
      memory: "512Mi"
```

Omit a resource key to leave it unspecified; `unlimited` is not a valid Kubernetes
quantity. A resource change updates the Pod template and follows the selected
StatefulSet update strategy.

Set `cluster.replica` through `helm upgrade` to scale the cluster. For example,
`cluster.replica: 5` creates five Pods in one StatefulSet and configures every
Pod with `HORSE_HOST_COUNT=5` and the headless DNS template. Each node generates
ordinals 0 through 4, skips itself, and uses the other four addresses as peers.
Existing Pods get the updated peer count through the configured update strategy;
`OnDelete` requires manual Pod replacement. A standalone `kubectl scale` changes
the Pod count but does not update the chart-generated peer-count environment
variable, so it is not sufficient for this discovery scheme.

`deployment.environments` and `cluster.nodeAffinity` were unused and have been
removed. `deployment.nodeAffinity` remains because it
controls the existing topology spread constraint.

## Values validation

Helm natively checks `values.schema.json` against the final merged values during
`install`, `upgrade`, `lint`, and `template`. This chart's schema checks:

- Integer replica counts (zero is allowed for scale-down), port ranges, and
  nonnegative numeric limits and timeouts.
- Boolean switches, documented queue/cluster enums, and image pull policies.
- Resource quantity syntax, including rejection of the string `unlimited`.
- Absolute mount paths, empty-or-absolute data paths, and namespace/DNS syntax.

The schema uses local references only. It does not require a network fetch and
does not replace Kubernetes API validation (for example, requests must not exceed
limits). Unrecognized values are not generally rejected, to preserve compatibility
with Helm parent charts and old values files; removed settings remain unused.

The relationship between `mount.path` and `server.dataPath` is checked separately
by a Helm template helper. Helm 3 lint logs template `fail` calls without failing
the lint command, so run **both lint and template**. Rendering (and normal
install/upgrade rendering) rejects a data path outside the PVC, even when
`deployment.restartOnConfigChange` is disabled.

Examples that must fail:

```sh
helm lint . --strict --set cluster.replica=2.5
helm template review . --set server.port=70000
helm template review . --set server.dataPath=/tmp/data
```

See [Helm schema files](https://helm.sh/docs/topics/charts/#schema-files).

Run the local regression checks with Helm and kubectl installed:

```powershell
./tests/render.ps1
# Or pass explicit executable paths using -HelmPath and -KubectlPath.
```

The checks run Helm lint and validate rendered namespaces, port references,
Ingress switches, resource requests/limits, string round-trips, checksum behavior, update strategies,
headless DNS identities and self-exclusion, image selection, PVC data-path
containment, and schema rejection of invalid inputs. They do not contact a cluster
or replace Kubernetes schema and runtime integration testing.
