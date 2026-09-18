#!/usr/bin/env bash

#==============================================================================
# WORDPRESS KUBERNETES LIFECYCLE
#==============================================================================

set -euo pipefail

#==============================================================================
# LIFECYCLE INPUTS
#==============================================================================

action="${1:-validate}"
image_repository="${2:-}"
image_tag="${3:-}"
image_digest="${4:-}"
hostname="${5:-ignitox.bharathcloudops.com}"
restore_snapshot="${6:-latest}"
operation_id="${7:-manual}"
database_secrets="${8:-}"
backup_secrets="${9:-}"
registry_secrets="${10:-}"
namespace=wordpress
release=wordpress
kubeconfig=/etc/rancher/k3s/k3s.yaml
k3s_version=v1.36.4+k3s1
repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

case "$action" in
  validate|deploy|backup|restore|status)
    ;;
  *)
    printf 'Unsupported WordPress action: %s\n' "$action" >&2
    exit 2
    ;;
esac

if [[ ! "$hostname" =~ ^[a-z0-9.-]+$ ]] || \
  [[ ! "$operation_id" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || \
  [[ ! "$restore_snapshot" =~ ^[A-Za-z0-9:._/-]+$ ]]; then
  printf 'Invalid WordPress lifecycle inputs.\n' >&2
  exit 2
fi

#==============================================================================
# KUBERNETES AND HELM COMMANDS
#==============================================================================

kubectl_command=(sudo /usr/local/bin/k3s kubectl --kubeconfig "$kubeconfig")
helm_command=(sudo env KUBECONFIG="$kubeconfig" /usr/local/bin/helm)

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
  if [[ ! -r "$repository_root/Chart.yaml" ]]; then
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
  --set-string ingress.hostname="$hostname"
  --set backup.enabled=true
)

#==============================================================================
# SECRET RECONCILIATION
#==============================================================================

reconcile_secrets() {
  jq -e 'type == "object" and (.wordpress_database_password | strings | length >= 24) and (.mariadb_root_password | strings | length >= 24)' <<< "$database_secrets" >/dev/null
  jq -e 'type == "object" and (.RESTIC_REPOSITORY | strings | length > 0) and (.RESTIC_PASSWORD | strings | length >= 24) and (.AWS_ACCESS_KEY_ID | strings | length > 0) and (.AWS_SECRET_ACCESS_KEY | strings | length > 0)' <<< "$backup_secrets" >/dev/null
  jq -e 'type == "object" and (.username | strings | length > 0) and (.token | strings | length >= 20)' <<< "$registry_secrets" >/dev/null

  "${kubectl_command[@]}" create namespace "$namespace" --dry-run=client -o yaml | "${kubectl_command[@]}" apply -f - >/dev/null
  "${kubectl_command[@]}" --namespace "$namespace" create secret generic wordpress-secrets \
    --from-literal="wordpress-database-password=$(jq -r .wordpress_database_password <<< "$database_secrets")" \
    --from-literal="mariadb-root-password=$(jq -r .mariadb_root_password <<< "$database_secrets")" \
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
    reconcile_secrets
    "${helm_command[@]}" upgrade --install "$release" "$repository_root" \
      "${helm_values[@]}" --create-namespace --atomic --cleanup-on-fail --wait \
      --timeout 15m --history-max 10 \
      --set-string wordpress.image.repository="$image_repository" \
      --set-string wordpress.image.tag="$image_tag" \
      --set-string wordpress.image.digest="$image_digest" \
      --set imagePullSecrets[0].name=wordpress-registry >/dev/null
    "${kubectl_command[@]}" --namespace "$namespace" rollout status deployment/wordpress --timeout=10m >/dev/null
    printf 'wordpress_deploy=ready\n'
    ;;
  backup)
    backup_job="wordpress-backup-${operation_id}"
    "${kubectl_command[@]}" --namespace "$namespace" create job --from=cronjob/wordpress-backup "$backup_job"
    "${kubectl_command[@]}" --namespace "$namespace" wait --for=condition=complete "job/$backup_job" --timeout=30m
    "${kubectl_command[@]}" --namespace "$namespace" logs "job/$backup_job" --all-containers
    printf 'wordpress_backup=ready\n'
    ;;
  restore)
    restore_job="wordpress-restore-${operation_id}"
    replicas=$("${kubectl_command[@]}" --namespace "$namespace" get deployment wordpress -o jsonpath='{.spec.replicas}')
    restore_application() {
      "${kubectl_command[@]}" --namespace "$namespace" scale deployment wordpress --replicas="$replicas" >/dev/null
    }
    trap restore_application EXIT
    "${kubectl_command[@]}" --namespace "$namespace" scale deployment wordpress --replicas=0
    "${kubectl_command[@]}" --namespace "$namespace" wait --for=delete pod \
      --selector=app.kubernetes.io/name=wordpress,app.kubernetes.io/component=application --timeout=10m
    "${helm_command[@]}" template "$release" "$repository_root" "${helm_values[@]}" \
      --show-only templates/restore-job.yaml \
      --set backup.restore.enabled=true \
      --set-string backup.restore.id="$operation_id" \
      --set-string backup.restore.snapshot="$restore_snapshot" |
      "${kubectl_command[@]}" apply -f -
    "${kubectl_command[@]}" --namespace "$namespace" wait --for=condition=complete "job/$restore_job" --timeout=30m
    "${kubectl_command[@]}" --namespace "$namespace" logs "job/$restore_job" --all-containers
    restore_application
    trap - EXIT
    "${kubectl_command[@]}" --namespace "$namespace" rollout status deployment/wordpress --timeout=10m
    printf 'wordpress_restore=ready\n'
    ;;
  status)
    "${kubectl_command[@]}" --namespace "$namespace" get deployment,statefulset,service,ingress,cronjob,networkpolicy
    printf 'wordpress_status=ready\n'
    ;;
esac