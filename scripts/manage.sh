#!/usr/bin/env bash

#==============================================================================
# WORDPRESS KUBERNETES LIFECYCLE
#==============================================================================

set -euo pipefail

#==============================================================================
# LIFECYCLE INPUTS
#==============================================================================

action="${1:-validate}"
chart_repository="${2:-}"
chart_ref="${3:-}"
image_repository="${4:-}"
image_tag="${5:-}"
image_digest="${6:-}"
hostname="${7:-ignitox.bharathcloudops.com}"
site_title="${8:-WordPress}"
admin_user="${9:-wordpress-admin}"
admin_email="${10:-wordpress@example.invalid}"
restore_snapshot="${11:-latest}"
operation_id="${12:-manual}"
site_profile_encoded="${13:-}${14:-}${15:-}${16:-}${17:-}${18:-}${19:-}${20:-}"
database_secrets="${21:-}"
backup_secrets="${22:-}"
registry_secrets="${23:-}"
kubeconfig=/etc/rancher/k3s/k3s.yaml
k3s_version=v1.36.4+k3s1
repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
chart_root="$repository_root/.shared-chart/charts/wordpress"

case "$action" in
  validate|deploy|backup|verify-backup|restore|status)
    ;;
  *)
    printf 'Unsupported WordPress action: %s\n' "$action" >&2
    exit 2
    ;;
esac

