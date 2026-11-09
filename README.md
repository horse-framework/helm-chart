# Horse Messaging Server Helm Chart

[Horse](https://github.com/horse-framework/horse-messaging) is an open source,
general-purpose messaging server for communication between applications:
queues, channels, routers, gateway, transactions, cache and RPC.

This chart deploys Horse on Kubernetes as a StatefulSet with persistent
storage, optional multi-node clustering, the **Jockey** administration panel and
WebSocket support.

| | |
| --- | --- |
| Chart version | `8.3.0` |
| App version | `8.3.0` |
| Image | [`horseframework/messaging-server`](https://hub.docker.com/r/horseframework/messaging-server) |
| Kubernetes | 1.23+ |
| Helm | 3.8+ (OCI registry support) |

## Quick start

```sh
helm install horse oci://ghcr.io/horse-framework/charts/horse \
  --version 8.3.0 \
  --namespace messaging --create-namespace
```

Before going to production, change at least the default credentials:

```sh
helm install horse oci://ghcr.io/horse-framework/charts/horse \
  --version 8.3.0 \
  --namespace messaging --create-namespace \
  --set jockey.password='<strong-password>' \
  --set cluster.sharedSecret='<random-uuid>' \
  --set jockey.ingressHost=.example.com
```

To inspect the chart and its default values without installing:

```sh
helm show readme oci://ghcr.io/horse-framework/charts/horse --version 8.3.0
helm show values oci://ghcr.io/horse-framework/charts/horse --version 8.3.0 > my-values.yaml
```

Then install with your own values file:

```sh
helm upgrade --install horse oci://ghcr.io/horse-framework/charts/horse \
  --version 8.3.0 -n messaging --create-namespace -f my-values.yaml
```

### Uninstall

```sh
helm uninstall horse -n messaging
```

PersistentVolumeClaims created by the StatefulSet are **not** deleted by
`helm uninstall`. Delete them manually if you no longer need the data.

## What gets deployed

| Resource | Name | Purpose |
| --- | --- | --- |
| StatefulSet | `<release>` | Horse server Pods with one PVC each |
| Service | `<release>` | Shared ClusterIP Service for clients, Jockey and WebSocket |
| Service | `<release>-<n>` | Per-Pod Service, one per replica |
| Service | `<release>-headless` | Headless Service for stable Pod DNS and node discovery |
| ConfigMap | `<release>-config` | Server, queue, channel and cache options |
| Secret | `<release>-secret` | Jockey credentials and cluster shared secret |
| Ingress | see [Ingress](#ingress) | Jockey panel and WebSocket endpoints (optional) |

## Ports

The container image listens on fixed ports. Changing a Service port does not
change the application's listener.

| Traffic | Container port | Service port | Exposed by Ingress |
| --- | --- | --- | --- |
| Horse protocol (clients) | 2626 | `server.port` | No |
| Jockey admin panel (HTTP) | 2627 | `jockey.port` | `jockey.enabled` + `jockey.ingress` |
| Node-to-node communication | 2628 | headless and per-Pod Services only | No (cluster-internal) |
| WebSocket | 2680 | `server.websocketPort` | `websocket.ingress` |

- `jockey.enabled: false` removes the Jockey ports and Ingresses.
- `server.websocketPort: 0` disables WebSocket and removes its ports and Ingresses.

## Configuration

All parameters are documented in [`values.yaml`](values.yaml) and validated by
[`values.schema.json`](values.schema.json).

### Image

| Parameter | Description | Default |
| --- | --- | --- |
| `image.repository` | Image repository | `horseframework/messaging-server` |
| `image.tag` | Image tag | `"8.3.0"` |
| `image.digest` | Optional `sha256:` digest; overrides `tag` when set | `""` |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |

### Deployment

| Parameter | Description | Default |
| --- | --- | --- |
| `deployment.namespace` | Namespace for all resources. Empty uses `--namespace` | `""` |
| `deployment.nodeAffinity` | Spread Pods across nodes (topology spread, `maxSkew: 1`, `DoNotSchedule`) | `true` |
| `deployment.rollingUpdate` | `true`: `RollingUpdate`, `false`: `OnDelete` | `true` |
| `deployment.restartOnConfigChange` | Roll Pods when the ConfigMap or Secret changes | `true` |
| `deployment.resources.requests` | CPU/memory requests | `{}` |
| `deployment.resources.limits` | CPU/memory limits | `{}` |

### Persistence

| Parameter | Description | Default |
| --- | --- | --- |
| `mount.path` | Volume mount path inside the container | `/etc/horse` |
| `mount.storage` | PVC size per Pod | `4Gi` |
| `server.dataPath` | Data directory. Empty means `<mount.path>/data` | `""` |

### Cluster

| Parameter | Description | Default |
| --- | --- | --- |
| `cluster.replica` | Number of Horse nodes (1, 3 or 5 recommended) | `1` |
| `cluster.clusterType` | `Reliable` or `Scaled` | `Reliable` |
| `cluster.sharedSecret` | Secret shared between nodes of the same cluster | *(sample UUID, change it)* |
| `cluster.dnsDomain` | Kubernetes cluster DNS domain | `cluster.local` |

- **Reliable**: clients connect to the main node; queue messages are replicated
  between nodes.
- **Scaled**: clients connect to different nodes; queues are independent per
  node. Recommended for channels and direct messaging.

### Server

| Parameter | Description | Default |
| --- | --- | --- |
| `server.port` | Horse protocol Service port | `2626` |
| `server.websocketPort` | WebSocket Service port, `0` disables WebSocket | `2680` |
| `server.channelLimit` | Maximum channels, `0` = unlimited | `0` |
| `server.clientLimit` | Maximum concurrent clients, `0` = unlimited | `0` |
| `server.queueLimit` | Maximum queues, `0` = unlimited | `0` |
| `server.routerLimit` | Maximum routers, `0` = unlimited | `0` |

### Jockey (admin panel)

| Parameter | Description | Default |
| --- | --- | --- |
| `jockey.enabled` | Enable the Jockey panel | `true` |
| `jockey.ingress` | Create Ingresses for Jockey | `true` |
| `jockey.port` | Jockey Service port | `2627` |
| `jockey.username` | Panel username | `admin` |
| `jockey.password` | Panel password | `password` *(change it)* |
| `jockey.ingressHost` | Host suffix, see [Ingress](#ingress) | `.yourdomain.com` |

### WebSocket

| Parameter | Description | Default |
| --- | --- | --- |
| `websocket.ingress` | Create Ingresses for WebSocket | `true` |
| `websocket.ingressHost` | Host suffix. Empty reuses `jockey.ingressHost` | `""` |

### Queue defaults

Defaults applied to every queue unless the queue specifies its own options.

| Parameter | Description | Default |
| --- | --- | --- |
| `queue.autoCreate` | Create a queue on first push | `true` |
| `queue.queueType` | `RoundRobin`, `Push` or `Pull` | `RoundRobin` |
| `queue.queueAck` | `None`, `JustRequest` or `WaitForAcknowledge` | `WaitForAcknowledge` |
| `queue.ackTimeout` | Acknowledge timeout (seconds) | `30` |
| `queue.autoDestroy` | `Disabled`, `Empty`, `NoConsumers` or `NoMessages` | `Disabled` |
| `queue.commitWhen` | `None`, `AfterReceived`, `AfterSent` or `AfterAcknowledge` | `AfterReceived` |
| `queue.putback` | `No`, `Regular` or `Priority` | `Regular` |
| `queue.putbackDelay` | Put-back delay (ms) | `15000` |
| `queue.consumerLimit` | Max consumers per queue, `0` = unlimited | `0` |
| `queue.messageLimit` | Max messages per queue, `0` = unlimited | `0` |
| `queue.msgExceedStrategy` | `RejectNewMessage` or `DeleteOldestMessage` | `RejectNewMessage` |
| `queue.messageSizeLimit` | Max message size (bytes), `0` = unlimited | `0` |
| `queue.messageTimeout` | Message timeout (minutes), `0` = none | `0` |
| `queue.messageTimeoutStrategy` | `NoTimeout`, `Delete`, `PushQueue` or `PublishRouter` | `Delete` |
| `queue.messageTimeoutTarget` | Target queue/router for timed-out messages | `""` |
| `queue.delayBetweenMessages` | Delay per consumer between messages (ms) | `0` |
| `queue.messageIdUniqueCheck` | Enforce unique message IDs (slower) | `false` |
| `queue.usePersistentQueues` | Enable persistent queues | `true` |
| `queue.useMemoryQueues` | Enable in-memory queues | `true` |
| `queue.defaultQueueManager` | `Persistent` or `Memory` | `Persistent` |

### Channel defaults

| Parameter | Description | Default |
| --- | --- | --- |
| `channel.autoCreate` | Create channels on first use | `true` |
| `channel.autoDestroy` | Destroy channels with no subscribers | `true` |
| `channel.sendLatestMessage` | Send the latest message to new subscribers | `true` |
| `channel.subscriberLimit` | Max subscribers per channel, `0` = unlimited | `0` |

### Cache

| Parameter | Description | Default |
| --- | --- | --- |
| `cache.maxKeys` | Maximum key count, `0` = unlimited | `0` |
| `cache.maxValueSize` | Maximum value size (bytes), `0` = unlimited | `0` |

## Ingress

Ingresses use `ingressClassName: nginx` and are built from the release name and
a host suffix. With release `horse`, `cluster.replica: 3` and
`jockey.ingressHost: .example.com`, the chart creates:

| Endpoint | Hosts |
| --- | --- |
| Jockey (any node) | `horse-jockey.example.com` |
| Jockey (per node) | `horse-jockey-0.example.com`, `horse-jockey-1.example.com`, `horse-jockey-2.example.com` |
| WebSocket (any node) | `horse.example.com` |
| WebSocket (per node) | `horse-0.example.com`, `horse-1.example.com`, `horse-2.example.com` |

Start the suffix with `.` for a subdomain, or use something like `-mq.example.com`
to get `horse-jockey-mq.example.com`. Set `websocket.ingressHost` to put
WebSocket on a different domain.

Jockey and WebSocket Ingresses are switched independently:

```yaml
jockey:
  ingress: false
websocket:
  ingress: true
  ingressHost: .ws.example.com
```

## Clustering

Set `cluster.replica` to run multiple nodes:

```sh
helm upgrade horse oci://ghcr.io/horse-framework/charts/horse \
  --version 8.3.0 -n messaging --reuse-values --set cluster.replica=3
```

Each Pod gets a stable DNS name through the headless Service:

```text
horse-0.horse-headless.messaging.svc.cluster.local
horse-1.horse-headless.messaging.svc.cluster.local
horse-2.horse-headless.messaging.svc.cluster.local
```

Every node receives the replica count (`HORSE_HOST_COUNT`) and a hostname
template (`HORSE_HOSTNAME`), builds the address list for all ordinals and skips
itself. Because of this:

- **Always scale with `helm upgrade`**, not `kubectl scale`. `kubectl scale`
  changes the Pod count but not the peer count the nodes use.
- Set `cluster.dnsDomain` if your cluster does not use `cluster.local`.
- Use a different `cluster.sharedSecret` for each independent cluster.

These DNS names are cluster-internal. Exposing the Horse protocol (port 2626)
outside the cluster needs your own LoadBalancer/NodePort setup.

## Persistence

Each Pod gets its own PVC of size `mount.storage`, mounted at `mount.path`.
Queue data is stored in `server.dataPath`, which defaults to
`<mount.path>/data`.

```yaml
mount:
  path: /var/lib/horse
  storage: 10Gi
server:
  dataPath: ""   # resolves to /var/lib/horse/data
```

An explicit `server.dataPath` must be absolute and inside `mount.path`;
otherwise rendering fails, so data never ends up outside the volume.

Changing `mount.storage` does not resize existing PVCs, and changing the data
directory does not move existing data.

## Configuration changes and rollouts

With the defaults (`rollingUpdate: true`, `restartOnConfigChange: true`), any
change to the rendered ConfigMap or Secret during `helm upgrade` rolls the
Pods one by one, from the highest ordinal to the lowest.

- `rollingUpdate: false` uses the `OnDelete` strategy: Pods are only replaced
  when you delete them yourself.
- `restartOnConfigChange: false` keeps Pods running when only configuration
  changes.
- Manual `kubectl edit` changes are not detected.

## Resources

No CPU or memory requests/limits are set by default. Example:

```yaml
deployment:
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

## Pinning the image

To pin an exact image, set a digest. It takes precedence over `image.tag`:

```yaml
image:
  tag: "8.3.0"
  digest: sha256:<digest>
```

Clear or update the digest when you change versions.

## Values validation

Helm validates your values against `values.schema.json` on `install`, `upgrade`,
`lint` and `template`. Invalid replica counts, port ranges, enum values,
resource quantities and paths are rejected before anything reaches the cluster.

```sh
helm template horse . --set server.port=70000          # fails: port out of range
helm template horse . --set server.dataPath=/tmp/data  # fails: outside mount.path
```

## Upgrading

### From chart versions older than 7.0.0

7.0.0 introduced the headless Service and changed the StatefulSet's
`serviceName`. Kubernetes cannot change that field in place, so a plain
`helm upgrade` from an older chart fails. Do **not** use `--force` and do not
delete PVCs. Instead:

1. Back up your data. Note the release values, replica count, namespace and
   PVC names.
2. Stop producers and consumers, scale the old StatefulSet to `0` and wait for
   all Pods to stop.
3. Delete only the StatefulSet, keeping PVCs and Services:
   `kubectl delete statefulset horse -n messaging --cascade=orphan`
4. Run `helm upgrade` with the same release name, namespace and values.
5. The new Pods reuse the existing PVCs. Check cluster membership and data
   before resuming traffic.

Other notes for old installations:

- `deployment.environments` and `cluster.nodeAffinity` were removed.
- Older charts used the `latest` image tag. Check which image your Pods are
  actually running before upgrading.

## Development

Render and lint locally:

```sh
helm lint .
helm template horse . -n messaging
```

Run the regression checks (requires Helm, kubectl and PowerShell):

```powershell
./tests/render.ps1
```

They validate rendered manifests, Ingress switches, DNS identities, checksums,
update strategies, path containment and schema rejections. They do not contact
a cluster.

## Links

- Horse Messaging: <https://github.com/horse-framework/horse-messaging>
- Helm chart source: <https://github.com/horse-framework/helm-chart>
- Issues: <https://github.com/horse-framework/helm-chart/issues>

## License

[Apache License 2.0](LICENSE)
