# k3s-homelab

GitOps helm chart repository for the thenasus.com homelab k3s cluster. Managed
by ArgoCD — push to master, ArgoCD deploys automatically.

## Architecture

```
ans-homelab (Ansible)     →  provisions infrastructure, bootstraps k3s + ArgoCD
k3s-homelab (this repo)   →  everything running inside k3s
```

Ansible is the source of truth for infrastructure. This repo is the source of
truth for applications. ArgoCD watches this repo and reconciles the cluster to
match.

## Charts

| Chart              | Namespace        | Description                                    |
| ------------------ | ---------------- | ---------------------------------------------- |
| `nfs-provisioner`  | default          | NFS storage classes (nfs-fast, nfs-slow)       |
| `external-secrets` | external-secrets | Syncs secrets from Vault to Kubernetes         |
| `traefik-config`   | kube-system      | Traefik ACME/Let's Encrypt config, middlewares |
| `argocd-ingress`   | argocd           | Traefik IngressRoute for ArgoCD UI             |

## Storage Classes

Two NFS-backed storage classes are available:

- `nfs-fast` → `10.0.40.3:/srv/fast` (SSD, for active app data)
- `nfs-slow` → `10.0.40.3:/home/zeal/data` (RAID, for backups, media)

Use in a PVC:

```yaml
storageClassName: nfs-fast # or nfs-slow
```

## Secrets

Secrets are managed via HashiCorp Vault on azir-01 and synced to Kubernetes via
external-secrets-operator. A `ClusterSecretStore` named `vault` is available
cluster-wide.

To add a new secret:

1. Store it in Vault: `vault kv put secret/myapp key=value`
2. Create an `ExternalSecret` in your chart referencing the `vault` store

## Adding a New App

1. Create a chart directory: `charts/myapp/`
2. Add `Chart.yaml`, `values.yaml`, and `templates/`
3. Commit and push — ArgoCD detects the change
4. Create the ArgoCD app:

```bash
argocd app create myapp \
  --repo https://github.com/Kylar514/k3s-homelab \
  --path charts/myapp \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace myapp \
  --sync-policy automated \
  --auto-prune \
  --self-heal \
  --sync-option CreateNamespace=true
```

## Ingress

All services are exposed via Traefik with Let's Encrypt wildcard cert for
`*.thenasus.com`. Add an IngressRoute to your chart:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: myapp
  namespace: myapp
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`myapp.thenasus.com`)
      kind: Rule
      middlewares:
        - name: redirect-https
          namespace: kube-system
      services:
        - name: myapp
          port: 80
  tls:
    certResolver: letsencrypt
```

Then add a DNS rewrite in AdGuard: `myapp.thenasus.com → 10.0.40.8`

## Notes

- Renovate Bot is planned for automated dependency updates
- ArgoCD UI: https://argocd.thenasus.com
- Port-forward (local):
  `kubectl port-forward svc/argocd-server -n argocd 8080:80` →
  `http://localhost:8080`