if [[ ! "$hostname" =~ ^[a-z0-9.-]+$ ]] || \
  [[ ! "$chart_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
  [[ ! "$chart_ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  [[ -z "$site_title" || ! "$admin_user" =~ ^[A-Za-z0-9._-]+$ || ! "$admin_email" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || \
  [[ ! "$operation_id" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || \
  [[ ! "$restore_snapshot" =~ ^[A-Za-z0-9:._/-]+$ ]]; then
  printf 'Invalid WordPress lifecycle inputs.\n' >&2
  exit 2
fi

if [[ ! "$site_profile_encoded" =~ ^[A-Za-z0-9+/]+=*$ ]] || \
  ! site_profile=$(printf '%s' "$site_profile_encoded" | base64 --decode 2>/dev/null) || \
  ! jq -e '
  type == "object" and
  (.site_id | type == "string" and test("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")) and
  (.namespace | type == "string" and test("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")) and
  (.release | type == "string" and test("^[a-z0-9]([a-z0-9-]{0,51}[a-z0-9])?$")) and
  (.storage.class | type == "string" and test("^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$")) and
  all(.storage.uploads, .storage.core, .storage.extensions, .storage.database; type == "string" and test("^[1-9][0-9]*(Mi|Gi)$")) and
  (.php.memoryLimit | type == "string" and test("^[1-9][0-9]*M$")) and
  (.php.uploadMaxFilesize | type == "string" and test("^[1-9][0-9]*M$")) and
  (.php.postMaxSize | type == "string" and test("^[1-9][0-9]*M$")) and
  all(.php.maxExecutionTime, .php.maxInputTime, .php.maxInputVars, .php.opcacheInternedStringsBuffer, .php.opcacheMaxAcceleratedFiles, .php.opcacheMemoryConsumption; type == "number" and . > 0) and
  (.wordpress.memoryLimit | type == "string" and test("^[1-9][0-9]*M$")) and
  (.wordpress.maxMemoryLimit | type == "string" and test("^[1-9][0-9]*M$")) and
  all(.wordpress.autosaveInterval, .wordpress.postRevisions, .wordpress.emptyTrashDays; type == "number" and . >= 0) and
  (.nginx.clientMaxBodySize | type == "string" and test("^[1-9][0-9]*m$")) and
  (.backup.tag | type == "string" and test("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")) and
  (.backup.schedule | type == "string" and length > 0 and (contains("\\n") | not)) and
  all(.backup.daily, .backup.weekly, .backup.monthly; type == "number" and . > 0)
' <<< "$site_profile" >/dev/null; then
  printf 'Invalid WordPress site profile.\n' >&2
  exit 2
fi

site_id=$(jq -r .site_id <<< "$site_profile")
namespace=$(jq -r .namespace <<< "$site_profile")
release=$(jq -r .release <<< "$site_profile")
storage_class=$(jq -r .storage.class <<< "$site_profile")
site_values_file=$(mktemp)
trap 'rm -f "$site_values_file"' EXIT
jq '{
  wordpress: {
    persistence: {storageClass: .storage.class, size: .storage.uploads, coreSize: .storage.core, extensionsSize: .storage.extensions},
    configuration: .wordpress,
    php: .php
  },
  nginx: {clientMaxBodySize: .nginx.clientMaxBodySize},
  mariadb: {persistence: {storageClass: .storage.class, size: .storage.database}},
  backup: {enabled: true, tag: .backup.tag, schedule: .backup.schedule, retention: {daily: .backup.daily, weekly: .backup.weekly, monthly: .backup.monthly}}
}' <<< "$site_profile" > "$site_values_file"

#==============================================================================
# KUBERNETES AND HELM COMMANDS
#==============================================================================

kubectl_command=(sudo /usr/local/bin/k3s kubectl --kubeconfig "$kubeconfig")
helm_command=(sudo env KUBECONFIG="$kubeconfig" /usr/local/bin/helm)

prepare_chart() {
  rm -rf "$repository_root/.shared-chart"
  mkdir -p "$repository_root/.shared-chart"
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    "https://github.com/${chart_repository}/archive/refs/tags/${chart_ref}.tar.gz" |
    tar --extract --gzip --directory "$repository_root/.shared-chart" --strip-components=1
  [[ -r "$chart_root/Chart.yaml" ]]
}

install_k3s() {
  local architecture checksum download_name temporary_binary

  if sudo test -r "$kubeconfig"; then
    return
  fi
  if sudo systemctl is-active --quiet k3s; then
    printf 'K3s service is active without a readable kubeconfig.\n' >&2
    exit 1
  fi

  architecture=$(uname -m)
  case "$architecture" in
    aarch64|arm64)
      checksum=c920706346d5ad4e5cd3c7bf1bb09ce71ebe07fec829e513e40f1caf98aed8bb
      download_name=k3s-arm64
      ;;
    x86_64|amd64)
      checksum=835873f37245fc615f547a2fe2af9402a347875f13fa64a1f136de644955ea3f
      download_name=k3s
      ;;
    *)
      printf 'Unsupported K3s architecture: %s\n' "$architecture" >&2
      exit 1
      ;;
  esac

  temporary_binary=$(mktemp)
  trap 'rm -f "$temporary_binary"' RETURN
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    "https://github.com/k3s-io/k3s/releases/download/${k3s_version/+/%2B}/${download_name}" \
    --output "$temporary_binary"
  printf '%s  %s\n' "$checksum" "$temporary_binary" | sha256sum --check --status
  sudo install -o root -g root -m 0755 "$temporary_binary" /usr/local/bin/k3s
  sudo install -d -o root -g root -m 0755 /etc/rancher/k3s
  sudo tee /etc/systemd/system/k3s.service >/dev/null <<'EOF'
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
Environment=K3S_KUBECONFIG_MODE=600
ExecStart=/usr/local/bin/k3s server
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
TasksMax=infinity
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now k3s

  for _ in {1..90}; do
    if sudo test -r "$kubeconfig" && "${kubectl_command[@]}" get --raw=/readyz >/dev/null 2>&1; then
      printf 'k3s_installation=ready\n'
      return
    fi
    sleep 2
  done
  sudo systemctl status k3s --no-pager || true
  printf 'K3s did not become ready.\n' >&2
  exit 1
}

