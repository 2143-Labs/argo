#!/usr/bin/env bash
set -euo pipefail

readonly CHART_DIR='workloads/vpn-endpoints'
readonly APPLICATION_SET='apps/vpn-endpoints.yaml'
readonly EXPECTED_ELEMENTS='scripts/vpn-endpoints-expected.json'

fail() {
  printf 'vpn-endpoints validation failed: %s\n' "$1" >&2
  exit 1
}

for command_name in helm yq jq cmp mktemp bash grep; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "required command not found: ${command_name}"
done

[[ -d "${CHART_DIR}" ]] || fail "chart not found: ${CHART_DIR}"
[[ -f "${APPLICATION_SET}" ]] || fail "ApplicationSet not found: ${APPLICATION_SET}"
[[ -f "${EXPECTED_ELEMENTS}" ]] || fail "expected element inventory not found: ${EXPECTED_ELEMENTS}"
jq -e 'type == "array"' "${EXPECTED_ELEMENTS}" >/dev/null || fail 'expected element inventory must be a JSON array'

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

render() {
  local name="$1"
  local country="$2"
  local hostname="$3"
  local pvc_name="$4"
  local replicas="$5"
  local rotation_nonce="$6"
  local output="$7"

  helm template "${name}" "${CHART_DIR}" \
    --namespace vpn-endpoints \
    --set-string "name=${name}" \
    --set-string "country=${country}" \
    --set-string "hostname=${hostname}" \
    --set-string "pvcName=${pvc_name}" \
    --set "replicas=${replicas}" \
    --set "mullvadRotationNonce=${rotation_nonce}" >"${output}"
}

assert_jq() {
  local input="$1"
  local expression="$2"
  local message="$3"
  shift 3

  jq -e "$@" "${JQ_DEFS}${expression}" "${input}" >/dev/null || fail "${message}"
}

