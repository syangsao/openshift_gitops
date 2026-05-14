# Installing the OpenShift GitOps Operator via CLI

This guide walks through installing the OpenShift GitOps operator using the `oc` CLI, following Red Hat documentation.

Reference: [Installing GitOps Operator using CLI](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.16/html-single/installing_gitops/index#installing-gitops-operator-using-cli_installing-openshift-gitops)

## Prerequisites

- **Cluster-admin access** – You must have cluster-admin privileges on your OpenShift cluster.
- **`oc` CLI** – The OpenShift CLI must be installed and configured to communicate with your cluster.
- **Marketplace capability** – The cluster must have the OpenShift Container Platform Marketplace capability enabled (default on most installations). Verify with:

  ```bash
  oc get clusterversion version -o jsonpath='{.status.capabilities.status}'
  ```

## Step 1: Create the GitOps Operator Namespace

Create the namespace where the GitOps operator will be installed:

```bash
oc create namespace openshift-gitops-operator
```

## Step 2: Create the OperatorGroup

Apply the OperatorGroup manifest to allow operators to install in this namespace:

```yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  upgradeStrategy: Default
```

Apply with:

```bash
oc apply -f operators/gitops/operator-group.yaml
```

## Step 3: Create the Subscription

Apply the Subscription to trigger the operator installation:

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

Apply with:

```bash
oc apply -f operators/gitops/subscription.yaml
```

## Step 4: Wait for Installation

The operator installation takes a few minutes. Monitor progress:

```bash
# Watch the subscription status
oc get subscription -n openshift-gitops-operator -w

# Check the CSV installation state
oc get csv -n openshift-gitops-operator -o jsonpath='{.items[0].status.phase}'
```

The installation is complete when the CSV phase shows `Succeeded`.

## Step 5: Verify Installation

### Check pods in `openshift-gitops` namespace

```bash
oc get pods -n openshift-gitops
```

You should see Argo CD pods running (server, repo, application-controller, etc.).

### Check pods in `openshift-gitops-operator` namespace

```bash
oc get pods -n openshift-gitops-operator
```

You should see the `openshift-gitops-operator` pod running.

### Verify the ArgoCD resource

```bash
oc get argocd -n openshift-gitops
```

This should show the default ArgoCD instance (typically named `openshift-gitops`).

### Retrieve the Argo CD admin password

```bash
oc get secret openshift-gitops-cluster -n openshift-gitops -o json | jq -r '.data["admin.password"]' | base64 -d
```

> **Note:** Use `jq` to extract the password — `jsonpath` bracket notation is unreliable for keys containing dots like `admin.password`.

### Log in to Argo CD

```bash
argocd login openshift-gitops-server-openshift-gitops.apps.YOUR_DOMAIN \
  --username admin \
  --password '<PASSWORD>' \
  --grpc-web \
  --grpc-web-root-path / \
  --skip-test-tls
```

> **Note:** Use `--grpc-web` because OpenShift reencrypt routes don't negotiate HTTP/2 ALPN for native gRPC — without it the CLI will hang.
>
> Replace the hostname with your actual Argo CD route:
>
> ```bash
> oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}'
> ```
>
> You can also fetch it inline:
>
> ```bash
> argocd login $(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}') \
>   --username admin \
>   --password '<PASSWORD>' \
>   --grpc-web \
>   --grpc-web-root-path / \
>   --skip-test-tls
> ```
>
> **Tip:** To avoid typing `--grpc-web --grpc-web-root-path /` on every command, create a shell alias:
>
> ```bash
> alias argocd='argocd --grpc-web --grpc-web-root-path /'
> ```
>
> Add this to your `~/.bashrc` or `~/.zshrc` to make it permanent. This applies to all `argocd` commands except `argocd login`, which also needs `--skip-test-tls`.

Or access the Argo CD UI via the route:

```bash
oc get route openshift-gitops-server -n openshift-gitops
```

## Verification Summary

| Check | Command |
|-------|---------|
| CSV phase | `oc get csv -n openshift-gitops-operator -o jsonpath='{.items[0].status.phase}'` |
| GitOps pods | `oc get pods -n openshift-gitops` |
| Operator pods | `oc get pods -n openshift-gitops-operator` |
|| ArgoCD instance | `oc get argocd -n openshift-gitops` |
|| Admin password | `oc get secret openshift-gitops-cluster -n openshift-gitops -o json \| jq -r '.data["admin.password"]' \| base64 -d` |
|| ArgoCD route | `oc get route openshift-gitops-server -n openshift-gitops` |

## Sizing Requirements

The Argo CD instance has sizing requirements for each workload component:

- **Application Controller**: Requires significant CPU and memory (default: 4 CPU cores, 8 Gi memory)
- **Argo CD Server**: Moderate resources (default: 2 CPU cores, 4 Gi memory)
- **Repo Server**: Moderate resources (default: 2 CPU cores, 2 Gi memory)
- **Redis**: Lightweight (default: 1 CPU core, 1 Gi memory)

You can customize these in the ArgoCD custom resource. Ensure your cluster has sufficient resources available before installation. See the [Argo CD sizing documentation](https://argo-cd.readthedocs.io/en/stable/operator-manual/resource_requests_limits/) for details.