install_helm() {
  local architecture checksum archive temporary_directory
  architecture=$(uname -m)
  case "$architecture" in
    aarch64|arm64)
      architecture=arm64
      checksum=440cf7add0aee27ebc93fada965523c1dc2e0ab340d4348da2215737fc0d76ad
      ;;
    x86_64|amd64)
      architecture=amd64
      checksum=a7f81ce08007091b86d8bd696eb4d86b8d0f2e1b9f6c714be62f82f96a594496
      ;;
    *)
      printf 'Unsupported Helm architecture: %s\n' "$architecture" >&2
      exit 1
      ;;
  esac

  if sudo /usr/local/bin/helm version --short 2>/dev/null | grep -Fq 'v3.19.0'; then
    return
  fi

  temporary_directory=$(mktemp -d)
  archive="$temporary_directory/helm.tar.gz"
  trap 'rm -rf "$temporary_directory"' RETURN
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    "https://get.helm.sh/helm-v3.19.0-linux-${architecture}.tar.gz" --output "$archive"
  printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check --status
  tar --extract --gzip --file "$archive" --directory "$temporary_directory"
  sudo install -o root -g root -m 0755 \
    "$temporary_directory/linux-${architecture}/helm" /usr/local/bin/helm
}

validate_runtime() {
  local required_command
  local network_resources

  for required_command in curl jq sha256sum sudo systemctl; do
    if ! command -v "$required_command" >/dev/null; then
      printf 'Required command is unavailable: %s\n' "$required_command" >&2
      return 1
    fi
  done
  if [[ ! -r "$chart_root/Chart.yaml" ]]; then
    printf 'WordPress Helm chart is unreadable.\n' >&2
    return 1
  fi
  if ! sudo test -r "$kubeconfig"; then
    if [[ "$action" == "validate" ]] && ! sudo systemctl is-active --quiet k3s; then
      printf 'k3s_installation=required\n'
      return
    fi
    printf 'K3s kubeconfig is unreadable: %s\n' "$kubeconfig" >&2
    return 1
  fi
  if ! sudo test -x /usr/local/bin/k3s; then
    printf 'K3s binary is unavailable: /usr/local/bin/k3s\n' >&2
    return 1
  fi
  if ! "${kubectl_command[@]}" version >/dev/null; then
    printf 'K3s API is unavailable.\n' >&2
    return 1
  fi
  if ! network_resources=$("${kubectl_command[@]}" api-resources --api-group=networking.k8s.io); then
    printf 'Kubernetes networking API discovery failed.\n' >&2
    return 1
  fi
  if ! grep -Fq networkpolicies <<< "$network_resources"; then
    printf 'Kubernetes NetworkPolicy API is unavailable.\n' >&2
    return 1
  fi
}

helm_values=(
  --namespace "$namespace"
  --values "$site_values_file"
  --set-string ingress.hostname="$hostname"
  --set-string wordpress.siteTitle="$site_title"
  --set-string wordpress.adminUser="$admin_user"
  --set-string wordpress.adminEmail="$admin_email"
)

#==============================================================================
# PERSISTENT STORAGE SAFETY
#==============================================================================

ensure_retained_storage_class() {
  cat <<'STORAGE_CLASS' | "${kubectl_command[@]}" apply -f - >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path-retain
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: rancher.io/local-path
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
STORAGE_CLASS
}

