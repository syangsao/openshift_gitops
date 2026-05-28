# Installing OpenShift Data Foundation (ODF) via Argo CD (GitOps) — Standalone MCG Mode

This guide walks through deploying [Red Hat OpenShift Data Foundation](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.21/) on your OpenShift cluster using Argo CD in **standalone Multicloud Object Gateway (MCG)** mode, leveraging the GitOps workflow already in place.

## Prerequisites

- **GitOps operator installed** – The OpenShift GitOps operator must already be installed and Argo CD running. Follow [Guide 01](01-install-gitops-operator.md) if you haven't installed it yet.
- **NFS CSI driver** – An NFS CSI driver with a working StorageClass (e.g., `nfs-csidriver3`) must be available. ODF in standalone mode uses NFS for NooBaa database and backing store volumes. See [Guide 05](05-install-nfs-csi-via-gitops.md).
- **OpenShift cluster** – Version 4.21+ with cluster-admin privileges.
- **`oc` CLI** – Installed and authenticated to your cluster.
- **OpenShift Marketplace** – Must be enabled and accessible (for `redhat-operators` catalog source).

## Overview

OpenShift Data Foundation (ODF) in **standalone MCG mode** deploys NooBaa as a S3-compatible object storage service without requiring local Ceph OSDs. This is ideal for clusters where:

- You don't have dedicated storage nodes with raw disks
- You want S3-compatible object storage for applications (Quay, registry, CI/CD artifacts, etc.)
- You have NFS or other external storage available as a backing store

The deployment includes three Argo CD Applications:
1. **ODF Operator** (`odf-operator`) – Subscribes to `odf-operator` from `redhat-operators` catalog
2. **ODF Instance** (`odf-instance`) – OCSInitialization + StorageCluster (external mode, standalone MCG)
3. **NooBaa MCG** (`odf-noobaa`) – NooBaa instance, BackingStores, BucketClasses, and ObjectBucketClaims

