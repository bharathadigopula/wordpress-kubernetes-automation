#!/usr/bin/env bash

#==============================================================================
# WORDPRESS KUBERNETES REPOSITORY VALIDATION
#==============================================================================

set -euo pipefail

#==============================================================================
# REQUIRED FILE VALIDATION
#==============================================================================

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
required_files=(Chart.yaml values.yaml scripts/bootstrap.sh scripts/manage.sh templates/backup-cronjob.yaml templates/restore-job.yaml templates/network-policies.yaml templates/nginx-configmap.yaml templates/redis-deployment.yaml templates/redis-service.yaml templates/wordpress-cronjob.yaml templates/wordpress-deployment.yaml templates/wordpress-php-configmap.yaml templates/wordpress-service.yaml templates/wordpress-pvc.yaml templates/mariadb-statefulset.yaml templates/mariadb-service.yaml templates/ingress.yaml)
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
if [[ "$image_digest_count" -ne 5 ]]; then
  printf 'WordPress, NGINX, Redis, MariaDB, and Restic images must use immutable SHA-256 digests.\n' >&2
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

if ! grep -Fq "\$_SERVER['HTTPS'] = 'on';" "$repository_root/templates/wordpress-deployment.yaml" || \
  grep -Fq "HTTP_X_FORWARDED_PROTO" "$repository_root/templates/wordpress-deployment.yaml"; then
  printf 'WordPress must enforce HTTPS behind the production proxy chain.\n' >&2
  exit 1
fi

if ! grep -Fq 'until mariadb-dump --host=mariadb' "$repository_root/templates/backup-cronjob.yaml" || \
  ! grep -Fq "if [ \"\$attempt\" -ge 30 ]; then" "$repository_root/templates/backup-cronjob.yaml" || \
  ! grep -Fq 'sleep 5' "$repository_root/templates/backup-cronjob.yaml"; then
  printf 'WordPress backup must tolerate transient database connectivity.\n' >&2
  exit 1
fi

if ! grep -Fq 'name: prepare-wordpress-webroot' "$repository_root/templates/wordpress-deployment.yaml" || \
  ! grep -Fq 'mkdir -p /extensions/themes /extensions/plugins /nginx-cache' "$repository_root/templates/wordpress-deployment.yaml" || \
  ! grep -Fq 'runAsUser: 0' "$repository_root/templates/wordpress-deployment.yaml" || \
  ! grep -Fq -- '- CHOWN' "$repository_root/templates/wordpress-deployment.yaml"; then
  printf 'WordPress deployment must prepare writable extension directories.\n' >&2
  exit 1
fi

if ! grep -Fq 'claimName: wordpress-extensions' "$repository_root/templates/wordpress-deployment.yaml" || \
  [[ "$(grep -Fc 'subPath: themes' "$repository_root/templates/wordpress-deployment.yaml")" != "2" ]] || \
  [[ "$(grep -Fc 'subPath: plugins' "$repository_root/templates/wordpress-deployment.yaml")" != "2" ]] || \
  ! grep -Fq "define('FS_METHOD', 'direct');" "$repository_root/templates/wordpress-deployment.yaml" || \
  ! grep -Fq 'memory_limit = 512M' "$repository_root/templates/wordpress-php-configmap.yaml" || \
  ! grep -Fq 'upload_max_filesize = 128M' "$repository_root/templates/wordpress-php-configmap.yaml"; then
  printf 'WordPress must support persistent dashboard-managed extensions.\n' >&2
  exit 1
fi

if ! grep -Fq 'client_max_body_size 128m;' "$repository_root/templates/nginx-configmap.yaml" || \
  ! grep -Fq 'gzip on;' "$repository_root/templates/nginx-configmap.yaml" || \
  ! grep -Fq 'expires 30d;' "$repository_root/templates/nginx-configmap.yaml" || \
  ! grep -Fq 'opcache.enable = 1' "$repository_root/templates/wordpress-php-configmap.yaml" || \
  ! grep -Fq 'opcache.validate_timestamps = 1' "$repository_root/templates/wordpress-php-configmap.yaml" || \
  ! grep -Fq "define('WP_POST_REVISIONS', 10);" "$repository_root/templates/wordpress-deployment.yaml"; then
  printf 'WordPress must retain the dashboard-compatible performance baseline.\n' >&2
  exit 1