validate_existing_claim_storage() {
  local claim_name
  local existing_storage_class

  for claim_name in wordpress-core wordpress-uploads wordpress-extensions data-mariadb-0; do
    existing_storage_class=$("${kubectl_command[@]}" --namespace "$namespace" get pvc "$claim_name" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
    if [[ -n "$existing_storage_class" && "$existing_storage_class" != "$storage_class" ]]; then
      printf 'PVC %s uses storage class %s; refusing immutable change to %s.\n' "$claim_name" "$existing_storage_class" "$storage_class" >&2
      exit 1
    fi
  done
}

retain_persistent_volumes() {
  local claim_name
  local volume_name

  for claim_name in wordpress-core wordpress-uploads wordpress-extensions data-mariadb-0; do
    volume_name=$("${kubectl_command[@]}" --namespace "$namespace" get pvc "$claim_name" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
    if [[ -n "$volume_name" ]]; then
      "${kubectl_command[@]}" patch persistentvolume "$volume_name" --type merge \
        --patch '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
    fi
  done
}

#==============================================================================
# SECRET RECONCILIATION
#==============================================================================

reconcile_secrets() {
  jq -e 'type == "object" and (.wordpress_database_password | strings | length >= 24) and (.mariadb_root_password | strings | length >= 24) and (.wordpress_admin_password | strings | length >= 24)' <<< "$database_secrets" >/dev/null
  jq -e 'type == "object" and (.RESTIC_REPOSITORY | strings | length > 0) and (.RESTIC_PASSWORD | strings | length >= 24) and (.AWS_ACCESS_KEY_ID | strings | length > 0) and (.AWS_SECRET_ACCESS_KEY | strings | length > 0)' <<< "$backup_secrets" >/dev/null
  jq -e 'type == "object" and (.username | strings | length > 0) and (.token | strings | length >= 20)' <<< "$registry_secrets" >/dev/null

  "${kubectl_command[@]}" create namespace "$namespace" --dry-run=client -o yaml | "${kubectl_command[@]}" apply -f - >/dev/null
  "${kubectl_command[@]}" --namespace "$namespace" create secret generic wordpress-secrets \
    --from-literal="wordpress-database-password=$(jq -r .wordpress_database_password <<< "$database_secrets")" \
    --from-literal="mariadb-root-password=$(jq -r .mariadb_root_password <<< "$database_secrets")" \
    --from-literal="wordpress-admin-password=$(jq -r .wordpress_admin_password <<< "$database_secrets")" \
    --dry-run=client -o yaml | "${kubectl_command[@]}" apply -f - >/dev/null
  "${kubectl_command[@]}" --namespace "$namespace" create secret generic wordpress-backup-secrets \
    --from-literal="RESTIC_REPOSITORY=$(jq -r .RESTIC_REPOSITORY <<< "$backup_secrets")" \
    --from-literal="RESTIC_PASSWORD=$(jq -r .RESTIC_PASSWORD <<< "$backup_secrets")" \
    --from-literal="AWS_ACCESS_KEY_ID=$(jq -r .AWS_ACCESS_KEY_ID <<< "$backup_secrets")" \
    --from-literal="AWS_SECRET_ACCESS_KEY=$(jq -r .AWS_SECRET_ACCESS_KEY <<< "$backup_secrets")" \
    --dry-run=client -o yaml | "${kubectl_command[@]}" apply -f - >/dev/null
  "${kubectl_command[@]}" --namespace "$namespace" create secret docker-registry wordpress-registry \
    --docker-server=ghcr.io \
    --docker-username="$(jq -r .username <<< "$registry_secrets")" \
    --docker-password="$(jq -r .token <<< "$registry_secrets")" \
    --dry-run=client -o yaml | "${kubectl_command[@]}" apply -f - >/dev/null
}

#==============================================================================
# LIFECYCLE ACTIONS
#==============================================================================

prepare_chart
if [[ "$action" == "deploy" ]]; then
  install_k3s
fi
validate_runtime

case "$action" in
  validate)
    printf 'wordpress_validation=ready\n'
    ;;
  deploy)
    if [[ ! "$image_repository" =~ ^[a-z0-9.-]+(/[a-z0-9._-]+)+$ ]] || \
      [[ ! "$image_tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || \
      [[ ! "$image_digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
      printf 'Deployment requires an immutable application image.\n' >&2
      exit 2
    fi
    install_helm
    ensure_retained_storage_class
    validate_existing_claim_storage
    reconcile_secrets
    "${kubectl_command[@]}" label namespace "$namespace" \
      bharathcloudops.com/wordpress-site="$site_id" --overwrite >/dev/null
    "${helm_command[@]}" upgrade --install "$release" "$chart_root" \
      "${helm_values[@]}" --create-namespace --atomic --cleanup-on-fail --wait \
      --timeout 15m --history-max 10 \
      --set-string wordpress.image.repository="$image_repository" \
      --set-string wordpress.image.tag="$image_tag" \
      --set-string wordpress.image.digest="$image_digest" \
      --set imagePullSecrets[0].name=wordpress-registry >/dev/null
    retain_persistent_volumes
    "${kubectl_command[@]}" --namespace "$namespace" rollout status deployment/wordpress --timeout=10m >/dev/null
    "${kubectl_command[@]}" --namespace "$namespace" rollout status deployment/redis --timeout=10m >/dev/null
    "${kubectl_command[@]}" --namespace "$namespace" exec -i deployment/wordpress -c wordpress -- php >/dev/null <<'PHP'
<?php
  define('WP_INSTALLING', true);
require '/var/www/html/wp-load.php';
require_once ABSPATH . 'wp-admin/includes/upgrade.php';
require_once ABSPATH . 'wp-admin/includes/plugin.php';

$new_install = !is_blog_installed();
if ($new_install) {
    $result = wp_install(
        getenv('WORDPRESS_SITE_TITLE'),
        getenv('WORDPRESS_ADMIN_USER'),
        getenv('WORDPRESS_ADMIN_EMAIL'),
        true,
        '',
        getenv('WORDPRESS_ADMIN_PASSWORD')
    );
    if (is_wp_error($result)) {
        fwrite(STDERR, $result->get_error_message() . PHP_EOL);
        exit(1);
    }
}

    wp_cache_flush();
    if (!is_blog_installed()) {
      fwrite(STDERR, "wordpress_initialization=failed reason=installation_postcondition" . PHP_EOL);
      exit(1);
    }

    $active_template = get_option('template');
    $active_stylesheet = get_option('stylesheet');
    wp_cache_flush();
    if (!is_dir(WP_CONTENT_DIR . '/themes/' . $active_template) ||
        !is_dir(WP_CONTENT_DIR . '/themes/' . $active_stylesheet)) {
      fwrite(STDERR, "wordpress_initialization=failed reason=active_theme_missing" . PHP_EOL);
      exit(1);
    }

    $cache_plugin = 'redis-cache/redis-cache.php';
    if (!is_plugin_active($cache_plugin)) {
      $result = activate_plugin($cache_plugin);
      if (is_wp_error($result)) {
        fwrite(STDERR, $result->get_error_message() . PHP_EOL);
        exit(1);
      }
    }

    if (!wp_using_ext_object_cache()) {
      fwrite(STDERR, "wordpress_initialization=failed reason=object_cache_inactive" . PHP_EOL);
      exit(1);
    }

    global $wp_object_cache;
    if (!is_object($wp_object_cache) ||
        !method_exists($wp_object_cache, 'redis_status') ||
        !$wp_object_cache->redis_status()) {
      fwrite(STDERR, "wordpress_initialization=failed reason=redis_connection_unavailable" . PHP_EOL);
      exit(1);
    }

    $cache_key = 'deployment-postcondition';
    if (!wp_cache_set($cache_key, 'ready', 'wordpress-platform', 30) ||
        wp_cache_get($cache_key, 'wordpress-platform') !== 'ready') {
      fwrite(STDERR, "wordpress_initialization=failed reason=object_cache_unavailable" . PHP_EOL);
      exit(1);
    }
    wp_cache_delete($cache_key, 'wordpress-platform');
PHP
    "${kubectl_command[@]}" --namespace "$namespace" exec deployment/wordpress -c nginx -- \
      sh -c 'find /var/cache/nginx/wordpress -mindepth 1 -delete'
    curl --fail --silent --show-error --dump-header /dev/null --output /dev/null "https://$hostname/"
    cache_headers=$(curl --fail --silent --show-error --dump-header - --output /dev/null "https://$hostname/")
    if ! grep -Eiq '^x-fastcgi-cache:[[:space:]]*HIT' <<< "$cache_headers"; then
      printf 'WordPress FastCGI cache postcondition failed.\n' >&2
      exit 1
    fi
    printf 'wordpress_deploy=ready\n'
    ;;
  backup)
    backup_job="wordpress-backup-${operation_id}"
    "${kubectl_command[@]}" --namespace "$namespace" create job --from=cronjob/wordpress-backup "$backup_job" >/dev/null
    "${kubectl_command[@]}" --namespace "$namespace" wait --for=condition=complete "job/$backup_job" --timeout=30m >/dev/null
    backup_output=$("${kubectl_command[@]}" --namespace "$namespace" logs "job/$backup_job" --all-containers --tail=8)
    printf 'wordpress_backup=ready\n'
    printf '%s\n' "$backup_output"
    ;;
  verify-backup)
    verification_job="wordpress-backup-verify-${operation_id}"
    "${helm_command[@]}" template "$release" "$chart_root" "${helm_values[@]}" \
      --show-only templates/backup-verify-job.yaml \
      --set backup.verify.enabled=true \
      --set-string backup.verify.id="$operation_id" \
      --set-string backup.verify.snapshot="$restore_snapshot" |
      "${kubectl_command[@]}" --namespace "$namespace" apply -f - >/dev/null
    if ! "${kubectl_command[@]}" --namespace "$namespace" wait --for=condition=complete \
      "job/$verification_job" --timeout=30m >/dev/null; then
      "${kubectl_command[@]}" --namespace "$namespace" get "job/$verification_job" -o wide || true
      "${kubectl_command[@]}" --namespace "$namespace" get pods \
        --selector="job-name=$verification_job" -o wide || true
      "${kubectl_command[@]}" --namespace "$namespace" describe "job/$verification_job" || true
      "${kubectl_command[@]}" --namespace "$namespace" logs \
        "job/$verification_job" --all-containers --tail=100 || true
      exit 1
    fi
    verification_output=$("${kubectl_command[@]}" --namespace "$namespace" logs \
      "job/$verification_job" --all-containers)
    grep -Fq 'wordpress_backup_verification=ready' <<< "$verification_output"
    printf 'wordpress_verify-backup=ready\n'
    ;;
  restore)
    pre_restore_job="wordpress-backup-before-restore-${operation_id}"
    "${kubectl_command[@]}" --namespace "$namespace" create job --from=cronjob/wordpress-backup "$pre_restore_job" >/dev/null
    "${kubectl_command[@]}" --namespace "$namespace" wait --for=condition=complete "job/$pre_restore_job" --timeout=30m >/dev/null
    restore_job="wordpress-restore-${operation_id}"
    replicas=$("${kubectl_command[@]}" --namespace "$namespace" get deployment wordpress -o jsonpath='{.spec.replicas}')
    restore_application() {
      "${kubectl_command[@]}" --namespace "$namespace" scale deployment wordpress --replicas="$replicas" >/dev/null
    }
    trap restore_application EXIT
    "${kubectl_command[@]}" --namespace "$namespace" scale deployment wordpress --replicas=0
    "${kubectl_command[@]}" --namespace "$namespace" wait --for=delete pod \
      --selector=app.kubernetes.io/name=wordpress,app.kubernetes.io/component=application --timeout=10m
    "${helm_command[@]}" template "$release" "$chart_root" "${helm_values[@]}" \
      --show-only templates/restore-job.yaml \
      --set backup.restore.enabled=true \
      --set-string backup.restore.id="$operation_id" \
      --set-string backup.restore.snapshot="$restore_snapshot" |
      "${kubectl_command[@]}" --namespace "$namespace" apply -f -
    "${kubectl_command[@]}" --namespace "$namespace" wait --for=condition=complete "job/$restore_job" --timeout=30m
    "${kubectl_command[@]}" --namespace "$namespace" logs "job/$restore_job" --all-containers
    restore_application
    trap - EXIT
    "${kubectl_command[@]}" --namespace "$namespace" rollout status deployment/wordpress --timeout=10m
    "${kubectl_command[@]}" --namespace "$namespace" exec -i deployment/wordpress -c wordpress -- php >/dev/null <<'PHP'
<?php
require '/var/www/html/wp-load.php';
if (!is_blog_installed()) {
    exit(1);
}
PHP
    curl --fail --silent --show-error --output /dev/null "https://$hostname/"
    printf 'wordpress_restore=ready\n'
    ;;
  status)
    "${kubectl_command[@]}" --namespace "$namespace" get deployment,statefulset,service,ingress,cronjob,networkpolicy >/dev/null
    printf 'wordpress_status=ready\n'
    ;;
esac