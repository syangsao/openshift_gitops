# Installing the nmstate Operator via Argo CD (GitOps)

This guide walks through deploying and managing the Kubernetes nmstate operator using Argo CD, leveraging the GitOps workflow already in place on your OpenShift cluster.

## Prerequisites

- **GitOps operator installed** – The OpenShift GitOps operator must already be installed and Argo CD running. Follow [Guide 01](01-install-gitops-operator.md) if you haven't installed it yet.
- **Git repository** – You need a Git repository to store the nmstate manifests (this repository can serve as one).
- **`argocd` CLI** (optional) – Useful for verifying from the command line.

## Overview

The nmstate operator deployment uses **two separate ArgoCD applications**:

1. **`nmstate-operator`** — Deploys the namespace, OperatorGroup, and Subscription (installs the operator)
2. **`nmstate-instance`** — Creates the NMState custom resource (applied *after* the operator is installed)

This two-app approach avoids a sync hang: the NMState CRD is created by the operator itself, so the CR cannot be applied before the operator is running.

## Step 1: Review the Manifests

The operator manifests are in `operators/nmstate/`:

- `namespace.yaml` – Creates the `openshift-nmstate` namespace
- `operator-group.yaml` – Configures the operator group
- `subscription.yaml` – Subscribes to `kubernetes-nmstate-operator` from Red Hat operators

The NMState instance is in `operators/nmstate-instance/`:

- `nmstate-instance.yaml` – Creates the NMState custom resource

## Step 2: Deploy the nmstate Operator

Apply the operator app:

```bash
oc apply -f operators/argocd-applications/nmstate-operator-app.yaml
```

Argo CD will automatically reconcile the manifests and deploy the operator.

## Step 3: Wait for the Operator to Be Ready

```bash
# Watch the application status
argocd app get nmstate-operator

# Check operator pods
oc get pods -n openshift-nmstate -w

# Verify the CSV phase
oc get csv -n openshift-nmstate -o jsonpath='{.items[0].status.phase}'
```

The operator is ready when all pods are `Running` and the CSV phase is `Succeeded`.

## Step 4: Deploy the NMState Instance

Once the operator is running, apply the instance app:

```bash
oc apply -f operators/argocd-applications/nmstate-instance-app.yaml
```

This creates the `NMState` custom resource, which tells the operator to configure networking.

## Step 5: Verify the Deployment

### Check via ArgoCD CLI

```bash
# Operator app status
argocd app get nmstate-operator

# Instance app status
argocd app get nmstate-instance
```

### Check via `oc` CLI

```bash
# Verify pods in the nmstate namespace
oc get pods -n openshift-nmstate

# Check the operator pod is running
oc get pod -n openshift-nmstate -l name=kubernetes-nmstate-operator

# Verify the NMState CR exists
oc get nmstate -n openshift-nmstate
```

### Check via ArgoCD UI

1. Get the ArgoCD route:

   ```bash
   oc get route openshift-gitops-server -n openshift-gitops
   ```

2. Log in with the admin password:

   ```bash
   oc get secret openshift-gitops-cluster -n openshift-gitops -o json | jq -r '.data["admin.password"]' | base64 -d
   ```

3. Navigate to the **Applications** section and find `nmstate-operator` and `nmstate-instance`.
4. Verify that both **Health** and **Sync Status** show `Healthy` and `Synced`.

## Step 6: Check ArgoCD Health and Sync Status

### Automated reconciliation

Both applications use `syncPolicy` with `automated` sync:

- **`prune: true`** – Resources deleted from Git are removed from the cluster
- **`selfHeal: true`** – Drifted resources are automatically corrected

### Common verification commands

```bash
# Application details
argocd app get nmstate-operator
argocd app get nmstate-instance

# Diff between desired (Git) and actual state
argocd app diff nmstate-operator
argocd app diff nmstate-instance

# Watch sync progress
argocd app watch nmstate-operator

# Trigger manual sync if needed
argocd app sync nmstate-operator
```

> **Note:** These commands assume you've set grpc-web globally (`argocd config set grpc-web true`). If you haven't, append `--grpc-web --grpc-web-root-path /` to each command.

## Deleting Applications

When deleting ArgoCD applications, the behavior differs between the operator and instance apps:

### Operator app (`nmstate-operator`)

```bash
argocd app delete nmstate-operator
```

Deleting this app removes the OLM `Subscription`, which triggers OLM's finalizers — the operator, all its pods, and the CRD are automatically cleaned up. No `--cascade` flag is needed.

### Instance app (`nmstate-instance`)

```bash
argocd app delete nmstate-instance --cascade
```

This app manages a plain CR, not an OLM Subscription. Deleting the app **without `--cascade`** removes only the ArgoCD Application resource — the `NMState` CR stays on the cluster. Use `--cascade` to also delete the CR.

> **Note:** This applies to all non-OLM ArgoCD apps — deleting an Application doesn't remove the resources it created unless you use `--cascade`.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Application shows `OutOfSync / Missing` | The app hasn't been synced yet — apply the app manifest with `oc apply` |
| Sync hangs indefinitely | The NMState CR was included with the operator manifests — use the two-app approach instead |
| Application shows `Missing` | Verify the Git repo URL in the Application manifest is correct and accessible |
| Pods not starting | Check `oc describe pod -n openshift-nmstate` for events and errors |
|| Sync fails | Run `argocd app diff nmstate-operator` to identify differences |
|| Operator not installing | Verify the `Subscription` CSV phase: `oc get csv -n openshift-nmstate` |
|| `argocd` CLI hangs | Set grpc-web globally: `argocd config set grpc-web true` |