fi

if ! grep -Fq 'fastcgi_cache WORDPRESS;' "$repository_root/templates/nginx-configmap.yaml" || \
  ! grep -Fq "fastcgi_cache_bypass \$skip_cache;" "$repository_root/templates/nginx-configmap.yaml" || \
  ! grep -Fq 'fastcgi_cache_valid 200 60s;' "$repository_root/templates/nginx-configmap.yaml" || \
  ! grep -Fq "define('DISABLE_WP_CRON', true);" "$repository_root/templates/wordpress-deployment.yaml" || \
  ! grep -Fq "define('WP_REDIS_CLIENT', 'predis');" "$repository_root/templates/wordpress-deployment.yaml" || \
  ! grep -Fq "wp_using_ext_object_cache()" "$repository_root/scripts/manage.sh"; then
  printf 'WordPress must retain cache-safe dynamic performance controls.\n' >&2
  exit 1
fi

if ! grep -Fq 'map $http_x_forwarded_proto $redirect_https {' "$repository_root/templates/nginx-configmap.yaml" || \
  ! grep -Fq 'return 301 https://$host$request_uri;' "$repository_root/templates/nginx-configmap.yaml" || \
  ! grep -Fq 'add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;' "$repository_root/templates/nginx-configmap.yaml" || \
  ! grep -Fq 'add_header Content-Security-Policy' "$repository_root/templates/nginx-configmap.yaml" || \
  ! grep -Fq 'location = /robots.txt {' "$repository_root/templates/nginx-configmap.yaml" || \
  ! grep -Fq 'location = /wp-sitemap.xml {' "$repository_root/templates/nginx-configmap.yaml"; then
  printf 'WordPress must retain launch-ready HTTPS, security header, and discovery controls.\n' >&2
  exit 1
fi

if ! grep -Fq 'app.kubernetes.io/component: cron' "$repository_root/templates/network-policies.yaml" || \
  ! grep -Fq 'port: 6379' "$repository_root/templates/network-policies.yaml" || \
  ! grep -Fq 'chmod -R u+rwX /extensions' "$repository_root/templates/wordpress-deployment.yaml"; then
  printf 'WordPress performance services must retain isolated writable connectivity.\n' >&2
  exit 1
fi

if ! grep -Fq 'restic backup --tag wordpress /backup/database.sql /extensions /uploads' "$repository_root/templates/backup-cronjob.yaml" || \
  ! grep -Fq 'cp -a /restore/extensions/. /extensions/' "$repository_root/templates/restore-job.yaml"; then
  printf 'WordPress backup and restore must include dashboard-managed extensions.\n' >&2
  exit 1
fi

if [[ "$(grep -Fc 'apply -f - >/dev/null' "$repository_root/scripts/manage.sh")" != "4" ]] || \
  ! grep -Fq -- '--set imagePullSecrets[0].name=wordpress-registry >/dev/null' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'rollout status deployment/wordpress --timeout=10m >/dev/null' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'mkdir -p /var/www/html/wp-content/themes' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'chmod -R u+rwX /var/www/html/wp-content/themes' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'cp -R /usr/src/wordpress/wp-content/themes/bharathcoudops /var/www/html/wp-content/themes/.bharathcoudops.next' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'mv /var/www/html/wp-content/themes/.bharathcoudops.next /var/www/html/wp-content/themes/bharathcoudops' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "exec -i deployment/wordpress -c wordpress -- php >/dev/null" "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "define('WP_INSTALLING', true);" "$repository_root/scripts/manage.sh" || \
  [[ "$(grep -Fc "if (!is_blog_installed())" "$repository_root/scripts/manage.sh")" != "2" ]] || \
  ! grep -Fq 'wordpress_initialization=failed reason=installation_postcondition' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'wordpress_initialization=failed reason=object_cache_unavailable' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "'^x-fastcgi-cache:[[:space:]]*HIT'" "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "update_option('template', \$theme)" "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "update_option('stylesheet', \$theme)" "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'wordpress_initialization=failed reason=theme_postcondition' "$repository_root/scripts/manage.sh"; then
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