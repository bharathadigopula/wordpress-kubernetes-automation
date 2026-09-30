<!--
==============================================================================
WORDPRESS KUBERNETES AUTOMATION
==============================================================================
-->

# WordPress Kubernetes Automation

Versioned Helm automation for the production WordPress, MariaDB, Redis, NGINX,
backup, restore, and network-policy workloads.

Each WordPress project owns its non-secret deployment profile. The lifecycle accepts that validated JSON profile and applies the same released chart with a site-specific namespace, release, hostname, image, storage, PHP, WordPress, Nginx, and backup policy. Credentials remain in OCI Vault and are supplied only to the selected site namespace.

## ✅ Validation

`01 - Validate WordPress Kubernetes Automation` runs on a free GitHub-hosted
runner because this repository is public. It checks shell scripts, image digests,
Helm templates, secrets, backup behavior, and readiness markers.

```bash
shellcheck --exclude=SC2016 scripts/*.sh
bash scripts/validate.sh
```

## 🚀 Deployment

Production changes run through `09 - Configure Production WordPress` in the
private `bharath-oci-host-config` repository. Validation uses the OCI `validate`
runner and lifecycle changes use the OCI `deploy` runner. Direct cluster commands
from local machines are not part of the production path.

| Action | Behaviour |
|---|---|
| `validate` | Validate release sources and runtime prerequisites without changing the cluster |
| `deploy` | Reconcile only the selected site with `helm upgrade --install --atomic --wait` |
| `status` | Read deployment, StatefulSet, service, ingress, CronJob, and network-policy state |
| `backup` | Start the selected site's backup CronJob and wait for completion |
| `verify-backup` | Restore a selected site-tagged snapshot into temporary storage and verify database, webroot, extensions, and uploads |
| `restore` | Take a pre-restore backup, validate the requested snapshot, replace the selected database/content, and verify the site |

Deploy does not uninstall releases or delete namespaces. It rejects attempts to change the immutable storage class of existing PVCs, adds a retained storage class for future sites, marks bound PVs `Retain`, and relies on the chart's PVC keep policy. Configuration checksums roll only the selected WordPress pod. After rollout, WordPress object cache and Nginx FastCGI cache are cleared and tested.

## 🔒 Safety

- Images use immutable SHA-256 digests.
- Secrets are injected at deployment time and never committed.
- Backup and restore run through the managed lifecycle workflow.
- Production restore callers must provide an explicit snapshot and site-scoped confirmation; `latest` is reserved for non-destructive backup verification.
- K3s local-path data survives pod and service restarts but not total host-disk loss. Encrypted off-host Restic snapshots are mandatory.
