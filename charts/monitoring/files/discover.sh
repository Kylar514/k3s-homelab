#!/bin/sh
# Builds blackbox probe target lists (Prometheus file_sd) from what's actually running:
# Traefik IngressRoutes, k8s Services, nasus docker containers (read back from
# Prometheus) and Proxmox guests. Output: ConfigMap probe-targets, mounted into Prometheus.
set -eu
cd /tmp

kubectl get ingressroutes.traefik.io -A -o json > routes.json
kubectl get services -A -o json > svcs.json
kubectl get pods -A -o json > pods.json

curl -sf "$PROM_URL/api/v1/query" --data-urlencode 'query=docker_container_info' > docker.json \
  || echo '{"data":{"result":[]}}' > docker.json

# Proxmox guests + IP: cloud-init ipconfig0 / lxc net0, else the qemu guest agent
AUTH="Authorization: PVEAPIToken=$PVE_USER!$PVE_TOKEN_NAME=$PVE_TOKEN_VALUE"
pve() { curl -sfk -H "$AUTH" "$PVE_URL/api2/json$1"; }
pve '/cluster/resources?type=vm' > res.json || echo '{"data":[]}' > res.json
jq -r '.data[] | select(.template != 1) | "\(.node) \(.type) \(.vmid) \(.name)"' res.json > guests.txt
: > vms.jsonl
while read -r node type vmid name; do
  ip=$(pve "/nodes/$node/$type/$vmid/config" \
    | jq -r '[.data.ipconfig0, .data.net0] | map(select(.) | capture("ip=(?<ip>[0-9.]+)").ip) | first // empty' || true)
  if [ -z "$ip" ] && [ "$type" = qemu ]; then
    ip=$(pve "/nodes/$node/qemu/$vmid/agent/network-get-interfaces" \
      | jq -r '[.data.result[]?."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address" | select(startswith("127.") | not)] | first // empty' || true)
  fi
  if [ -n "$ip" ]; then
    jq -nc --arg id "$type/$vmid" --arg name "$name" --arg ip "$ip" '{id: $id, name: $name, ip: $ip}' >> vms.jsonl
  fi
done < guests.txt
jq -s . vms.jsonl > vms.json

jq -n \
  --slurpfile routes routes.json --slurpfile svcs svcs.json --slurpfile pods pods.json \
  --slurpfile docker docker.json --slurpfile vms vms.json \
  --argjson nasus "$NASUS_IPS" --argjson extra "$EXTRA_PROBES" \
  -f /scripts/targets.jq > targets.json

for f in http tcp icmp; do jq ".$f" targets.json > "$f.json"; done
kubectl create configmap probe-targets -n "$NAMESPACE" \
  --from-file=http.json --from-file=tcp.json --from-file=icmp.json \
  --dry-run=client -o yaml | kubectl apply -f -
echo "http=$(jq '.http | length' targets.json) tcp=$(jq '.tcp | length' targets.json) icmp=$(jq '.icmp | length' targets.json)"
