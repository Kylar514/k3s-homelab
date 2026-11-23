# Inputs: $routes $svcs $pods $docker $vms (slurped), $nasus (nasus IPs), $extra (extraProbes)
($svcs[0].items) as $svcs
| ($pods[0].items) as $pods
| ($vms[0]) as $vms
| [$docker[0].data.result[].metric
   | {name, ports: ((.ports // "") | split(",") | map(select(. != "")))}] as $containers
| $nasus[0] as $nasusIP

# where an IP lives: nasus, a Proxmox guest name, or just the IP
| def loc($ip):
    if any($nasus[]; . == $ip) then "nasus"
    else ([$vms[] | select(.ip == $ip) | .name] | first // $ip) end;

# nasus container publishing this port
  def owner($ip; $port):
    if any($nasus[]; . == $ip)
    then [$containers[] | select(any(.ports[]; . == ($port | tostring))) | .name] | first
    else null end;

# first container of a pod behind this Service (so names line up with workloads)
  def podname($svc):
    ($svc.spec.selector // {}) as $sel
    | if ($sel | length) == 0 then null
      else [$pods[]
            | select(.metadata.namespace == $svc.metadata.namespace)
            | select((.metadata.labels // {}) as $l | all($sel | to_entries[]; $l[.key] == .value))
            | .spec.containers[0].name] | first
      end;

  def app($svc):
    if $svc.spec.type == "ExternalName" then
      $svc.spec.externalName as $ip
      | { name: ([$svc.spec.ports[]? | owner($ip; .port) | select(.)] | first // $svc.metadata.name),
          location: loc($ip), ip: $ip }
    else
      { name: (podname($svc) // $svc.metadata.name),
        location: ("k3s/" + $svc.metadata.namespace),
        # only LAN-reachable addresses (LoadBalancer = node IPs); cluster IPs are noise
        ip: ([$svc.status.loadBalancer.ingress[]?.ip] | join(",")) }
    end;

  def ports: map(tonumber) | unique | map(tostring) | join(",");

# direct = TCP connect to every Service port and every published nasus port
[ $svcs[]
  | select(.spec.type == "ExternalName" or .spec.clusterIP != "None")
  | . as $s | app($s) as $a
  | $s.spec.ports[]? | select((.protocol // "TCP") == "TCP")
  | { target: (if $s.spec.type == "ExternalName"
               then "\($s.spec.externalName):\(.port)"
               else "\($s.metadata.name).\($s.metadata.namespace).svc:\(.port)" end),
      name: $a.name, location: $a.location, ip: $a.ip, port: (.port | tostring) } ]
+ [ $containers[] | .name as $n | .ports[]
    | { target: "\($nasusIP):\(.)", name: $n, location: "nasus", ip: $nasusIP, port: . } ]
| . as $direct

# traefik = HTTPS to every Host() in every IngressRoute, plus the manual extras
| [ $routes[0].items[] | . as $r
    | .spec.routes[]?
    | [(.match // "") | scan("Host\\(`([^`]+)`\\)") | .[0]] as $hosts
    | (.services // [])[0] // empty
    | select((.kind // "Service") == "Service")
    | (.namespace // $r.metadata.namespace) as $ns | .name as $sn
    | ([$svcs[] | select(.metadata.name == $sn and .metadata.namespace == $ns)] | first) as $s
    | (if $s then app($s) else {name: $sn, location: ("k3s/" + $ns)} end) as $a
    | $hosts[] | {target: "https://\(.)", name: $a.name, location: $a.location, host: .} ]
  + [ $extra[] | { target: .public, name: .name, location: (.location // "nasus"),
                   host: (.public | sub("^https?://"; "") | sub("/.*"; "")) } ]
| unique_by(.target) as $http

| {
    http: [ $http[] | {targets: [.target], labels: {name, location, host, via: "traefik"}} ],
    tcp: [ $direct | unique_by(.target)[] | . as $d
           | [$direct[] | select(.name == $d.name and .location == $d.location)] as $same
           | { targets: [.target],
               labels: { name, location, via: "direct",
                         ports: ([$same[].port] | ports),
                         ip: ([$same[].ip | select(. != "") | split(",")[]] | unique | join(",")),
                         hosts: ([$http[] | select(.name == $d.name and .location == $d.location) | .host] | unique | join(",")) } } ],
    icmp: [ $vms[] | .ip as $ip
            | { targets: [$ip],
                labels: { id, vm: .name, ip: $ip, via: "ping",
                          ports: ([$direct[] | select(.ip | split(",") | any(. == $ip)) | .port] | ports) } } ]
  }
