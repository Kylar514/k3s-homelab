# External Services

Single source of truth for all services running **outside** the K8s cluster that
need to be accessible via Traefik ingress. When a service moves into K8s, delete
its file here.

---

## Prerequisites

Traefik must have `allowExternalNameServices: true` set in its config. This is
already configured in `traefik-config` chart via `HelmChartConfig`. Without it,
ExternalName services will return 404.

---

## Pattern

Each file in `templates/` is fully self-contained — Service + IngressRoute for
one external service. Uses Kubernetes `ExternalName` service type which Traefik
resolves directly to the external IP. No EndpointSlice or Endpoints needed.

### Basic Template

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  namespace: infra
spec:
  type: ExternalName
  externalName: 10.0.40.x # IP of the external host
  ports:
    - name: http
      port: 80
      targetPort: 80
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: my-service
  namespace: infra
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`my-service.thenasus.com`)
      kind: Rule
      services:
        - name: my-service
          port: 80
  tls:
    certResolver: letsencrypt
```

> **Why ExternalName?** ExternalName services route directly to an external IP
> without needing Endpoints or EndpointSlice objects. ArgoCD excludes both
> Endpoints and EndpointSlice by default, making ExternalName the correct
> GitOps-friendly pattern for external services. Requires
> `allowExternalNameServices: true` in Traefik config.

---

## Special Cases

Some services require Traefik middleware for headers, websockets, or TLS
passthrough. Define the Middleware in the same file, then reference it in the
IngressRoute.

### Proxmox

Proxmox uses a self-signed cert and requires TLS verification to be skipped.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: proxmox
  namespace: infra
spec:
  type: ExternalName
  externalName: 10.0.40.x
  ports:
    - name: https
      port: 8006
      targetPort: 8006
---
# Required to skip TLS verification for Proxmox's self-signed cert
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata:
  name: proxmox-transport
  namespace: infra
spec:
  insecureSkipVerify: true
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: proxmox
  namespace: infra
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`proxmox.thenasus.com`)
      kind: Rule
      services:
        - name: proxmox
          port: 8006
          serversTransport: proxmox-transport
  tls:
    certResolver: letsencrypt
```

### Jellyfin

Jellyfin requires websocket passthrough and specific headers for streaming to
work.

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: jellyfin-headers
  namespace: infra
spec:
  headers:
    customRequestHeaders:
      X-Forwarded-Proto: 'https'
      X-Real-IP: ''
---
apiVersion: v1
kind: Service
metadata:
  name: jellyfin
  namespace: infra
spec:
  type: ExternalName
  externalName: 10.0.40.x
  ports:
    - name: http
      port: 8096
      targetPort: 8096
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: jellyfin
  namespace: infra
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`jellyfin.thenasus.com`)
      kind: Rule
      middlewares:
        - name: jellyfin-headers
      services:
        - name: jellyfin
          port: 8096
  tls:
    certResolver: letsencrypt
```

### Services Requiring Basic Auth

If an external service has no built-in auth, add Traefik BasicAuth middleware.
Credentials go in a K8s Secret, not hardcoded here.

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: my-service-auth
  namespace: infra
spec:
  basicAuth:
    secret: my-service-basicauth # K8s Secret with htpasswd encoded credentials
```

---

## Adding a New Service

1. Copy the basic template above into a new file `templates/<service-name>.yaml`
2. Update name, namespace, IP, port, and domain
3. Add any required middleware (see Special Cases above)
4. Add a row to the table above
5. Push — ArgoCD deploys automatically

## Removing a Service (migrated to K8s)

1. Delete the file from `templates/`
2. Push — ArgoCD prunes the resources automatically
3. Remove the row from the table above