readonly JQ_DEFS='
  def docs: map(select(type == "object"));
  def object($kind; $name): first(docs[] | select(.kind == $kind and .metadata.name == $name));
  def deployment($name): object("Deployment"; $name);
  def configmap($name): object("ConfigMap"; $name);
  def init($deployment; $name): first($deployment.spec.template.spec.initContainers[] | select(.name == $name));
  def container($deployment; $name): first($deployment.spec.template.spec.containers[] | select(.name == $name));
  def envmap($container): ($container.env // [] | map({key: .name, value: .value}) | from_entries);
  def commandtext($container): ([($container.command // [])[], ($container.args // [])[]] | join("\n"));
  def has_mount($container; $volume; $path; $readonly):
    any($container.volumeMounts[]?; .name == $volume and .mountPath == $path and (.readOnly // false) == $readonly);
  def common_labels($object; $name; $country):
    $object.metadata.labels["app.kubernetes.io/name"] == $name and
    $object.metadata.labels["app.kubernetes.io/part-of"] == "vpn-endpoints" and
    $object.metadata.labels["vpn.2143.me/endpoint"] == $name and
    $object.metadata.labels["vpn.2143.me/country"] == $country;
  def capability($role; $group; $resource; $verbs):
    any($role.rules[]?; . as $rule |
      ($rule.apiGroups | index($group)) != null and
      ($rule.resources | index($resource)) != null and
      all($verbs[]; . as $verb | ($rule.verbs | index($verb)) != null));
'

validate_application_set() {
  local json="${work_dir}/application-set.json"
  local expected_sorted="${work_dir}/expected-elements.json"
  local actual_sorted="${work_dir}/actual-elements.json"

  yq eval -o=json -I=0 '.' "${APPLICATION_SET}" >"${json}"

  assert_jq "${json}" '
    .apiVersion == "argoproj.io/v1alpha1" and
    .kind == "ApplicationSet" and
    .metadata.name == "vpn-endpoints" and
    .metadata.namespace == "argocd" and
    .spec.goTemplate == true and
    .spec.goTemplateOptions == ["missingkey=error"]
  ' 'ApplicationSet identity or strict Go-template settings are incorrect'

  assert_jq "${json}" '
    .spec.generators as $generators |
    ($generators | length) == 1 and
    ($generators[0] | keys) == ["list"] and
    ($generators[0].list | keys) == ["elements"] and
    all($generators[0].list.elements[];
      (keys | sort) == (["country","hostname","mullvadRotationNonce","name","pvcName","replicas"] | sort) and
      (.name | type == "string" and test("^vpn-[a-z]{2}$")) and
      (.country | type == "string" and length > 0) and
      .hostname == .name and
      .pvcName == (.name + "-state") and
      (.replicas == 0 or .replicas == 1) and
      (.mullvadRotationNonce | type == "number") and
      (has("bootstrap") | not) and
      (has("tags") | not))
  ' 'ApplicationSet elements violate endpoint identity, state, or single-tag invariants'

  jq -S 'sort_by(.name)' "${EXPECTED_ELEMENTS}" >"${expected_sorted}"
  jq -S '.spec.generators[0].list.elements | sort_by(.name)' "${json}" >"${actual_sorted}"
  cmp -s "${expected_sorted}" "${actual_sorted}" || fail 'ApplicationSet elements differ from scripts/vpn-endpoints-expected.json'

  assert_jq "${json}" '
    .spec.template.metadata.name == "vpn-endpoint-{{.name}}" and
    .spec.template.metadata.finalizers == [
      "resources-finalizer.argocd.argoproj.io",
      "pre-delete-finalizer.argocd.argoproj.io",
      "pre-delete-finalizer.argocd.argoproj.io/cleanup"
    ] and
    .spec.template.spec.project == "default" and
    .spec.template.spec.source.repoURL == "https://github.com/2143-Labs/argo.git" and
    .spec.template.spec.source.targetRevision == "HEAD" and
    .spec.template.spec.source.path == "workloads/vpn-endpoints" and
    .spec.template.spec.source.helm.releaseName == "{{.name}}" and
    .spec.template.spec.destination.server == "https://kubernetes.default.svc" and
    .spec.template.spec.destination.namespace == "vpn-endpoints" and
    .spec.template.spec.syncPolicy.automated == {"prune":true,"selfHeal":true} and
    (.spec.template.spec.syncPolicy.syncOptions | index("CreateNamespace=true")) != null
  ' 'generated Application source, destination, finalizer, or sync policy is incorrect'

  assert_jq "${json}" '
    .spec.template.spec.source.helm.parameters == [
      {"name":"name","value":"{{.name}}"},
      {"name":"country","value":"{{.country}}"},
      {"name":"hostname","value":"{{.hostname}}"},
      {"name":"pvcName","value":"{{.pvcName}}"},
      {"name":"replicas","value":"{{.replicas}}"},
      {"name":"mullvadRotationNonce","value":"{{.mullvadRotationNonce}}"}
    ]
  ' 'Helm parameters must be exactly the six approved endpoint values in canonical order'
}

validate_scripts() {
  local json="$1"
  local name="$2"
  local enroll_script="${work_dir}/${name}-enroll.sh"
  local deregister_script="${work_dir}/${name}-deregister.sh"

  jq -er --arg name "${name}" "${JQ_DEFS}configmap(\$name).data[\"enroll.sh\"]" "${json}" >"${enroll_script}" \
    || fail 'ConfigMap enroll.sh is absent or empty'
  jq -er --arg name "${name}" "${JQ_DEFS}configmap(\$name).data[\"deregister.sh\"]" "${json}" >"${deregister_script}" \
    || fail 'ConfigMap deregister.sh is absent or empty'
  bash -n "${enroll_script}" || fail 'rendered enroll.sh has invalid shell syntax'
  bash -n "${deregister_script}" || fail 'rendered deregister.sh has invalid shell syntax'

  if grep -Eq '(^|[;&|])[[:space:]]*set[[:space:]]+-x([[:space:]]|$)' "${enroll_script}" "${deregister_script}"; then
    fail 'lifecycle scripts must not enable shell tracing'
  fi
  if grep -Eiq '(echo|printf).*(\$\{?(TOKEN|PRIV|PRIVATE_KEY)|wireguard_private_key)' "${enroll_script}" "${deregister_script}"; then
    fail 'lifecycle scripts may print a token or private key'
  fi

  for literal in \
    'auth/v1/token' \
    'accounts/v1/devices' \
    '/pubkey' \
    'mullvad.json' \
    'wg genkey' \
    'hijack_dns'; do
    grep -Fq "${literal}" "${enroll_script}" || fail "enroll.sh is missing required lifecycle operation: ${literal}"
  done
  grep -Fq '/var/lib/vpn-endpoint/mullvad.json.new' "${enroll_script}" || fail 'enroll.sh must write Mullvad state atomically through mullvad.json.new'
  grep -Fq 'umask 077' "${enroll_script}" || fail 'enroll.sh must protect persisted Mullvad state with umask 077'
  grep -Fq 'kubectl create configmap' "${enroll_script}" || fail 'enroll.sh must publish non-secret Mullvad identity to Kubernetes'
  grep -Fq -- '-identity' "${enroll_script}" || fail 'enroll.sh must target the endpoint identity ConfigMap'
  if grep -Eq 'hijack_dns[^}]*name[[:space:]]*:' "${enroll_script}"; then
    fail 'Mullvad create request must not send an unsupported device name'
  fi

  for literal in \
    'kubectl scale' \
    'accounts/v1/devices' \
    'headscale nodes delete' \
    'kubectl delete pvc'; do
    grep -Fq "${literal}" "${deregister_script}" || fail "deregister.sh is missing required teardown operation: ${literal}"
  done
  grep -Fq -- '-identity' "${deregister_script}" || fail 'deregister.sh must consume and delete the endpoint identity ConfigMap'
}

validate_manifest() {
  local json="$1"
  local name="$2"
  local country="$3"
  local hostname="$4"
  local pvc_name="$5"
  local replicas="$6"
  local rotation_nonce="$7"
  local country_slug
  country_slug="$(printf '%s' "${country}" | tr '[:upper:] ' '[:lower:]-')"

  assert_jq "${json}" '
    (docs | length) == 12 and
    ([docs[] | .kind + "/" + .metadata.name + "/" + (if (.kind == "Role" or .kind == "RoleBinding") and .metadata.name == ($name + "-deregister-headscale") then (.metadata.namespace // "default") else (.metadata.namespace // "vpn-endpoints") end)] | sort) == ([
      "ServiceAccount/vpn-endpoint-" + $name + "/vpn-endpoints",
      "ConfigMap/" + $name + "/vpn-endpoints",
      "PersistentVolumeClaim/" + $pvc + "/vpn-endpoints",
      "Deployment/" + $name + "/vpn-endpoints",
      "ServiceAccount/" + $name + "-deregister/vpn-endpoints",
      "Role/" + $name + "-identity-writer/vpn-endpoints",
      "RoleBinding/" + $name + "-identity-writer/vpn-endpoints",
      "Role/" + $name + "-deregister/vpn-endpoints",
      "RoleBinding/" + $name + "-deregister/vpn-endpoints",
      "Role/" + $name + "-deregister-headscale/default",
      "RoleBinding/" + $name + "-deregister-headscale/default",
      "Job/" + $name + "-deregister/vpn-endpoints"
    ] | sort)
  ' 'release must render exactly the workload, PVC, identity sync, lifecycle Job, and narrow RBAC objects' \
    --arg name "${name}" --arg pvc "${pvc_name}"

  assert_jq "${json}" '
    deployment($name) as $d |
    $d.spec.replicas == $replicas and
    $d.spec.strategy.type == "Recreate" and
    $d.spec.template.spec.serviceAccountName == ("vpn-endpoint-" + $name) and
    $d.spec.template.spec.automountServiceAccountToken == false and
    ($d.spec.template.spec.hostNetwork // false) == false and
    $d.spec.template.spec.dnsConfig.options == [{"name":"ndots","value":"1"}] and
    ($d.spec.template.spec.dnsConfig.searches? == null) and
    common_labels($d; $name; $country) and
    common_labels($d.spec.template; $name; $country) and
    $d.spec.template.metadata.annotations["reloader.stakater.com/auto"] == "true" and
    $d.spec.template.metadata.annotations["vpn.2143.me/rotate-mullvad"] == $nonce
  ' 'Deployment identity, replicas, workload isolation, labels, reloader, or rotation annotation is incorrect' \
    --arg name "${name}" --arg country "${country_slug}" --arg nonce "${rotation_nonce}" --argjson replicas "${replicas}"

  assert_jq "${json}" '
    common_labels(object("ServiceAccount"; ("vpn-endpoint-" + $name)); $name; $country) and
    common_labels(object("ServiceAccount"; ($name + "-deregister")); $name; $country) and
    common_labels(object("Role"; ($name + "-identity-writer")); $name; $country) and
    common_labels(object("RoleBinding"; ($name + "-identity-writer")); $name; $country) and
    common_labels(object("Role"; ($name + "-deregister")); $name; $country) and
    common_labels(object("RoleBinding"; ($name + "-deregister")); $name; $country) and
    common_labels(object("Role"; ($name + "-deregister-headscale")); $name; $country) and
    common_labels(object("RoleBinding"; ($name + "-deregister-headscale")); $name; $country) and
    common_labels(object("Job"; ($name + "-deregister")).spec.template; $name; $country)
  ' 'all workload, lifecycle, and RBAC objects must carry endpoint and normalized country labels' \
    --arg name "${name}" --arg country "${country_slug}"

  assert_jq "${json}" '
    deployment($name) as $d |
    [$d.spec.template.spec.initContainers[].name] == ["enroll","gluetun"] and
    [$d.spec.template.spec.containers[].name] == ["tailscale"] and
    init($d; "gluetun").restartPolicy == "Always" and
    all(($d.spec.template.spec.initContainers + $d.spec.template.spec.containers)[];
      (.image | type == "string" and length > 0 and test("^[^[:space:]]+(@sha256:[0-9a-f]{64}|:sha-[0-9a-f]{40})$"))) and
    init($d; "enroll").image == object("Job"; ($name + "-deregister")).spec.template.spec.containers[0].image
  ' 'container order, restartable Gluetun init, or digest-pinned images are incorrect' --arg name "${name}"

  assert_jq "${json}" '
    configmap($name) as $cm |
    ($cm.data | keys | sort) == (["deregister.sh","enroll.sh","hostname","rotation-nonce"] | sort) and
    $cm.data.hostname == $hostname and
    $cm.data["rotation-nonce"] == $nonce and
    common_labels($cm; $name; $country)
  ' 'ConfigMap must contain exactly both lifecycle scripts, hostname, and rotation nonce' \
    --arg name "${name}" --arg country "${country_slug}" --arg hostname "${hostname}" --arg nonce "${rotation_nonce}"

  assert_jq "${json}" '
    deployment($name) as $d |
    init($d; "enroll") as $enroll |
    $enroll.command[0:2] == ["/bin/sh","-ec"] and
    (commandtext($enroll) | contains("/etc/vpn-endpoint/enroll.sh")) and
    has_mount($enroll; "config"; "/etc/vpn-endpoint"; true) and
    has_mount($enroll; "vpn-endpoint-state"; "/var/lib/vpn-endpoint"; false) and
    has_mount($enroll; "account-secret"; "/etc/mullvad-account"; true) and
    has_mount($enroll; "runtime-secrets"; "/run/secrets"; false) and
    (($enroll.volumeMounts | map(.mountPath) | unique | length) == ($enroll.volumeMounts | length)) and
    $enroll.securityContext.runAsUser == 0 and
    $enroll.securityContext.allowPrivilegeEscalation == false and
    $enroll.securityContext.readOnlyRootFilesystem == true and
    $enroll.securityContext.capabilities.drop == ["ALL"] and
    ($enroll.securityContext.capabilities.add // []) == [] and
    ($enroll.securityContext.privileged // false) == false
  ' 'enroll init command, secret/state mounts, or least-privilege security context is incorrect' --arg name "${name}"

  assert_jq "${json}" '
    deployment($name) as $d |
    init($d; "enroll") as $enroll |
    ($d.spec.template.spec.volumes | first(.[] | select(.name == "enroll-api-credentials"))) as $api |
    (first($api.projected.sources[] | select(.serviceAccountToken? != null)).serviceAccountToken) as $token |
    $token.path == "token" and
    $token.expirationSeconds == 3600 and
    has_mount($enroll; "enroll-api-credentials"; "/var/run/secrets/kubernetes.io/serviceaccount"; true) and
    all(([$d.spec.template.spec.initContainers[], $d.spec.template.spec.containers[]] | map(select(.name != "enroll")))[];
      all(.volumeMounts[]?; .name != "enroll-api-credentials"))
  ' 'Kubernetes API credentials must be projected only into enroll while workload automount remains disabled' --arg name "${name}"

  assert_jq "${json}" '
    deployment($name) as $d |
    (envmap(init($d; "gluetun"))) as $env |
    $env == {
      "VPN_SERVICE_PROVIDER":"mullvad",
      "VPN_TYPE":"wireguard",
      "SERVER_COUNTRIES":$country,
      "WIREGUARD_PRIVATE_KEY_SECRETFILE":"/run/secrets/wireguard_private_key",
      "WIREGUARD_ADDRESSES_SECRETFILE":"/run/secrets/wireguard_addresses"
    } and
    init($d; "gluetun").startupProbe.exec.command == ["/gluetun-entrypoint","healthcheck"] and
    init($d; "gluetun").readinessProbe.exec.command == ["/gluetun-entrypoint","healthcheck"]
  ' 'Gluetun provider, country, runtime secret paths, or health probes are incorrect' \
    --arg name "${name}" --arg country "${country}"

  assert_jq "${json}" '
    deployment($name) as $d |
    (envmap(container($d; "tailscale"))) == {
      "TS_USERSPACE":"false",
      "TS_STATE_DIR":"/var/lib/tailscale",
      "TS_KUBE_SECRET":"",
      "TS_AUTH_ONCE":"true",
      "TS_ACCEPT_DNS":"false",
      "TS_ENABLE_HEALTH_CHECK":"true",
      "TS_LOCAL_ADDR_PORT":"127.0.0.1:9002",
      "TS_BOOT_TIMEOUT":"180s",
      "TS_HOSTNAME":$hostname,
      "TS_AUTHKEY":"file:/etc/tailscale/auth_key",
      "TS_EXTRA_ARGS":"--login-server=https://net.john2143.com --advertise-exit-node --accept-routes=false"
    } and
    container($d; "tailscale").readinessProbe.exec.command == ["wget","-qO-","http://127.0.0.1:9002/healthz"] and
    has_mount(container($d; "tailscale"); "tailscale-auth-secret"; "/etc/tailscale"; true) and
    has_mount(container($d; "tailscale"); "tailscale-state"; "/var/lib/tailscale"; false) and
    ((container($d; "tailscale").volumeMounts | map(.mountPath) | unique | length) == (container($d; "tailscale").volumeMounts | length)) and
    all(container($d; "tailscale").volumeMounts[]; .name != "runtime-secrets")
  ' 'Tailscale must use the reusable file key, durable state, and exact health settings; the endpoint tag must come from the preauth key (headscale rejects a client-requested tag when the key already carries it)' \
    --arg name "${name}" --arg hostname "${hostname}"

  assert_jq "${json}" '
    deployment($name) as $d |
    container($d; "tailscale").command[0] == "/bin/sh" and
    container($d; "tailscale").command[1] == "-ec" and
    (container($d; "tailscale").command[2]
      | contains("iptables-nft")
        and contains("ip -6 rule add to fd7a:115c:a1e0::/48 lookup 52 priority 97")
        and contains("ip rule add to 100.64.0.0/10 lookup 52 priority 97")
        and contains("TCPMSS --clamp-mss-to-pmtu")
        and contains("exec /usr/local/bin/containerboot")) and
    container($d; "tailscale").args == null
  ' 'Tailscale must run a startup wrapper that repairs the nft backend, routes tailnet replies, clamps MSS, then execs containerboot' --arg name "${name}"

  assert_jq "${json}" '
    deployment($name) as $d |
    ($d.spec.template.spec.volumes | first(.[] | select(.name == "account-secret"))) as $account |
    ($d.spec.template.spec.volumes | first(.[] | select(.name == "tailscale-auth-secret"))) as $auth |
    ($d.spec.template.spec.volumes | first(.[] | select(.name == "runtime-secrets"))) as $runtime |
    ($d.spec.template.spec.volumes | first(.[] | select(.name == "tun"))) as $tun |
    $account.secret.secretName == "mullvad-account" and
    $auth.secret.secretName == "tailscale-bootstrap" and
    $runtime.emptyDir.medium == "Memory" and
    $tun.hostPath == {"path":"/dev/net/tun","type":"CharDevice"} and
    ([docs[] | tostring] | join("\n") | test("openbao|ctmpl|bootstrap[[:space:]_-]*mode"; "i") | not) and
    all(($d.spec.template.spec.initContainers + $d.spec.template.spec.containers)[];
      all(.env[]?; .valueFrom? == null and (.name | IN("ACCOUNT_NUMBER","MULLVAD_TOKEN","WIREGUARD_PRIVATE_KEY") | not)))
  ' 'ESO Secret volumes, memory runtime, TUN device, or absence of direct OpenBao artifacts is incorrect' --arg name "${name}"

  assert_jq "${json}" '
    deployment($name) as $d |
    all(($d.spec.template.spec.initContainers + $d.spec.template.spec.containers)[];
      .securityContext.runAsUser == 0 and
      .securityContext.allowPrivilegeEscalation == false and
      .securityContext.capabilities.drop == ["ALL"] and
      (.securityContext.privileged // false) == false) and
    init($d; "gluetun").securityContext.capabilities.add == ["NET_ADMIN"] and
    container($d; "tailscale").securityContext.capabilities.add == ["NET_ADMIN"] and
    $d.spec.template.spec.securityContext.seccompProfile.type == "RuntimeDefault" and
    (($d.spec.template.spec.securityContext | has("sysctls")) | not)
  ' 'container capabilities, privilege boundaries, seccomp, or forwarding checks are incorrect' --arg name "${name}"

  assert_jq "${json}" '
    deployment($name) as $d |
    init($d; "enroll").resources == {"requests":{"cpu":"50m","memory":"64Mi"},"limits":{"cpu":"250m","memory":"128Mi"}} and
    init($d; "gluetun").resources == {"requests":{"cpu":"50m","memory":"128Mi"},"limits":{"cpu":"1","memory":"512Mi"}} and
    container($d; "tailscale").resources == {"requests":{"cpu":"50m","memory":"128Mi"},"limits":{"cpu":"2","memory":"512Mi"}}
  ' 'container resource requests and limits must remain bounded' --arg name "${name}"

  assert_jq "${json}" '
    deployment($name) as $d |
    $d.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms as $terms |
    $d.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution as $anti |
    any($terms[].matchExpressions[]; .key == "kubernetes.io/arch" and .operator == "In" and .values == ["amd64"]) and
    any($terms[].matchExpressions[]; .key == "kubernetes.io/hostname" and .operator == "In" and (.values | sort) == (["arch","big","closet","nas"] | sort)) and
    any($anti[];
      .topologyKey == "kubernetes.io/hostname" and
      .labelSelector.matchExpressions == [{"key":"app.kubernetes.io/part-of","operator":"In","values":["vpn-endpoints"]}])
  ' 'required amd64/hostname affinity or cross-endpoint anti-affinity is incorrect' --arg name "${name}"

  assert_jq "${json}" '
    deployment($name) as $d |
    object("PersistentVolumeClaim"; $pvc) as $claim |
    ($d.spec.template.spec.volumes | first(.[] | select(.name == "vpn-endpoint-state"))) as $endpoint_state |
    ($d.spec.template.spec.volumes | first(.[] | select(.name == "tailscale-state"))) as $tailscale_state |
    common_labels($claim; $name; $country) and
    $claim.metadata.annotations["argocd.argoproj.io/sync-options"] == "Prune=false,Delete=false" and
    $claim.metadata.labels["recurring-job.longhorn.io/default"] == "enabled" and
    $claim.spec.storageClassName == "longhorn-3" and
    $claim.spec.accessModes == ["ReadWriteOnce"] and
    $claim.spec.resources.requests.storage == "1Gi" and
    $endpoint_state.persistentVolumeClaim.claimName == $pvc and
    $tailscale_state.persistentVolumeClaim.claimName == $pvc
  ' 'PVC identity, retention, backup, storage, or both durable state volumes are incorrect' \
    --arg name "${name}" --arg country "${country_slug}" --arg pvc "${pvc_name}"

  assert_jq "${json}" '
    object("Job"; ($name + "-deregister")) as $job |
    $job.metadata.annotations["helm.sh/hook"] == "pre-delete" and
    $job.metadata.annotations["helm.sh/hook-weight"] == "-10" and
    ($job.metadata.annotations["helm.sh/hook-delete-policy"] | split(",") | sort) == (["before-hook-creation","hook-succeeded"] | sort) and
    $job.spec.backoffLimit == 2 and
    $job.spec.activeDeadlineSeconds == 600 and
    common_labels($job; $name; $country) and
    $job.spec.template.spec.serviceAccountName == ($name + "-deregister") and
    $job.spec.template.spec.restartPolicy == "Never" and
    ($job.spec.template.spec.hostNetwork // false) == false and
    ($job.spec.template.spec.containers | length) == 1 and
    $job.spec.template.spec.containers[0].name == "deregister" and
    $job.spec.template.spec.containers[0].command[0:2] == ["/bin/sh","-ec"] and
    $job.spec.template.spec.securityContext.seccompProfile.type == "RuntimeDefault" and
    $job.spec.template.spec.containers[0].securityContext.runAsUser == 0 and
    $job.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation == false and
    $job.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem == true and
    $job.spec.template.spec.containers[0].securityContext.capabilities.drop == ["ALL"] and
    ($job.spec.template.spec.containers[0].securityContext.privileged // false) == false and
    (commandtext($job.spec.template.spec.containers[0]) | contains("/etc/vpn-endpoint/deregister.sh")) and
    all($job.spec.template.spec.containers[0].volumeMounts[]; .name != "vpn-endpoint-state" and .mountPath != "/var/lib/vpn-endpoint") and
    has_mount($job.spec.template.spec.containers[0]; "account-secret"; "/etc/mullvad-account"; true) and
    has_mount($job.spec.template.spec.containers[0]; "runtime-secrets"; "/run/secrets"; false) and
    has_mount($job.spec.template.spec.containers[0]; "config"; "/etc/vpn-endpoint"; true) and
    all($job.spec.template.spec.volumes[]; .name != "vpn-endpoint-state" and .persistentVolumeClaim? == null) and
    any($job.spec.template.spec.volumes[]; .name == "account-secret" and .secret.secretName == "mullvad-account") and
    any($job.spec.template.spec.volumes[]; .name == "runtime-secrets" and .emptyDir.medium == "Memory" and .emptyDir.sizeLimit == "1Mi") and
    any($job.spec.template.spec.volumes[]; .name == "config" and .configMap.name == $name)
  ' 'pre-delete Job must avoid the RWO PVC while retaining account/config/runtime cleanup inputs' \
    --arg name "${name}" --arg country "${country_slug}"

  assert_jq "${json}" '
    object("Role"; ($name + "-identity-writer")) as $writer |
    object("RoleBinding"; ($name + "-identity-writer")) as $writer_binding |
    object("Role"; ($name + "-deregister")) as $local |
    object("Role"; ($name + "-deregister-headscale")) as $headscale |
    object("RoleBinding"; ($name + "-deregister")) as $local_binding |
    object("RoleBinding"; ($name + "-deregister-headscale")) as $headscale_binding |
    object("ServiceAccount"; ($name + "-deregister")) as $sa |
    $writer.metadata.namespace == "vpn-endpoints" and
    any($writer.rules[]; .apiGroups == [""] and .resources == ["configmaps"] and .verbs == ["create"] and (.resourceNames? == null)) and
    any($writer.rules[]; . as $rule | $rule.apiGroups == [""] and $rule.resources == ["configmaps"] and ($rule.resourceNames | index($name + "-identity")) != null and all(["get","update","patch"][]; . as $verb | ($rule.verbs | index($verb)) != null)) and
    $writer_binding.roleRef == {"apiGroup":"rbac.authorization.k8s.io","kind":"Role","name":($name + "-identity-writer")} and
    $writer_binding.subjects == [{"kind":"ServiceAccount","name":("vpn-endpoint-" + $name),"namespace":"vpn-endpoints"}] and
    $local.metadata.namespace == "vpn-endpoints" and
    $headscale.metadata.namespace == "default" and
    capability($local; "apps"; "deployments"; ["get"]) and
    any($local.rules[]; .apiGroups == ["apps"] and .resources == ["deployments/scale"] and (.verbs | sort) == (["get","update","patch"] | sort)) and
    capability($local; ""; "pods"; ["get","list","watch"]) and
    capability($local; ""; "persistentvolumeclaims"; ["get","list","delete"]) and
    any($local.rules[]; . as $rule | $rule.apiGroups == [""] and $rule.resources == ["configmaps"] and ($rule.resourceNames | index($name + "-identity")) != null and all(["get","delete"][]; . as $verb | ($rule.verbs | index($verb)) != null)) and
    capability($headscale; ""; "pods"; ["get","list"]) and
    capability($headscale; ""; "pods/exec"; ["create"]) and
    $local_binding.roleRef == {"apiGroup":"rbac.authorization.k8s.io","kind":"Role","name":($name + "-deregister")} and
    $headscale_binding.roleRef == {"apiGroup":"rbac.authorization.k8s.io","kind":"Role","name":($name + "-deregister-headscale")} and
    $local_binding.subjects == [{"kind":"ServiceAccount","name":($name + "-deregister"),"namespace":"vpn-endpoints"}] and
    $headscale_binding.subjects == [{"kind":"ServiceAccount","name":($name + "-deregister"),"namespace":"vpn-endpoints"}] and
    common_labels($sa; $name; $country)
  ' 'identity writer and deregistration RBAC must be resource-scoped to the endpoint identity while allowing lifecycle cleanup' \
    --arg name "${name}" --arg country "${country_slug}"

  validate_scripts "${json}" "${name}"
}

validate_application_set

readonly NAME='vpn-de'
readonly COUNTRY='Germany'
readonly HOSTNAME='vpn-de'
readonly PVC_NAME='vpn-de-state'
readonly ROTATION_NONCE='7'

for replicas in 0 1; do
  first_render="${work_dir}/replicas-${replicas}-first.yaml"
  second_render="${work_dir}/replicas-${replicas}-second.yaml"
  json="${work_dir}/replicas-${replicas}.json"

  render "${NAME}" "${COUNTRY}" "${HOSTNAME}" "${PVC_NAME}" "${replicas}" "${ROTATION_NONCE}" "${first_render}"
  render "${NAME}" "${COUNTRY}" "${HOSTNAME}" "${PVC_NAME}" "${replicas}" "${ROTATION_NONCE}" "${second_render}"
  cmp -s "${first_render}" "${second_render}" || fail "render is nondeterministic for replicas=${replicas}"
  yq eval-all -o=json -I=0 '[.]' "${first_render}" >"${json}"
  validate_manifest "${json}" "${NAME}" "${COUNTRY}" "${HOSTNAME}" "${PVC_NAME}" "${replicas}" "${ROTATION_NONCE}"
done

printf 'vpn-endpoints validation passed (two replica states, two byte-identical renders each)\n'
