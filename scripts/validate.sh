#!/usr/bin/env bash

#==============================================================================
# WORDPRESS KUBERNETES REPOSITORY VALIDATION
#==============================================================================

set -euo pipefail

#==============================================================================
# REQUIRED FILE VALIDATION
#==============================================================================

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
required_files=(Chart.yaml values.yaml scripts/bootstrap.sh scripts/manage.sh templates/backup-cronjob.yaml templates/restore-job.yaml templates/network-policies.yaml templates/nginx-configmap.yaml templates/wordpress-deployment.yaml templates/wordpress-service.yaml templates/wordpress-pvc.yaml templates/mariadb-statefulset.yaml templates/mariadb-service.yaml templates/ingress.yaml)
for required_file in "${required_files[@]}"; do
  [[ -f "$repository_root/$required_file" ]] || { printf 'Missing required file: %s\n' "$required_file" >&2; exit 1; }
done

#==============================================================================
# SECRET AND IMAGE VALIDATION
#==============================================================================

if grep -R --line-number --extended-regexp '(password|secret|accessKey|access_key)[[:space:]]*:[[:space:]]*[^{$[:space:]\"]+' "$repository_root/values.yaml" "$repository_root/templates"; then
  printf 'Potential literal secret detected in Helm configuration.\n' >&2
  exit 1
fi

if grep -R --line-number --extended-regexp 'image:[[:space:]]+[^[:space:]]+:latest([[:space:]]|$)' "$repository_root/templates"; then
  printf 'Container images must use pinned tags.\n' >&2
  exit 1
fi

image_digest_count=$(grep -Ec '^[[:space:]]+digest:[[:space:]]+sha256:[[:xdigit:]]{64}$' "$repository_root/values.yaml")
if [[ "$image_digest_count" -ne 4 ]]; then
  printf 'WordPress, NGINX, MariaDB, and Restic images must use immutable SHA-256 digests.\n' >&2
  exit 1
fi

#==============================================================================
# K3S PROVISIONING VALIDATION
#==============================================================================

grep -Fq 'k3s_version=v1.36.4+k3s1' "$repository_root/scripts/manage.sh"
grep -Fq "sha256sum --check --status" "$repository_root/scripts/manage.sh"
grep -Fq 'sudo systemctl enable --now k3s' "$repository_root/scripts/manage.sh"
grep -Fq "if [[ \"\$action\" == \"deploy\" ]]; then" "$repository_root/scripts/manage.sh"
grep -Fq 'k3s_installation=required' "$repository_root/scripts/manage.sh"

#==============================================================================
# HELM VALIDATION
#==============================================================================

if command -v helm >/dev/null 2>&1; then
  helm lint "$repository_root"
  helm template wordpress "$repository_root" --namespace wordpress >/dev/null
  helm template wordpress "$repository_root" --namespace wordpress \
    --set backup.enabled=true \
    --set backup.restore.enabled=true \
    --set backup.restore.id=validation >/dev/null
elif command -v docker >/dev/null 2>&1; then
  helm_image=alpine/helm:3.19.0@sha256:aef9b56f64e866207d9591d0abd8f6d767b36aadd12edf68f8a719716d9d29c9
  helm_chart=/chart
  helm_mount=(--volume "$repository_root:/chart:ro")
  if [[ -n "${JENKINS_CONTAINER_ID:-}" || -f /.dockerenv ]]; then
    jenkins_container_id="${JENKINS_CONTAINER_ID:-${HOSTNAME:-}}"
    helm_chart="$repository_root"
    helm_mount=(--volumes-from "$jenkins_container_id" --workdir "$repository_root")
  fi
  docker run --rm "${helm_mount[@]}" "$helm_image" lint "$helm_chart"
  docker run --rm "${helm_mount[@]}" "$helm_image" template wordpress "$helm_chart" --namespace wordpress >/dev/null
  docker run --rm "${helm_mount[@]}" "$helm_image" template wordpress "$helm_chart" \
    --namespace wordpress --set backup.enabled=true \
    --set backup.restore.enabled=true --set backup.restore.id=validation >/dev/null
else
  printf 'Helm or Docker is required for chart validation.\n' >&2
  exit 1
fi

if [[ "$(grep -Fc 'apply -f - >/dev/null' "$repository_root/scripts/manage.sh")" != "4" ]] || \
  ! grep -Fq -- '--set imagePullSecrets[0].name=wordpress-registry >/dev/null' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'rollout status deployment/wordpress --timeout=10m >/dev/null' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "exec -i deployment/wordpress -c wordpress -- php >/dev/null" "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "define('WP_INSTALLING', true);" "$repository_root/scripts/manage.sh" || \
  [[ "$(grep -Fc "if (!is_blog_installed())" "$repository_root/scripts/manage.sh")" != "2" ]] || \
  ! grep -Fq 'wordpress_initialization=failed reason=installation_postcondition' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "switch_theme('bharathcoudops')" "$repository_root/scripts/manage.sh"; then
  printf 'Deployment success output must preserve the OCI readiness marker.\n' >&2
  exit 1
fi

if ! grep -Fq 'get deployment,statefulset,service,ingress,cronjob,networkpolicy >/dev/null' "$repository_root/scripts/manage.sh"; then
  printf 'Status success output must preserve the OCI readiness marker.\n' >&2
  exit 1
fi

if ! grep -Fq "create job --from=cronjob/wordpress-backup \"\$backup_job\" >/dev/null" "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "wait --for=condition=complete \"job/\$backup_job\" --timeout=30m >/dev/null" "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "logs \"job/\$backup_job\" --all-containers --tail=8" "$repository_root/scripts/manage.sh"; then
  printf 'Backup success output must preserve the OCI readiness marker.\n' >&2
  exit 1
fi

printf 'wordpress_kubernetes_validation=ready\n'