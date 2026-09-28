<!--
==============================================================================
WORDPRESS KUBERNETES AUTOMATION
==============================================================================
-->

# WordPress Kubernetes Automation

Versioned Helm automation for the production WordPress, MariaDB, Redis, NGINX,
backup, restore, and network-policy workloads.

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

## 🔒 Safety

- Images use immutable SHA-256 digests.
- Secrets are injected at deployment time and never committed.
- Backup and restore run through the managed lifecycle workflow.
