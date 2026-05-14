# OpenShift GitOps Operator Management

This repository contains manifests, guides, and automation scripts for managing OpenShift GitOps (Argo CD) operators on Red Hat OpenShift clusters.

## Directory Structure

- **`guides/`** - Step-by-step installation and configuration guides
  - `01-install-gitops-operator.md` - Installing the GitOps operator via CLI
  - `02-install-nmstate-via-gitops.md` - Managing nmstate operator through Argo CD
- **`scripts/`** - Automation scripts
  - `install-gitops-operator.sh` - Automated GitOps operator installation with verification
  - `uninstall-gitops-operator.sh` - Automated removal of the GitOps operator and all related resources
- **`operators/`** - Kubernetes manifests for operator deployments
  - `gitops/` - Namespace, OperatorGroup, and Subscription for the GitOps operator
  - `nmstate/` - Namespace, OperatorGroup, Subscription, and NMState instance manifests
  - `argocd-applications/` - Argo CD Application resources for GitOps management

## Prerequisites

- Red Hat OpenShift cluster (4.x+)
- `oc` CLI installed and authenticated
- Cluster-admin privileges
- OpenShift Marketplace capability enabled

## Quick Start

To install the GitOps operator automatically, run:

```bash
./scripts/install-gitops-operator.sh
```

For manual installation, follow the guides in the `guides/` directory.

## Uninstalling

To remove the GitOps operator and all related resources, run:

```bash
./scripts/uninstall-gitops-operator.sh
```

To preview what would be removed without making changes:

```bash
./scripts/uninstall-gitops-operator.sh --dry-run
```

The uninstall script:

1. Validates prerequisites (oc CLI, login, cluster-admin role)
2. Scans all namespaces for ArgoCD instances
3. Deletes all ArgoCD instances
4. Removes the Operator Subscription and waits for CSV removal
5. Waits for all operator pods to terminate
6. Deletes the OperatorGroup
7. Removes both `openshift-gitops-operator` and `openshift-gitops` namespaces
8. Verifies that all resources were cleaned up

> **WARNING:** Uninstallation is irreversible. All ArgoCD instances and operator resources will be permanently deleted.
