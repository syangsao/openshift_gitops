# OpenShift GitOps Operator Management

This repository contains manifests, guides, and automation scripts for managing OpenShift GitOps (Argo CD) operators on Red Hat OpenShift clusters.

## Directory Structure

- **`guides/`** - Step-by-step installation and configuration guides
  - `01-install-gitops-operator.md` - Installing the GitOps operator via CLI
  - `02-install-nmstate-via-gitops.md` - Managing nmstate operator through Argo CD
- **`scripts/`** - Automation scripts
  - `install-gitops-operator.sh` - Automated GitOps operator installation with verification
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
