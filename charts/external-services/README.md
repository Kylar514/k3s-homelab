# External Services

Single source of truth for all services running **outside** the K8s cluster that
need to be accessible via Traefik ingress. When a service moves into K8s, delete
its file here.

---

## Pattern

Each file in `templates/` is fully self-contained — Service + EndpointSlice +
IngressRoute for one external service. Nothing is split across files.

### Basic Template

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  namespace: infra # or whichever namespace makes sense
spec:
  clusterIP: None
  ports:
    - name: http
      port: 80
      targetPort: 80
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: my-service
  namespace: infra
  labels:
    kubernetes.io/service-name: my-service # must match Service name exactly
addressType: IPv4
ports:
  - name: http
    protocol: TCP
    port: 80
endpoints:
  - addresses:
      - 10.0.40.x # IP of the external host
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

> **Why EndpointSlice and not Endpoints?** ArgoCD excludes `Endpoints` resources
> globally by default. `EndpointSlice` is the modern replacement and ArgoCD
> manages it without issue.

---

## Special Cases

Some services require Traefik middleware for headers, websockets, or other
passthrough config. Define the Middleware in the same file, then reference it in
the IngressRoute.

### Proxmox

Proxmox requires skipping TLS verification (self-signed cert) and passing
specific headers.

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: proxmox-headers
  namespace: infra
spec:
  headers:
    customRequestHeaders:
      X-Forwarded-Proto: 'https'
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
      middlewares:
        - name: proxmox-headers
      services:
        - name: proxmox
          port: 8006
          serversTransport: proxmox-transport # see ServersTransport below
  tls:
    certResolver: letsencrypt
---
# Required to skip TLS verification for Proxmox's self-signed cert
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata:
  name: proxmox-transport
  namespace: infra
spec:
  insecureSkipVerify: true
```

### Jellyfin

Jellyfin requires websocket passthrough for streaming to work correctly.

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
    secret: my-service-basicauth # K8s Secret with htpasswd format
```

---

## Current External Services

| File                     | Domain                | Host              | Port | Notes                        |
| ------------------------ | --------------------- | ----------------- | ---- | ---------------------------- |
| `adguard-primary.yaml`   | adguard.thenasus.com  | nasus `10.0.40.3` | 85   | Primary DNS, origin for sync |
| `adguard-secondary.yaml` | adguard2.thenasus.com | Pi (TBD)          | 80   | Secondary DNS, replica       |

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