> **Note:** This guide follows the [Red Hat standalone MCG deployment documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.19/html-single/deploying_openshift_data_foundation_using_bare_metal_infrastructure/index#deploy-standalone-multicloud-object-gateway).

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  OpenShift Cluster                   │
│                                                      │
│  ┌──────────────────────────────────────────────┐   │
│  │           openshift-storage NS               │   │
│  │                                              │   │
│  │  odf-operator ──► ocs-operator ──► rook      │   │
│  │              ──► mcg-operator ──► NooBaa     │   │
│  │                                              │   │
│  │  StorageCluster (external mode)              │   │
│  │  ┌──────────────────────────────────────┐   │   │
│  │  │  NooBaa MCG                           │   │   │
│  │  │  ├─ noobaa-core (control plane)      │   │   │
│  │  │  ├─ noobaa-db (PostgreSQL 16 on NFS) │   │   │
│  │  │  ├─ noobaa-endpoint ×3 (S3 API)      │   │   │
│  │  │  ├─ BackingStore: default (50Gi NFS) │   │   │
│  │  │  └─ BackingStore: quay (50Gi NFS)    │   │   │
│  │  └──────────────────────────────────────┘   │   │
│  └──────────────────────────────────────────────┘   │
│                                                      │
│  ┌──────────────┐    ┌──────────────────────┐       │
│  │  NFS Server   │◄──│  nfs-csidriver3      │       │
│  │  (mirror)     │    │  StorageClass        │       │
│  └──────────────┘    └──────────────────────┘       │
└─────────────────────────────────────────────────────┘
```

> **⚠️ Important for existing installations:** If ODF is already installed manually on your cluster (like the luke cluster), these Argo CD Applications will adopt the existing resources — they won't recreate them. Apply them in order: RBAC first, then the operator app, then the instance app, then the noobaa app. Argo CD will detect the existing resources and reconcile them to match the Git-defined state. This is a safe adoption process that doesn't disrupt running workloads.

## Step 1: Deploy the RBAC for Argo CD

ODF manages many cluster-scoped and namespace-scoped resources. Argo CD needs elevated permissions:

```bash
oc apply -f operators/argocd-applications/odf-rbac.yaml
```

This grants the Argo CD application controller access to:
- OCSInitialization, StorageCluster (ocs.openshift.io)
- NooBaa, BackingStore, BucketClass (noobaa.io)
- ObjectBucketClaim (objectbucket.io)
- Ceph resources (ceph.rook.io) — for external mode reconciliation
- CSI Addons, Volume Replication, Volume Snapshots
- StorageClasses, PVs, PVCs, Routes, Monitoring resources
- SCC read access

## Step 2: Review the Manifests

### Operator Bootstrap (`operators/odf/`)

| File | Description |
|------|-------------|
| `namespace.yaml` | Creates the `openshift-storage` namespace |
| `operator-group.yaml` | OperatorGroup targeting `openshift-storage` |
| `subscription.yaml` | Subscribes to `odf-operator` on `stable-4.21` channel |

### ODF Instance (`operators/odf-instance/`)

| File | Description |
|------|-------------|
| `ocs-initialization.yaml` | OCSInitialization CR (empty spec — operator manages defaults) |
| `storage-cluster.yaml` | StorageCluster in external mode with standalone MCG |

### NooBaa MCG (`operators/odf-noobaa/`)

| File | Description |
|------|-------------|
| `noobaa.yaml` | NooBaa CR with PostgreSQL 16 on NFS, 3-10 endpoints |
| `backing-store-default.yaml` | Default PV pool backing store (50Gi on NFS) |
| `backing-store-quay.yaml` | Dedicated backing store for Quay Enterprise |
| `bucket-class-default.yaml` | Default bucket class → default backing store |
| `bucket-class-quay.yaml` | Quay bucket class → quay backing store (Spread) |
| `object-bucket-claim.yaml` | Pre-provisioned OBC for Quay (`quay-obc`) |

### Key Configuration Details

**StorageCluster:**
- `externalStorage: {}` — No local Ceph OSDs
- `arbiter: {}` — Arbiter node support (for 2-site quorum)
- `multiCloudGateway.reconcileStrategy: standalone` — MCG without Ceph dependency
- `multiCloudGateway.dbStorageClassName: nfs-csidriver3` — PostgreSQL DB on NFS
- `resourceProfile: balanced` — Balanced CPU/memory allocation
- Resource limits: 3 CPU / 4Gi memory for core, db, and endpoints

**NooBaa:**
- `dbSpec.dbStorageClass: nfs-csidriver3` — Database on NFS
- `dbSpec.image: registry.redhat.io/rhel9/postgresql-16` — PostgreSQL 16
- Endpoints: min 3, max 10 (auto-scaled via HPAv2)
- `MulticloudObjectGatewayProviderMode: "true"` annotation

**BackingStores:**
- Both use `pv-pool` type with 1 volume each on `nfs-csidriver3`
- 50Gi per volume, 1 CPU / 4Gi memory limits

> **Important:** Adjust the `dbStorageClassName`, `pvPoolDefaultStorageClass`, and backing store `storageClass` values to match your NFS CSI StorageClass name if it differs from `nfs-csidriver3`.

## Step 3: Deploy the ODF Operator

Apply the Argo CD Application for the operator:

```bash
oc apply -f operators/argocd-applications/odf-operator-app.yaml
```

Argo CD will create the namespace, OperatorGroup, and Subscription. Wait for the operator to be ready:

```bash
# Watch the application status
argocd app get odf-operator --grpc-web --grpc-web-root-path /

# Check operator pods
oc get pods -n openshift-storage -l control-only=true -w
```

The operator is ready when you see these pods running:
- `odf-operator-*`
- `ocs-operator-*`
- `rook-ceph-operator-*`
- `mcg-operator-*`
- `cephcsi-operator-*`
- `odf-csi-addons-operator-*`
- `odf-dependencies-*`
- `odf-external-snapshotter-operator-*`
- `odf-prometheus-operator-*`
- `recipe-*`

This typically takes **5-10 minutes**.

## Step 4: Deploy the ODF Instance

Once the operator is ready, apply the instance Application (OCSInitialization + StorageCluster):

```bash
oc apply -f operators/argocd-applications/odf-instance-app.yaml
```

Argo CD will create the OCSInitialization and StorageCluster. Wait for the StorageCluster to reach `Ready` phase:

```bash
oc get storagecluster ocs-storagecluster -n openshift-storage -w
```

## Step 5: Deploy NooBaa MCG

Once the StorageCluster is ready, apply the NooBaa Application:

```bash
oc apply -f operators/argocd-applications/odf-noobaa-app.yaml
```

Argo CD will create the NooBaa instance, BackingStores, BucketClasses, and ObjectBucketClaim.

### Expected Deployment Sequence

1. **OCSInitialization** → Creates common CRDs, SCCs, and webhook configurations
2. **StorageCluster** → Triggers operator reconciliation, creates NooBaa if not present
3. **NooBaa** → Deploys noobaa-core, noobaa-db (PostgreSQL), and endpoint pods
4. **BackingStores** → Provisions PVCs on NFS and creates data pools
5. **BucketClasses** → Registers placement policies
6. **ObjectBucketClaim** → Creates S3 bucket and provisioner secret

### Monitoring Progress

```bash
# Watch StorageCluster phase
oc get storagecluster ocs-storagecluster -n openshift-storage -w

# Watch NooBaa phase
oc get noobaa noobaa -n openshift-storage -w

# Watch all ODF pods
oc get pods -n openshift-storage -w
```

### Expected Pods When Ready (~22 pods)

| Pod | Role |
|-----|------|
| `odf-operator-*` | ODF operator controller |
| `ocs-operator-*` | OCS operator controller |
| `rook-ceph-operator-*` | Rook-Ceph operator (external mode) |
| `mcg-operator-*` | MCG operator controller |
| `cephcsi-operator-*` | Ceph CSI operator |
| `odf-csi-addons-operator-*` | CSI addons operator |
| `odf-dependencies-*` | Dependencies operator |
| `odf-external-snapshotter-operator-*` | Snapshot operator |
| `odf-prometheus-operator-*` | Prometheus operator |
| `recipe-*` | Recipe operator |
| `noobaa-core-*` | NooBaa control plane |
| `noobaa-db-pg-*` | PostgreSQL database (standalone) |
| `noobaa-endpoint-*` ×3 | S3 API endpoints (min 3, auto-scaled to 10) |
| `noobaa-default-backing-store-*` | Default backing store pod |
| `quay-backingstore-*` | Quay backing store pod |
| `ocs-metrics-exporter-*` | Metrics exporter |
| `ocs-client-operator-*` | Client operator |
| `ocs-client-operator-console-*` | Console plugin |

This typically takes **10-15 minutes** after the operator is ready.

## Step 5: Verify the Deployment

### Via Argo CD CLI

```bash
# Operator application
argocd app get odf-operator --grpc-web --grpc-web-root-path /
argocd app get odf-instance --grpc-web --grpc-web-root-path /
argocd app get odf-noobaa --grpc-web --grpc-web-root-path /

# Check sync status
argocd app sync-status odf-operator --grpc-web --grpc-web-root-path /
argocd app sync-status odf-instance --grpc-web --grpc-web-root-path /
argocd app sync-status odf-noobaa --grpc-web --grpc-web-root-path /
```

### Via `oc` CLI

```bash
# StorageCluster should be Ready
oc get storagecluster ocs-storagecluster -n openshift-storage
# Expected:   NAME                   AGE   PHASE     VERSION
#             ocs-storagecluster   15m   Ready     4.21.x

# NooBaa should be Ready
oc get noobaa noobaa -n openshift-storage
# Expected:   NAME     AGE   PHASE
#             noobaa   15m   Ready

# BackingStores should be OPTIMAL
oc get backingstore -n openshift-storage
# Expected:   NAME                             AGE   PHASE
#             noobaa-default-backing-store    15m   OPTIMAL
#             quay-backingstore               15m   OPTIMAL

# BucketClasses should be Ready
oc get bucketclass -n openshift-storage
# Expected:   NAME                         AGE   PHASE
#             noobaa-default-bucket-class  15m   Ready
#             quay-bucketclass             15m   Ready

# ObjectBucketClaim should be Bound
oc get obc -n openshift-storage
# Expected:   NAME      AGE   PHASE
#             quay-obc  15m   Bound

# S3 endpoint routes
oc get routes -n openshift-storage | grep -E 's3|iam|noobaa-mgmt|sts'
# Expected routes:
#   s3-openshift-storage        → S3 API
#   iam-openshift-storage       → IAM API
#   noobaa-mgmt-openshift-storage → Management UI
#   sts-openshift-storage       → STS API
```

### Test S3 Access

```bash
# Get the S3 credentials from the OBC secret
oc get secret quay-obc-s3-secret -n openshift-storage -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d
oc get secret quay-obc-s3-secret -n openshift-storage -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d
oc get secret quay-obc-s3-secret -n openshift-storage -o jsonpath='{.data.S3_URL}' | base64 -d

# Test with s3cmd or aws cli
# Install s3cmd: pip install s3cmd
s3cmd --access-key=<KEY> --secret-key=<SECRET> \
  --host=s3-openshift-storage.apps.<your-cluster>.net \
  --host-bucket=s3-openshift-storage.apps.<your-cluster>.net \
  --no-cert-check ls s3://
```

### Via Argo CD UI

1. Get the Argo CD route:
   ```bash
   oc get route openshift-gitops-server -n openshift-gitops
   ```
2. Log in and navigate to **Applications**.
3. Find `odf-operator`, `odf-instance`, and `odf-noobaa` — all three should show **Health** = `Healthy` and **Sync Status** = `Synced`.

## Configuring Additional Backing Stores

### Adding a New Backing Store

Create a new backing store manifest in `operators/odf-noobaa/`:

```yaml
apiVersion: noobaa.io/v1alpha1
kind: BackingStore
metadata:
  labels:
    app: noobaa
  name: my-app-backingstore
  namespace: openshift-storage
spec:
  pvPool:
    numVolumes: 1
    resources:
      limits:
        cpu: 1000m
        memory: 4000Mi
      requests:
        storage: 100Gi    # Adjust size as needed
    secret: {}
    storageClass: nfs-csidriver3
  type: pv-pool
```

Then create a corresponding BucketClass:

```yaml
apiVersion: noobaa.io/v1alpha1
kind: BucketClass
metadata:
  labels:
    app: noobaa
  name: my-app-bucketclass
  namespace: openshift-storage
spec:
  placementPolicy:
    tiers:
    - backingStores:
      - my-app-backingstore
```

Commit and push — Argo CD will sync automatically.

### Creating Application OBCs

For each application that needs S3 storage:

```yaml
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: my-app-obc
  namespace: my-app-namespace    # Can be any namespace
spec:
  additionalConfig:
    bucketclass: my-app-bucketclass
  generateBucketName: my-app
  storageClassName: openshift-storage.noobaa.io
```

The OBC creates a secret with S3 credentials in the same namespace.

## Upgrading ODF

1. Update the `channel` in `operators/odf/subscription.yaml` if needed.
2. Update resource limits in `operators/odf-instance/storage-cluster.yaml` if scaling the core services.
3. Update NooBaa-specific configs in `operators/odf-noobaa/noobaa.yaml` and backing stores in `operators/odf-noobaa/`.
4. Commit and push to Git.
5. Argo CD will sync the changes.

To find the latest ODF version:
```bash
oc packagemanifests odf-operator -n openshift-marketplace
```

## Deleting ODF

### Phase 1: Remove NooBaa MCG Resources

```bash
# Delete the noobaa application first (cascades to CRs)
argocd app delete odf-noobaa --cascade --grpc-web --grpc-web-root-path /
```

Wait for NooBaa pods and PVCs to be cleaned up:
```bash
oc get pods -n openshift-storage -w
oc get pvc -n openshift-storage
```

### Phase 2: Remove ODF Instance

```bash
# Delete the instance application
argocd app delete odf-instance --cascade --grpc-web --grpc-web-root-path /
```

Wait for StorageCluster and OCSInitialization to be cleaned up:
```bash
oc get storagecluster -n openshift-storage -w
```

### Phase 3: Remove Operator

```bash
# Delete the operator application
argocd app delete odf-operator --cascade --grpc-web --grpc-web-root-path /
```

### Phase 3: Clean Up

```bash
# Remove RBAC
oc delete -f operators/argocd-applications/odf-rbac.yaml

# Verify cleanup
oc get namespace openshift-storage
oc get sc | grep ocs
oc get sc | grep noobaa

# Remove lingering StorageClasses
oc delete sc openshift-storage.noobaa.io 2>/dev/null

# Remove namespace if it persists
oc delete namespace openshift-storage --wait=false
```

> **WARNING:** Deletion is irreversible. All S3 buckets, objects, and NooBaa data will be permanently deleted. Back up any important data before proceeding.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Operator pods stuck in `Pending` | Check node capacity: `oc describe pod -n openshift-storage` |
| StorageCluster phase stuck at `Expanding` | Check NooBaa status: `oc describe noobaa noobaa -n openshift-storage` |
| NooBaa endpoints crashing | Verify NFS CSI is working: `oc get pods -n csi-driver-nfs` |
| PVCs not binding | Verify NFS CSI StorageClass: `oc get sc nfs-csidriver3` and test a PVC manually |
| BackingStore not reaching `OPTIMAL` | Check PVC status: `oc get pvc -n openshift-storage` |
| S3 endpoint not accessible | Check routes: `oc get routes -n openshift-storage` and DNS resolution |
| `OutOfSync` in Argo CD | Run `argocd app diff odf-noobaa --grpc-web --grpc-web-root-path /` to identify differences |
| Sync fails with `Forbidden` | Ensure RBAC is applied: `oc apply -f operators/argocd-applications/odf-rbac.yaml` |
| PostgreSQL connection errors | Check noobaa-db pod logs: `oc logs -n openshift-storage -l noobaa-core=true -c db` |
| OBC not binding | Verify BucketClass exists and BackingStore is `OPTIMAL` |

### Checking Logs

```bash
# ODF operator logs
oc logs -n openshift-storage -l app=odf-operator -c odf-operator

# NooBaa core logs
oc logs -n openshift-storage -l noobaa-core=true -c core

# NooBaa endpoint logs
oc logs -n openshift-storage -l noobaa-core=true -c endpoint

# NooBaa database logs
oc logs -n openshift-storage -l noobaa-core=true -c db

# MCG operator logs
oc logs -n openshift-storage -l app=mcg-operator
```

## Appendix: Arbiter Node Configuration

This deployment includes `arbiter: {}` in the StorageCluster spec. The arbiter node provides quorum for a 2-site active-active setup. On the luke cluster, the arbiter node (`arbiter.syangsao.net`) exists but is not used for storage — it only participates in quorum decisions.

For single-site deployments without an arbiter node, remove `arbiter: {}` from `storage-cluster.yaml`.

## Appendix: Resource Sizing Guide

| Component | Current | Minimum | Recommended |
|-----------|---------|---------|-------------|
| noobaa-core | 3 CPU / 4Gi | 1 CPU / 2Gi | 3 CPU / 4Gi |
| noobaa-db | 3 CPU / 4Gi | 1 CPU / 2Gi | 2 CPU / 4Gi |
| noobaa-endpoint | 3 CPU / 4Gi × 3 | 1 CPU / 2Gi × 1 | 2 CPU / 4Gi × 3 |
| BackingStore | 1 CPU / 4Gi / 50Gi | 500m / 2Gi / 10Gi | 1 CPU / 4Gi / 50Gi |
| Endpoints | min 3, max 10 | min 1, max 5 | min 3, max 10 |

Adjust in `storage-cluster.yaml` (for core/db/endpoint defaults) and `noobaa.yaml` (for specific overrides).

## Appendix: Integration with Quay Enterprise

This ODF deployment includes a dedicated backing store (`quay-backingstore`) and bucket class (`quay-bucketclass`) for Quay Enterprise container registry. The `quay-obc` ObjectBucketClaim is pre-provisioned.

To use it in Quay:
1. Get the S3 credentials:
   ```bash
   oc get secret quay-obc-s3-secret -n openshift-storage -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d
   oc get secret quay-obc-s3-secret -n openshift-storage -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d
   ```
2. Get the S3 endpoint URL:
   ```bash
   oc get secret quay-obc-s3-secret -n openshift-storage -o jsonpath='{.data.S3_URL}' | base64 -d
   ```
3. Configure Quay storage to use S3 with these credentials and endpoint.
4. Set `Region` to `us-east-1` (NooBaa accepts any region).
5. Enable `Use SSL` and set `Verify SSL` to `false` (or configure proper certificates).
