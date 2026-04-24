# ArgoCD v3.3.8 — High Availability Architecture Reference

## Component Summary

| Component | HA Replicas | Scalable? | Anti-affinity | Notes |
|-----------|-------------|-----------|---------------|-------|
| argocd-server | 3+ | Horizontal | Yes | Stateless; configure `ARGOCD_API_SERVER_REPLICAS` |
| argocd-repo-server | 2+ | Horizontal | Yes | Controls manifest generation; tune parallelism |
| argocd-application-controller | 1–N (sharded) | Sharding | Yes | One leader per shard; set `ARGOCD_CONTROLLER_REPLICAS` |
| argocd-redis | 3 (Sentinel) | Fixed | Yes | HA requires exactly 3 nodes |
| argocd-dex-server | 1 | No | No | In-memory; multi-instance breaks state |
| argocd-applicationset-controller | 2 | Leader election | Yes | Active/standby; 2 for redundancy |
| argocd-notifications-controller | 1 | No | No | Single instance only |

**Minimum cluster nodes for HA:** 3 worker nodes (pod anti-affinity rules enforce this).

---

## Application Controller Sharding

The application controller is the component most likely to bottleneck at scale. Shard clusters across multiple replicas.

### Configure sharding

Set in the application controller Deployment:
```yaml
env:
  - name: ARGOCD_CONTROLLER_REPLICAS
    value: "3"   # must match spec.replicas
```

Set in `argocd-cmd-params-cm` ConfigMap:
```yaml
data:
  controller.sharding.algorithm: consistent-hashing
```

### Sharding algorithms

| Algorithm | Stability | Recommendation |
|-----------|-----------|----------------|
| `legacy` | Stable | Default; UID-based, non-uniform distribution |
| `round-robin` | Experimental | Even distribution but reshuffles on replica changes |
| `consistent-hashing` | Experimental | Bounded loads, minimal reshuffling — use for scale |

### Processor tuning (for large deployments)

Configure in the application controller args:
```yaml
args:
  - /usr/local/bin/argocd-application-controller
  - --status-processors=50        # default: 20; increase for >200 apps
  - --operation-processors=25     # default: 10; increase for high sync rate
  - --app-resync-jitter-percentage=25
```

Rule of thumb:
- Up to 100 apps: defaults are fine
- 100–500 apps: `--status-processors=30`, `--operation-processors=15`, 2–3 controller replicas
- 500+ apps: `--status-processors=50`, `--operation-processors=25`, 3+ controller replicas with consistent-hashing

---

## Repo Server Scaling

The repo server handles manifest generation (Helm, Kustomize, Jsonnet). Scale it to handle parallel app syncs.

### Parallelism limit

Prevent OOM by limiting concurrent manifest generation:
```yaml
args:
  - /usr/local/bin/argocd-repo-server
  - --parallelismlimit=10   # default: 0 (unlimited); set based on available memory
```

### Monorepo caching optimisation

Add annotation to Applications pointing to a monorepo to speed up cache invalidation:
```yaml
metadata:
  annotations:
    argocd.argoproj.io/manifest-generate-paths: apps/my-service
```

Set cache expiry (default 24h is fine; lower for fast-changing repos):
```yaml
# argocd-cmd-params-cm
data:
  reposerver.repo.cache.expiration: 24h
```

---

## Redis HA (Sentinel)

In HA mode, ArgoCD uses Redis with Sentinel for automatic failover. The HA install manifest pre-configures this.

Key facts:
- Fixed at 3 nodes (1 primary, 2 replicas) + 3 Sentinel processes
- Sentinels detect primary failure and promote a replica
- Requires no extra configuration unless you need auth

### Redis password (recommended for production)

Set in `argocd-secret`:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: argocd-secret
  namespace: argocd
stringData:
  redis-password: "your-strong-redis-password"
```

Configure in `argocd-cmd-params-cm`:
```yaml
data:
  redis.password: ""   # leave empty — pulled from argocd-secret automatically
```

---

## Resource Recommendations

### argocd-server (per replica)

```yaml
resources:
  requests:
    cpu: 250m
    memory: 256Mi
  limits:
    cpu: 2000m
    memory: 512Mi
```

### argocd-application-controller (per shard)

```yaml
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 4000m
    memory: 2Gi
```

### argocd-repo-server (per replica)

```yaml
resources:
  requests:
    cpu: 250m
    memory: 256Mi
  limits:
    cpu: 2000m
    memory: 1Gi   # higher for Helm/Kustomize heavy workloads
```

---

## Horizontal Pod Autoscaling

argocd-server and argocd-repo-server are HPA-friendly (stateless):

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: argocd-server-hpa
  namespace: argocd
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: argocd-server
  minReplicas: 3
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

Do NOT use HPA on the application controller — sharding requires manual replica management.

---

## argocd-cmd-params-cm (global parameter overrides)

Preferred way to tune component flags without patching Deployment manifests directly:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
data:
  # Application controller
  controller.sharding.algorithm: consistent-hashing
  controller.status.processors: "30"
  controller.operation.processors: "15"

  # Repo server
  reposerver.parallelism.limit: "10"
  reposerver.repo.cache.expiration: 24h

  # Server
  server.insecure: "false"
  server.enable.gzip: "true"

  # Redis
  redis.compression: gzip
```

---

## Checking HA Health

```bash
# All HA components running
kubectl -n argocd get pods

# Application controller sharding status
kubectl -n argocd exec -it statefulset/argocd-application-controller -- \
  argocd-application-controller --help | grep sharding

# Redis Sentinel status
kubectl -n argocd exec -it argocd-redis-ha-0 -- \
  redis-cli -p 26379 SENTINEL masters

# Check controller logs for shard assignments
kubectl -n argocd logs statefulset/argocd-application-controller | grep shard
```
