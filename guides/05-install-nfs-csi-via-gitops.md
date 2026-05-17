# Installing the NFS CSI Driver via Argo CD (GitOps)

This guide walks through deploying the [NFS CSI Driver](https://github.com/kubernetes-csi/csi-driver-nfs) on your OpenShift cluster using Argo CD, leveraging the GitOps workflow already in place.

## Prerequisites

- **GitOps operator installed** – The OpenShift GitOps operator must already be installed and Argo CD running. Follow [Guide 01](01-install-gitops-operator.md) if you haven't installed it yet.
- **NFS server** – An NFS server (RHEL, Ubuntu, or any NFS-compatible server) with at least one shared directory configured.
- **OpenShift cluster** – Version 4.x+ with cluster-admin privileges.
- **`oc` CLI** – Installed and authenticated to your cluster.

## Overview

The NFS CSI driver is the upstream Kubernetes CSI driver for NFS. It enables dynamic provisioning of persistent volumes from any NFS server, supporting `ReadWriteMany` access mode and volume snapshots. Unlike the QNAP driver which uses NetApp Trident, this driver uses the standard Kubernetes CSI framework.

The deployment includes:
1. **Namespace** – Creates the `csi-driver-nfs` namespace
2. **RBAC** – Service accounts, cluster roles, and cluster role bindings for controller, node, and snapshot components
3. **Controller** – Deployment with 2 replicas, RollingUpdate strategy, running on control-plane nodes
4. **Node** – DaemonSet that runs on every cluster node
5. **External Snapshotter** – Controller for volume snapshot functionality

> **Note:** The VolumeSnapshot CRDs (`VolumeSnapshotClass`, `VolumeSnapshot`, `VolumeSnapshotContent`) must be pre-installed on the cluster. On OpenShift, these are typically provided by the OpenShift Data Foundation operator or can be installed separately.

## Step 1: Deploy the RBAC for Argo CD

The NFS CSI driver uses cluster-scoped resources. Argo CD needs elevated permissions to manage them:

```bash
oc apply -f operators/argocd-applications/nfs-csi-rbac.yaml
```

This grants the Argo CD application controller access to PVs, PVCs, StorageClasses, volume snapshots, CSINodes, and volume attachments.

## Step 2: Review the Manifests

The driver manifests are in `operators/nfs-csi/`:

| File | Description |
|------|-------------|
| `namespace.yaml` | Creates the `csi-driver-nfs` namespace |
| `rbac.yaml` | ServiceAccounts, ClusterRoles, ClusterRoleBindings |
| `controller.yaml` | Controller deployment (2 replicas, RollingUpdate) |
| `node.yaml` | Node daemonset |
| `external-snapshotter.yaml` | External snapshotter controller deployment |
| `kustomization.yaml` | Kustomize config that assembles all resources |

> **Note:** These manifests are extracted and simplified from the [official Helm chart](https://github.com/kubernetes-csi/csi-driver-nfs/tree/master/charts/csi-driver-nfs) with the following Helm values applied:
>
> - `controller.runOnControlPlane=true`
> - `controller.replicas=2`
> - `controller.strategyType=RollingUpdate`
> - `externalSnapshotter.enabled=true`
> - `externalSnapshotter.customResourceDefinitions.enabled=false`

## Step 3: Deploy the NFS CSI Driver

Apply the Argo CD Application:

```bash
oc apply -f operators/argocd-applications/nfs-csi-app.yaml
```

Argo CD will reconcile the Kustomization and deploy all resources in order.

## Step 4: Grant Privileged SCC

On OpenShift, the NFS CSI driver requires the `privileged` Security Context Constraint (SCC) for both the controller and node service accounts. This is required because the driver needs to mount NFS volumes on the host.

```bash
oc adm policy add-scc-to-user privileged -z csi-nfs-node-sa -n csi-driver-nfs
oc adm policy add-scc-to-user privileged -z csi-nfs-controller-sa -n csi-driver-nfs
```

> **Important:** This step cannot be done via Argo CD automatically because SCC bindings on OpenShift require cluster-admin privileges through the `oc adm` command. Run this manually after the driver pods are deployed.

## Step 5: Wait for the Driver to Be Ready

```bash
# Watch the application status
argocd app get nfs-csi --grpc-web --grpc-web-root-path /

# Check driver pods
oc get pods -n csi-driver-nfs -w
```

The driver is ready when all pods are `Running`:
- `nfs-csi-controller-*` (2 replicas)
- `nfs-csi-node-*` (1 per node)
- `nfs-csi-snapshot-controller-*` (2 replicas)

## Step 6: Create a StorageClass

Create a StorageClass that references your NFS server:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
provisioner: nfs.csi.k8s.io
parameters:
  server: "192.168.1.100"   # Your NFS server IP or hostname
  share: "/exports"          # NFS export path
  mountOptions:
    - hard
    - vers=4.1
    - nconnect=1
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
```

Apply it:

```bash
kubectl apply -f storageclass.yaml
```

Verify:

```bash
kubectl get storageclass
```

> **Tip:** Adjust the `server`, `share`, and `mountOptions` parameters to match your NFS server configuration. For NFS v3, use `vers=3`. For NFS v4.1+, use `vers=4.1` with `nconnect` for parallel connections.

## Step 7: Create a VolumeSnapshotClass

If you plan to use volume snapshots, create a VolumeSnapshotClass:

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: csi-nfs-snapshot
driver: nfs.csi.k8s.io
deletionPolicy: Delete
```

Apply it:

```bash
kubectl apply -f volumesnapshotclass.yaml
```

Verify:

```bash
kubectl get volumesnapshotclass
```

> **Note:** VolumeSnapshot CRDs must already exist on your cluster. If you don't have them, install the snapshot controller or enable OpenShift Data Foundation.

## Step 8: Test with a PVC

Create a test PVC to verify the driver works:

```yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: test-nfs-pvc
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  storageClassName: nfs-csi
```

Apply it:

```bash
kubectl apply -f pvc.yaml
```

Verify:

```bash
kubectl get pvc test-nfs-pvc
kubectl get pv
```

The PVC should be `Bound` and a PV should be automatically provisioned with the NFS mount path.

### Test Snapshot

Create a test volume snapshot:

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: test-nfs-snapshot
  namespace: default
spec:
  volumeSnapshotClassName: csi-nfs-snapshot
  source:
    persistentVolumeClaimName: test-nfs-pvc
```

Verify:

```bash
kubectl get volumesnapshot test-nfs-snapshot
```

## Step 9: Verify the Deployment

### Via Argo CD CLI

```bash
# Application status
argocd app get nfs-csi --grpc-web --grpc-web-root-path /

# Diff between desired and actual state
argocd app diff nfs-csi --grpc-web --grpc-web-root-path /
```

### Via `oc` CLI

```bash
# Check driver pods
oc get pods -n csi-driver-nfs

# Check deployments
oc get deployments -n csi-driver-nfs

# Check daemonset
oc get daemonset -n csi-driver-nfs

# Check StorageClass
oc get storageclass

# Check VolumeSnapshotClass
oc get volumesnapshotclass
```

### Via Argo CD UI

1. Get the Argo CD route:

   ```bash
   oc get route openshift-gitops-server -n openshift-gitops
   ```

2. Log in and navigate to the **Applications** section.
3. Find `nfs-csi` and verify **Health** = `Healthy` and **Sync Status** = `Synced`.

## Upgrading the Driver

1. Update the image tags in `operators/nfs-csi/controller.yaml`, `operators/nfs-csi/node.yaml`, and `operators/nfs-csi/external-snapshotter.yaml` to the new versions.
2. Commit and push to Git.
3. Argo CD will automatically sync the changes (self-heal + automated sync).

To find the latest version, check the [csi-driver-nfs releases](https://github.com/kubernetes-csi/csi-driver-nfs/releases).

## Deleting the Driver

### Remove the Argo CD Application

```bash
argocd app delete nfs-csi --cascade --grpc-web --grpc-web-root-path /
```

> **Important:** Use `--cascade` to also delete the managed resources. Without it, only the Argo CD Application resource is removed — the driver pods, RBAC, and namespace remain on the cluster.

### Clean Up

After deleting the application, verify cleanup:

```bash
oc get namespace csi-driver-nfs
oc get sc nfs-csi
oc get volumesnapshotclass csi-nfs-snapshot
```

Remove any lingering resources:

```bash
oc delete sc nfs-csi
oc delete volumesnapshotclass csi-nfs-snapshot
oc delete namespace csi-driver-nfs
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Pods stuck in `Pending` | Check node capacity: `oc describe pod -n csi-driver-nfs` |
| Driver can't mount NFS | Verify NFS server connectivity: `oc run -i --tty test-pod --image=busybox --restart=Never --rm -- ping <NFS_SERVER_IP>` |
| Pods in `ContainerCannotRun` | Ensure privileged SCC is granted: `oc adm policy add-scc-to-user privileged -z csi-nfs-node-sa -n csi-driver-nfs` |
| PVC not binding | Verify `server` and `share` parameters in StorageClass match your NFS server configuration |
| Volume snapshot fails | Ensure VolumeSnapshot CRDs exist: `oc get crd \| grep snapshot` |
| Permission denied on mounted volume | Check NFS server export options — `no_root_squash` may be needed, or adjust UID/GID mapping. See [ACL Appendix](#appendix-acl-causing-permission-denied-errors) |
| Application shows `OutOfSync` | Run `argocd app diff nfs-csi --grpc-web --grpc-web-root-path /` to identify differences |
| Sync fails | Check pod logs: `oc logs -n csi-driver-nfs -l app=nfs-csi-driver` |

## Appendix: Updating Image Registry to Use NFS Storage

You can configure the OpenShift Image Registry to use NFS storage for persistent image storage. This is useful for clusters without other storage options.

```yaml
apiVersion: imageregistry.operator.openshift.io/v1
kind: Config
metadata:
  name: cluster
spec:
  storage:
    pvc:
      claim: ""
  logLevel: Normal
  proxies: null
```

Then create a PVC using the `nfs-csi` StorageClass:

```yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: registry-nfs-pvc
  namespace: openshift-image-registry
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 50Gi
  storageClassName: nfs-csi
```

Update the registry config to use the PVC:

```yaml
apiVersion: imageregistry.operator.openshift.io/v1
kind: Config
metadata:
  name: cluster
spec:
  storage:
    pvc:
      claim: registry-nfs-pvc
```

> **Warning:** NFS may not provide the performance needed for high-throughput image registries. Consider dedicated storage (Ceph, NFS with high performance, etc.) for production clusters.

## Appendix: Setting Up RHEL as an NFS Server

### Install NFS Server

```bash
sudo dnf install -y nfs-utils
sudo systemctl enable --now nfs-server rpcbind
```

### Create Export Directory

```bash
sudo mkdir -p /exports
sudo chmod 777 /exports
```

### Configure Exports

Edit `/etc/exports`:

```
/exports *(rw,sync,no_root_squash,no_subtree_check)
```

Apply exports:

```bash
sudo exportfs -ra
```

### Verify

```bash
showmount -e localhost
```

### Firewall

```bash
sudo firewall-cmd --permanent --add-service=nfs
sudo firewall-cmd --permanent --add-service=mountd
sudo firewall-cmd --permanent --add-service=rpc-bind
sudo firewall-cmd --reload
```

## Appendix: Setting Up Ubuntu as an NFS Server

### Install NFS Server

```bash
sudo apt update
sudo apt install -y nfs-kernel-server
```

### Create Export Directory

```bash
sudo mkdir -p /exports
sudo chmod 777 /exports
```

### Configure Exports

Edit `/etc/exports`:

```
/exports *(rw,sync,no_root_squash,no_subtree_check)
```

Apply exports:

```bash
sudo exportfs -ra
sudo systemctl restart nfs-kernel-server
```

### Verify

```bash
showmount -e localhost
```

### Firewall (ufw)

```bash
sudo ufw allow nfs
sudo ufw allow mountd
sudo ufw allow rpcbind
sudo ufw reload
```

## Appendix: ACL Causing Permission Denied Errors

If pods get `Permission denied` when accessing NFS-mounted volumes, it's often caused by NFS Access Control Lists (ACLs) or SELinux on the NFS server.

### Common Causes

1. **`root_squash`** (default) — Maps root UID/GID to `nfsnobody`. If your workload runs as root, files created by root on the NFS share are owned by `nfsnobody`, causing permission issues.

   **Fix:** Use `no_root_squash` in `/etc/exports` (less secure) or run containers with a non-root UID.

2. **SELinux on NFS server** — SELinux may block NFS access.

   **Fix:** Set the correct SELinux context:
   ```bash
   sudo chcon -Rt public_content_rw_t /exports
   ```

3. **POSIX ACLs** — If ACLs are enabled on the NFS server filesystem, they may restrict access.

   **Fix:** Remove restrictive ACLs:
   ```bash
   setfacl -b /exports
   ```

4. **NFSv4 ID Mapping** — NFSv4 uses names (user/group) instead of numeric IDs. If ID mapping is misconfigured, permissions fail.

   **Fix:** Ensure consistent `nfs-idmapd.conf` settings on both server and clients.

### Debugging Steps

```bash
# Check NFS mount options
mount | grep nfs

# Check NFS server exports
showmount -e <NFS_SERVER_IP>

# Test NFS connectivity from a pod
oc run -i --tty nfs-test --image=busybox --restart=Never --rm -- sh
# Inside the pod:
mount -t nfs <NFS_SERVER_IP>:/exports /mnt
touch /mnt/test-file
ls -la /mnt
```

## Appendix: Logs and Debugging

### Check Driver Pod Logs

```bash
# Controller logs
oc logs -n csi-driver-nfs -l app=nfs-csi-driver,role=nfs-csi-controller -c nfs-provisioner
oc logs -n csi-driver-nfs -l app=nfs-csi-driver,role=nfs-csi-controller -c external-provisioner
oc logs -n csi-driver-nfs -l app=nfs-csi-driver,role=nfs-csi-controller -c external-resizer
oc logs -n csi-driver-nfs -l app=nfs-csi-driver,role=nfs-csi-controller -c external-attacher

# Node logs
oc logs -n csi-driver-nfs -l app=nfs-csi-driver,role=nfs-csi-node -c nfs-provisioner
oc logs -n csi-driver-nfs -l app=nfs-csi-driver,role=nfs-csi-node -c node-driver-registrar

# Snapshotter logs
oc logs -n csi-driver-nfs -l app=nfs-csi-driver,role=nfs-csi-snapshot-controller
```

### Describe Problematic Pods

```bash
oc describe pod -n csi-driver-nfs <pod-name>
```

### Check CSI Driver Registration

```bash
oc get csinode
oc get volumeattachment
```

### Check NFS Server Connectivity

```bash
# From a worker node
ssh <worker-node>
mount -t nfs <NFS_SERVER_IP>:/exports /tmp/test-mount
ls -la /tmp/test-mount
umount /tmp/test-mount
```

### Check StorageClass and PV/PVC

```bash
oc get storageclass
oc describe storageclass nfs-csi
oc get pv
oc describe pv <pv-name>
oc get pvc
oc describe pvc <pvc-name>
```

## References

- [NFS CSI Driver Repository](https://github.com/kubernetes-csi/csi-driver-nfs)
- [NFS CSI Driver Helm Chart](https://github.com/kubernetes-csi/csi-driver-nfs/tree/master/charts/csi-driver-nfs)
- [CSI Driver Documentation](https://kubernetes-csi.github.io/docs/)
- [Kubernetes Volume Snapshots](https://kubernetes.io/docs/concepts/storage/volume-snapshots/)
- [OpenShift Persistent Volumes](https://docs.openshift.com/container-platform/latest/storage/persistent_storage/persistent-storage.html)
