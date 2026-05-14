# Installing the OpenShift Virtualization Operator via Argo CD (GitOps)

This guide walks through deploying the OpenShift Virtualization (KubeVirt Hypershift) operator using Argo CD, leveraging the GitOps workflow already in place on your OpenShift cluster.

Reference: [Installing a virtualization cluster](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/virtualization/index)

## Prerequisites

- **GitOps operator installed** – The OpenShift GitOps operator must already be installed and Argo CD running. Follow [Guide 01](01-install-gitops-operator.md) if you haven't installed it yet.
- **`argocd` CLI** (optional) – Useful for verifying from the command line.
- **Shell alias** – To avoid typing `--grpc-web --grpc-web-root-path /` on every command, set:

  ```bash
  alias argocd='argocd --grpc-web --grpc-web-root-path /'
  ```

## Step 1: Review the Manifests

The operator manifests are in `operators/virt/`:

- `namespace.yaml` – Creates the `openshift-virtualization-operator` namespace
- `operator-group.yaml` – Configures the operator group
- `subscription.yaml` – Subscribes to `kubevirt-hypershift` from Red Hat operators

## Step 2: Deploy the Virtualization Operator

Apply the operator app:

```bash
oc apply -f operators/argocd-applications/virt-operator-app.yaml
```

Argo CD will automatically reconcile the manifests and deploy the operator.

## Step 3: Wait for the Operator to Be Ready

```bash
# Watch the application status
argocd app get virt-operator

# Check operator pods
oc get pods -n openshift-virtualization-operator -w

# Verify the CSV phase
oc get csv -n openshift-virtualization-operator -o jsonpath='{.items[0].status.phase}'
```

The operator is ready when all pods are `Running` and the CSV phase is `Succeeded`.

## Step 4: Verify the Deployment

### Check via ArgoCD CLI

```bash
argocd app get virt-operator
argocd app diff virt-operator
```

### Check via `oc` CLI

```bash
# Verify pods in the virtualization namespace
oc get pods -n openshift-virtualization-operator

# Check the operator pods are running
oc get pods -n openshift-virtualization-operator -l name=kubevirt-hypershift-operator

# Verify the CSV
oc get csv -n openshift-virtualization-operator
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

3. Navigate to the **Applications** section and find `virt-operator`.
4. Verify that both **Health** and **Sync Status** show `Healthy` and `Synced`.

## Step 5: Check ArgoCD Health and Sync Status

### Automated reconciliation

The `syncPolicy` in the Application manifest enables `automated` sync:

- **`prune: true`** – Resources deleted from Git are removed from the cluster
- **`selfHeal: true`** – Drifted resources are automatically corrected

### Common verification commands

```bash
# Application details
argocd app get virt-operator

# Diff between desired (Git) and actual state
argocd app diff virt-operator

# Watch sync progress (all apps)
argocd app watch

# Trigger manual sync if needed
argocd app sync virt-operator
```

> **Note:** All `argocd` CLI commands use `--grpc-web --grpc-web-root-path /` because OpenShift reencrypt routes don't negotiate HTTP/2 ALPN for native gRPC. Use a shell alias to avoid typing these flags every time.

## Next Steps

After the virtualization operator is installed, you can:

1. Create `VirtualMachine` resources using the `VirtualMachine` CRD
2. Set up storage classes and data volumes for VM disk images
3. Configure network interfaces for VMs
4. Deploy the Virtualization UI plugin for the OpenShift console

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Application shows `OutOfSync / Missing` | The app hasn't been synced yet — apply the app manifest with `oc apply` |
| Application shows `Missing` | Verify the Git repo URL in the Application manifest is correct and accessible |
| Pods not starting | Check `oc describe pod -n openshift-virtualization-operator` for events and errors |
| Sync fails | Run `argocd app diff virt-operator` to identify configuration differences |
| Operator not installing | Verify the `Subscription` CSV phase: `oc get csv -n openshift-virtualization-operator` |
| `argocd` CLI hangs | Use `--grpc-web --grpc-web-root-path /` flags, or create a shell alias |

## Deleting the Application

```bash
argocd app delete virt-operator
```

Deleting this app removes the OLM `Subscription`, which triggers OLM's finalizers — the operator, all its pods, and the CRDs are automatically cleaned up.

> **Note:** Deleting an ArgoCD Application without `--cascade` removes only the Application resource, not the managed resources. For OLM-managed operators, OLM finalizers handle cleanup automatically.
