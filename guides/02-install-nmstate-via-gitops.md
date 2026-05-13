# Installing the nmstate Operator via Argo CD (GitOps)

This guide walks through deploying and managing the Kubernetes nmstate operator using Argo CD, leveraging the GitOps workflow already in place on your OpenShift cluster.

## Prerequisites

- **GitOps operator installed** – The OpenShift GitOps operator must already be installed and Argo CD running. Follow [Guide 01](01-install-gitops-operator.md) if you haven't installed it yet.
- **Git repository** – You need a Git repository to store the nmstate manifests (this repository can serve as one).
- **`argocd` CLI** (optional) – Useful for verifying from the command line.

## Step 1: Prepare the nmstate Manifests

The manifests needed to install the nmstate operator are located in `operators/nmstate/`:

- `namespace.yaml` – Creates the `openshift-nmstate` namespace
- `operator-group.yaml` – Configures the operator group for the nmstate namespace
- `subscription.yaml` – Subscribes to the `kubernetes-nmstate-operator` from Red Hat operators
- `nmstate-instance.yaml` – Creates the NMState custom resource instance

These files are already included in this repository under `operators/nmstate/`.

## Step 2: Commit and Push to Git

Push these manifests to your Git repository:

```bash
git add operators/nmstate/
git commit -m "Add nmstate operator manifests"
git push origin main
```

## Step 3: Create an ArgoCD Application

An ArgoCD Application resource tells Argo CD which Git repository and path to reconcile. The application manifest is located at `operators/argocd-applications/nmstate-operator-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nmstate-operator
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: 'https://github.com/YOUR_USERNAME/openshift_gitops.git'
    targetRevision: main
    path: operators/nmstate
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: openshift-nmstate
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

**Important**: Replace `YOUR_USERNAME` with your actual GitHub (or Git server) username before applying.

## Step 4: Apply the ArgoCD Application

```bash
oc apply -f operators/argocd-applications/nmstate-operator-app.yaml
```

Argo CD will automatically begin reconciling the manifests from your Git repository and deploy the nmstate operator.

## Step 5: Verify the Deployment

### Check via ArgoCD CLI

```bash
# Get application status
argocd app get nmstate-operator

# Check for diffs between Git and live state
argocd app diff nmstate-operator
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
   oc get secret openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin.password}' | base64 -d
   ```
3. Navigate to the **Applications** section and find `nmstate-operator`.
4. Verify that both **Health** and **Sync Status** show `Healthy` and `Synced`.

## Step 6: Check ArgoCD Health and Sync Status

### Automated reconciliation

The `syncPolicy` in the Application manifest enables `automated` sync with:
- **`prune: true`** – Resources deleted from Git are removed from the cluster
- **`selfHeal: true`** – Drifted resources are automatically corrected

### Common verification commands

```bash
# Application details
argocd app get nmstate-operator

# Diff between desired (Git) and actual state
argocd app diff nmstate-operator

# Watch sync progress
argocd app watch nmstate-operator

# Trigger manual sync if needed
argocd app sync nmstate-operator
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Application shows `Missing` | Verify the Git repo URL in the Application manifest is correct and accessible |
| Pods not starting | Check `oc describe pod -n openshift-nmstate` for events and errors |
| Sync fails | Run `argocd app diff nmstate-operator` to identify configuration differences |
| Operator not installing | Verify the `Subscription` CSV phase: `oc get csv -n openshift-nmstate` |
