# Installing the QNAP CSI Driver via Argo CD (GitOps)

This guide walks through deploying the [QNAP CSI Driver](https://github.com/qnap-dev/QNAP-CSI-PlugIn) on your OpenShift cluster using Argo CD, leveraging the GitOps workflow already in place.

## Prerequisites

- **GitOps operator installed** – The OpenShift GitOps operator must already be installed and Argo CD running. Follow [Guide 01](01-install-gitops-operator.md) if you haven't installed it yet.
- **QNAP NAS device** – A QNAP NAS with QTS 5.1.0+ or QuTS hero h5.1.0+, with iSCSI or SMB services enabled and at least one available storage pool.
- **iSCSI utilities** (if using iSCSI protocol) – Install on all master and worker nodes:

  ```bash
  # Single-path (basic connectivity)
  sudo apt install open-iscsi

  # Multipath (recommended for HA)
  sudo apt-get install -y open-iscsi lsscsi sg3-utils multipath-tools scsitools
  sudo sed -i 's/^\(node.session.scan\).*/\1 = manual/' /etc/iscsi/iscsid.conf
  sudo tee /etc/multipath.conf <<-EOF
  defaults {
      user_friendly_names yes
      find_multipaths no
  }
  EOF
  sudo systemctl enable --now multipath-tools.service
  sudo service multipath-tools restart
  ```

- **Network connectivity** – Pods must be able to reach the NAS management IP.

## Overview

The QNAP CSI driver is based on [NetApp Trident](https://github.com/NetApp/trident) and provides dynamic volume provisioning from QNAP NAS devices. Unlike OLM-managed operators, this driver is deployed via raw YAML manifests managed directly by Argo CD.

The deployment includes:
1. **Namespace** – Creates the `trident` namespace
2. **CRD** – Registers the `TridentOrchestrator` and `TridentBackendConfig` custom resource definitions
3. **Bundle** – Service accounts, RBAC roles, deployments (controller + operator), and services
4. **TridentOrchestrator** – The custom resource that bootstraps the Trident operator

## Step 1: Deploy the RBAC for Argo CD

The QNAP CSI driver uses cluster-scoped resources. Argo CD needs elevated permissions to manage them:

```bash
oc apply -f operators/argocd-applications/qnap-csi-rbac.yaml
```

This grants the Argo CD application controller access to `TridentOrchestrator`, `TridentBackendConfig`, PVs, PVCs, and StorageClasses.

## Step 2: Review the Manifests

The driver manifests are in `operators/qnap-csi/`:

| File | Description |
|------|-------------|
| `namespace.yaml` | Creates the `trident` namespace |
| `crd.yaml` | TridentOrchestrator CRD (cluster-scoped) |
| `bundle.yaml` | ServiceAccount, ClusterRoles, Deployments, Services |
| `trident-orchestrator.yaml` | TridentOrchestrator custom resource |
| `kustomization.yaml` | Kustomize config that assembles all resources |

> **Note:** These manifests are mirrored from the [QNAP CSI repository](https://github.com/qnap-dev/QNAP-CSI-PlugIn/tree/main/Deploy) for GitOps management. Update them when upgrading driver versions.

## Step 3: Deploy the QNAP CSI Driver

Apply the Argo CD Application:

```bash
oc apply -f operators/argocd-applications/qnap-csi-app.yaml
```

Argo CD will reconcile the Kustomization and deploy all resources in order.

## Step 4: Wait for the Driver to Be Ready

```bash
# Watch the application status
argocd app get qnap-csi --grpc-web --grpc-web-root-path /

# Check driver pods
oc get pods -n trident -w
```

The driver is ready when both `trident-operator` and `trident-controller` pods are `Running`.

## Step 5: Configure the Backend

The backend connects the CSI driver to your QNAP NAS. Create a YAML file with your NAS credentials and storage pool configuration:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: backend-qts-secret
  namespace: trident
type: Opaque
stringData:
  username: your_nas_username
  password: your_nas_password
  storageAddress: 192.168.1.100  # Your NAS IP
  https: "false"
  port: "8080"
---
apiVersion: trident.qnap.io/v1
kind: TridentBackendConfig
metadata:
  name: backend-qts
  namespace: trident
spec:
  version: 1
  storageDriverName: qnap-nas
  backendName: qts
  credentials:
    name: backend-qts-secret
  storage:
    - serviceLevel: pool1
      labels:
        performance: performance1
```

Apply it:

```bash
kubectl apply -f backend.yaml
```

Verify:

```bash
kubectl get tridentbackendconfig -n trident
```

> **Tip:** See the [QNAP CSI documentation](https://github.com/qnap-dev/QNAP-CSI-PlugIn#CSI-Driver-Configuration) for advanced features: CHAP authentication, HTTPS, multipath, network interfaces, and pool features (tiering, SSD cache, RAID levels).

## Step 6: Create a StorageClass

### iSCSI Protocol

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: qnap-iscsi
provisioner: csi.trident.qnap.io
parameters:
  selector: "performance=performance1"  # Must match backend pool labels
  fsType: "ext4"
  replacementTimeout: "120"
allowVolumeExpansion: true
```

### SMB Protocol

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: qnap-smb
provisioner: csi.trident.qnap.io
parameters:
  selector: "performance=performance1"
  trident.qnap.io/fileProtocol: "smb"
  csi.storage.k8s.io/node-stage-secret-name: "qts-csi-smb"
  csi.storage.k8s.io/node-stage-secret-namespace: "trident"
allowVolumeExpansion: true
```

> For SMB, you also need a secret with valid Samba credentials on the NAS.

## Step 7: Test with a PVC

```yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce  # iSCSI: ReadWriteOnce, SMB: ReadWriteMany
  resources:
    requests:
      storage: 10Gi
  storageClassName: qnap-iscsi
```

Verify:

```bash
kubectl get pvc test-pvc
kubectl get pv
```

The PVC should be `Bound` and a PV should be automatically provisioned.

## Step 8: Verify the Deployment

### Via Argo CD CLI

```bash
# Application status
argocd app get qnap-csi --grpc-web --grpc-web-root-path /

# Diff between desired and actual state
argocd app diff qnap-csi --grpc-web --grpc-web-root-path /
```

### Via `oc` CLI

```bash
# Check driver pods
oc get pods -n trident

# Check the Trident service
oc get service -n trident

# Verify backend
oc get tridentbackendconfig -n trident

# Check StorageClass
oc get storageclass
```

### Via Argo CD UI

1. Get the Argo CD route:

   ```bash
   oc get route openshift-gitops-server -n openshift-gitops
   ```

2. Log in and navigate to the **Applications** section.
3. Find `qnap-csi` and verify **Health** = `Healthy` and **Sync Status** = `Synced`.

## Upgrading the Driver

1. Update the manifests in `operators/qnap-csi/` from the [QNAP CSI repository](https://github.com/qnap-dev/QNAP-CSI-PlugIn).
2. Update the `tridentImage` field in `trident-orchestrator.yaml` to the new version.
3. Commit and push to Git.
4. Argo CD will automatically sync the changes (self-heal + automated sync).

## Deleting the Driver

### Remove the Argo CD Application

```bash
argocd app delete qnap-csi --cascade --grpc-web --grpc-web-root-path /
```

> **Important:** Use `--cascade` to also delete the managed resources. Without it, only the Argo CD Application resource is removed — the driver pods, CRDs, and namespace remain on the cluster.

### Clean Up

After deleting the application, verify cleanup:

```bash
oc get namespace trident
oc get crd tridentorchestrators.trident.qnap.io
oc get crd tridentbackendconfigs.trident.qnap.io
```

To remove lingering CRDs:

```bash
oc delete crd tridentorchestrators.trident.qnap.io
oc delete crd tridentbackendconfigs.trident.qnap.io
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Pods stuck in `Pending` | Check node capacity: `oc describe pod -n trident` |
| Driver can't connect to NAS | Verify network connectivity: `oc run -i --tty ping --image=busybox --restart=Never --rm -- \ping <NAS_IP>` |
| Backend shows `Disconnected` | Check NAS credentials, IP address, and that iSCSI service is enabled on the NAS |
| PVC not binding | Verify `selector` in StorageClass matches `labels` in backend virtual pool |
| iSCSI connection failures | Ensure iSCSI utilities are installed on all nodes; for multipath, verify `multipath.conf` |
| Application shows `OutOfSync` | Run `argocd app diff qnap-csi --grpc-web --grpc-web-root-path /` to identify differences |
| Sync fails | Check pod logs: `oc logs -n trident -l app=operator.trident.qnap.io` |

## References

- [QNAP CSI Driver Repository](https://github.com/qnap-dev/QNAP-CSI-PlugIn)
- [CSI Driver Configuration](https://github.com/qnap-dev/QNAP-CSI-PlugIn#CSI-Driver-Configuration)
- [NetApp Trident Documentation](https://github.com/NetApp/trident)
