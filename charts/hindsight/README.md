# Hindsight

Runs Hindsight's all-in-one image with its embedded pg0 database in the `apps`
namespace.

Before syncing the chart, create the OpenCode API key in Vault:

```bash
vault kv put secret/hindsight opencode-api-key=<key>
```

The chart only reads that value through the cluster's `vault`
`ClusterSecretStore`; it does not manage Vault itself.

Add these AdGuard rewrites to `10.0.40.8`:

- `hindsight.thenasus.com` for the UI
- `api.hindsight.thenasus.com` for the API

Data is stored on an 8 GiB `nfs-fast` PVC. The image runs as UID/GID 1000, so
the provisioned volume must be writable by that user.
