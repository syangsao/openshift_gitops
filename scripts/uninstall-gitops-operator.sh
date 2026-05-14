#!/usr/bin/env bash
#
# uninstall-gitops-operator.sh
# Automates the removal of the OpenShift GitOps (Argo CD) operator and all
# related resources from the cluster.
#
# Usage: ./uninstall-gitops-operator.sh [--dry-run] [--help]
#

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
OPERATOR_NAMESPACE="openshift-gitops-operator"
GITOPS_NAMESPACE="openshift-gitops"
NS_TIMEOUT=300   # seconds to wait for namespace deletion
POD_TIMEOUT=300  # seconds to wait for pods to terminate
POLL_INTERVAL=10  # seconds between polls
DRY_RUN=false
DELETE_CRDS=false

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Helpers ────────────────────────────────────────────────────────────────────

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
check()   { echo -e "${GREEN}[CHECK]${NC} $*"; }
dry()     { if [ "$DRY_RUN" = true ]; then echo -e "${BLUE}[DRY-RUN]${NC} Would: $*"; else echo -e "${BLUE}[ACTION]${NC} $*"; fi; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Removes the OpenShift GitOps (Argo CD) operator and all related resources
from the cluster.

Options:
  --dry-run    Show what would be removed without actually deleting.
  --delete-crds  Also delete the CRDs (use with caution - see below).
  --help, -h   Show this help message and exit.

CRDs are cluster-scoped resources that define ArgoCD custom resource types.
Deleting them orphans any ArgoCD resources in other namespaces on the cluster.
Only use --delete-crds if you are sure no ArgoCD resources remain.

Prerequisites:
  - oc CLI installed and available in PATH
  - Logged in to an OpenShift cluster (oc whoami should succeed)
  - Cluster-admin privileges

The script will:
  1. Validate prerequisites (oc CLI, login, cluster-admin role)
  2. Delete ArgoCD instances in all namespaces
  3. Delete the Operator Subscription
  4. Scale operator deployment to 0 (forces pod termination)
  5. Wait for operator pods to terminate
  6. Delete the operator and gitops namespaces (removes CSV, OperatorGroup)
  7. Wait for namespaces to be fully deleted
  8. Verify cleanup (namespaces, ArgoCD instances, CRDs)

WARNING: This operation is irreversible. All ArgoCD instances and operator
resources will be permanently deleted.

EOF
    exit 0
}

# ─── Prerequisite Checks ───────────────────────────────────────────────────────

check_oc_cli() {
    check "Checking oc CLI availability..."
    if ! command -v oc &>/dev/null; then
        error "oc CLI is not installed or not in PATH."
        error "Install it from: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/"
        exit 1
    fi
    info "oc CLI found: $(oc version -o jsonpath='{.client.version}' 2>/dev/null || echo 'version unknown')"
}

check_oc_login() {
    check "Checking cluster login..."
    if ! oc whoami &>/dev/null; then
        error "Not logged in to an OpenShift cluster. Run 'oc login' first."
        exit 1
    fi
    info "Logged in as: $(oc whoami)"
}

check_cluster_admin() {
    check "Checking cluster-admin role..."
    local current_user
    current_user=$(oc whoami)
    if ! oc adm groups list cluster-admin -o name 2>/dev/null | grep -q "cluster-admin"; then
        warn "Could not verify cluster-admin role (oc adm may not be available)."
        warn "Proceeding - please ensure you have cluster-admin privileges."
    else
        if oc adm groups list cluster-admin -o jsonpath='{.items[*].users[*]}' 2>/dev/null | grep -q "$current_user"; then
            info "User '$current_user' has cluster-admin role."
        else
            warn "User '$current_user' does not appear to have cluster-admin role."
            warn "The script may fail. Ensure you have cluster-admin privileges."
        fi
    fi
}

# ─── Pre-flight Checks ─────────────────────────────────────────────────────────

check_gitops_installed() {
    check "Checking if OpenShift GitOps is installed..."
    
    # Check for operator namespace
    if ! oc get namespace "$OPERATOR_NAMESPACE" &>/dev/null; then
        warn "Namespace '$OPERATOR_NAMESPACE' does not exist."
        # Also check gitops namespace as fallback
        if ! oc get namespace "$GITOPS_NAMESPACE" &>/dev/null; then
            error "Neither '$OPERATOR_NAMESPACE' nor '$GITOPS_NAMESPACE' exists."
            error "OpenShift GitOps may not be installed on this cluster."
            exit 1
        fi
    fi
    
    # Check for subscription
    local sub
    sub=$(oc get subscription -n "$OPERATOR_NAMESPACE" -o name 2>/dev/null | head -1 || echo "")
    if [ -z "$sub" ]; then
        warn "No subscription found in namespace '$OPERATOR_NAMESPACE'."
        info "Proceeding - resources may have been partially removed."
    else
        info "Subscription found: $sub"
    fi
    
    info "OpenShift GitOps installation confirmed."
}

find_argocd_instances() {
    check "Scanning for ArgoCD instances in all namespaces..."
    local instances=()
    
    # Check default namespace
    local default_instances
    default_instances=$(oc get argocd -n "$GITOPS_NAMESPACE" -o name 2>/dev/null || echo "")
    if [ -n "$default_instances" ]; then
        instances+=($default_instances)
        info "Found ArgoCD instance(s) in '$GITOPS_NAMESPACE': $default_instances"
    fi
    
    # Check for ArgoCD instances in other namespaces
    local all_namespaces
    all_namespaces=$(oc get namespaces -o name 2>/dev/null | sed 's|namespace/||')
    for ns in $all_namespaces; do
        # Skip known namespaces and system namespaces
        [[ "$ns" == "$OPERATOR_NAMESPACE" ]] && continue
        [[ "$ns" == "$GITOPS_NAMESPACE" ]] && continue
        [[ "$ns" == openshift-* ]] && continue
        [[ "$ns" == kube-* ]] && continue
        [[ "$ns" == default ]] && continue
        
        local ns_instances
        ns_instances=$(oc get argocd -n "$ns" -o name 2>/dev/null || echo "")
        if [ -n "$ns_instances" ]; then
            instances+=($ns_instances)
            info "Found ArgoCD instance(s) in '$ns': $ns_instances"
        fi
    done
    
    if [ ${#instances[@]} -eq 0 ]; then
        info "No ArgoCD instances found."
    else
        info "Total ArgoCD instances found: ${#instances[@]}"
    fi
    
    # Export for use in delete function
    export ARGOCD_INSTANCES="${instances[*]}"
}

# ─── Uninstallation Steps ──────────────────────────────────────────────────────

delete_argocd_instances() {
    check "Deleting ArgoCD instances..."
    
    if [ -z "${ARGOCD_INSTANCES:-}" ]; then
        info "No ArgoCD instances to delete."
        return 0
    fi
    
    for instance in $ARGOCD_INSTANCES; do
        # Parse namespace from name format: argocd/<name> (no namespace)
        # or get the namespace from the original scan
        local name
        name=$(echo "$instance" | sed 's|argocd/||')
        
        # Find which namespace this instance is in
        local found_ns=""
        local all_ns
        all_ns=$(oc get namespaces -o name 2>/dev/null | sed 's|namespace/||')
        for ns in $all_ns; do
            local check
            check=$(oc get argocd "$name" -n "$ns" -o name 2>/dev/null || echo "")
            if [ -n "$check" ]; then
                found_ns="$ns"
                break
            fi
        done
        
        if [ -z "$found_ns" ]; then
            warn "Could not find namespace for ArgoCD instance '$name', skipping."
            continue
        fi
        
        dry "Deleting ArgoCD '$name' in namespace '$found_ns'..."
        if [ "$DRY_RUN" != true ]; then
            if oc delete argocd "$name" -n "$found_ns" 2>/dev/null; then
                info "Deleted ArgoCD instance '$name' in '$found_ns'."
            else
                warn "Failed to delete ArgoCD instance '$name' in '$found_ns'."
                # Try with gitopsservice as fallback
                if oc delete gitopsservice "$name" -n "$found_ns" 2>/dev/null; then
                    info "Deleted via gitopsservice: '$name' in '$found_ns'."
                else
                    error "Could not delete ArgoCD instance '$name' in '$found_ns'. Check manually."
                fi
            fi
        fi
    done
    
    # Specifically delete the default instance using gitopsservice (per Red Hat docs)
    dry "Deleting default ArgoCD via gitopsservice in '$GITOPS_NAMESPACE'..."
    if [ "$DRY_RUN" != true ]; then
        if oc delete gitopsservice cluster -n "$GITOPS_NAMESPACE" 2>/dev/null; then
            info "Deleted Gitopsservice 'cluster' in '$GITOPS_NAMESPACE'."
        else
            warn "Gitopsservice 'cluster' not found or already deleted in '$GITOPS_NAMESPACE'."
        fi
    fi
}

delete_subscription() {
    check "Deleting Operator Subscription..."
    
    local subs
    subs=$(oc get subscription -n "$OPERATOR_NAMESPACE" -o name 2>/dev/null || echo "")
    
    if [ -z "$subs" ]; then
        info "No subscription found in '$OPERATOR_NAMESPACE'. Skipping."
        return 0
    fi
    
    for sub in $subs; do
        local name
        name=$(echo "$sub" | sed 's|subscription.operators.coreos.com/||')
        dry "Deleting subscription '$name' in '$OPERATOR_NAMESPACE'..."
        if [ "$DRY_RUN" != true ]; then
            if oc delete subscription "$name" -n "$OPERATOR_NAMESPACE" 2>/dev/null; then
                info "Deleted subscription '$name'."
            else
                warn "Failed to delete subscription '$name'."
            fi
        fi
    done
}

force_stop_operator() {
    check "Stopping operator deployment..."
    
    # Scale the deployment to 0 so operator pods terminate immediately.
    # OLM does not delete the deployment promptly after subscription removal,
    # so we do it manually to avoid waiting 300s.
    local deploy
    deploy=$(oc get deployment -n "$OPERATOR_NAMESPACE" -o name 2>/dev/null | head -1 || echo "")
    
    if [ -z "$deploy" ]; then
        info "No deployment found in '$OPERATOR_NAMESPACE'. Skipping."
        return 0
    fi
    
    local name
    name=$(echo "$deploy" | sed 's|deployment.apps/||')
    dry "Scaling deployment '$name' to 0 replicas..."
    if [ "$DRY_RUN" != true ]; then
        if oc scale deployment "$name" --replicas=0 -n "$OPERATOR_NAMESPACE" 2>/dev/null; then
            info "Scaled deployment '$name' to 0 replicas."
        else
            warn "Failed to scale deployment '$name'. Pods may take longer to terminate."
        fi
    fi
}

wait_for_pods_terminated() {
    local namespace="$1"
    check "Waiting for pods in '${namespace}' to terminate (timeout: ${POD_TIMEOUT}s)..."
    
    if [ "$DRY_RUN" = true ]; then
        info "[DRY-RUN] Would wait for pods in '${namespace}' to terminate."
        return 0
    fi
    
    local elapsed=0
    while [ "$elapsed" -lt "$POD_TIMEOUT" ]; do
        local pod_count
        pod_count=$(oc get pods -n "$namespace" --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$pod_count" -eq 0 ]; then
            info "All pods in '${namespace}' have terminated."
            return 0
        fi
        
        local remaining
        remaining=$(oc get pods -n "$namespace" --no-headers 2>/dev/null | awk '{print $1, $3}' || echo "")
        warn "Pods still running in '${namespace}': $remaining (${elapsed}s elapsed)"
        
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    
    error "Not all pods in '${namespace}' terminated within ${POD_TIMEOUT}s."
    oc get pods -n "$namespace" 2>/dev/null || true
    exit 1
}

delete_namespaces() {
    check "Deleting GitOps namespaces..."
    
    local namespaces=("$OPERATOR_NAMESPACE" "$GITOPS_NAMESPACE")
    
    for namespace in "${namespaces[@]}"; do
        if ! oc get namespace "$namespace" &>/dev/null; then
            info "Namespace '${namespace}' does not exist. Skipping."
            continue
        fi
        
        dry "Deleting namespace '${namespace}'..."
        if [ "$DRY_RUN" != true ]; then
            if oc delete namespace "$namespace" 2>/dev/null; then
                info "Namespace '${namespace}' deletion initiated."
            else
                warn "Failed to delete namespace '${namespace}'."
            fi
        fi
    done
}

wait_for_namespace_deletion() {
    local namespace="$1"
    check "Waiting for namespace '${namespace}' to be deleted..."
    
    if [ "$DRY_RUN" = true ]; then
        info "[DRY-RUN] Would wait for namespace '${namespace}' to be deleted."
        return 0
    fi
    
    local elapsed=0
    while [ "$elapsed" -lt "$NS_TIMEOUT" ]; do
        if ! oc get namespace "$namespace" &>/dev/null; then
            info "Namespace '${namespace}' has been deleted."
            return 0
        fi
        
        local status
        status=$(oc get namespace "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        warn "Namespace '${namespace}' status: $status (${elapsed}s elapsed)"
        
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    
    warn "Namespace '${namespace}' has not been fully deleted within ${NS_TIMEOUT}s."
    warn "It will be cleaned up by the garbage collector."
}

delete_crds() {
    check "Deleting GitOps CRDs..."
    
    # CRDs are cluster-scoped and deletion orphans any remaining ArgoCD resources.
    # Only delete them if --delete-crds was explicitly requested.
    local crd_names=("argocds.argoproj.io" "gitopsservices.pipelines.openshift.io" "appprojects.argoproj.io" "applications.argoproj.io")
    
    for crd in "${crd_names[@]}"; do
        if ! oc get crd "$crd" &>/dev/null; then
            info "CRD '$crd' already absent. Skipping."
            continue
        fi
        
        dry "Deleting CRD '$crd'..."
        if [ "$DRY_RUN" != true ]; then
            if oc delete crd "$crd" 2>/dev/null; then
                info "Deleted CRD '$crd'."
            else
                warn "Failed to delete CRD '$crd'. It may be in use by other resources."
            fi
        fi
    done
}

verify_cleanup() {
    check "Verifying cleanup..."
    local errors=0
    
    # Check operator namespace
    if oc get namespace "$OPERATOR_NAMESPACE" &>/dev/null; then
        warn "Namespace '$OPERATOR_NAMESPACE' still exists."
        errors=$((errors + 1))
    else
        info "Namespace '$OPERATOR_NAMESPACE' removed."
    fi
    
    # Check gitops namespace
    if oc get namespace "$GITOPS_NAMESPACE" &>/dev/null; then
        warn "Namespace '$GITOPS_NAMESPACE' still exists."
        errors=$((errors + 1))
    else
        info "Namespace '$GITOPS_NAMESPACE' removed."
    fi
    
    # Check for remaining ArgoCD instances
    local remaining
    remaining=$(oc get argocd -A -o name 2>/dev/null || echo "")
    if [ -n "$remaining" ]; then
        warn "Remaining ArgoCD instances: $remaining"
        errors=$((errors + 1))
    else
        info "No ArgoCD instances remaining."
    fi
    
    # Check for remaining subscriptions
    local subs
    subs=$(oc get subscription -n "$OPERATOR_NAMESPACE" -o name 2>/dev/null || echo "")
    if [ -n "$subs" ]; then
        warn "Remaining subscriptions: $subs"
        errors=$((errors + 1))
    else
        info "No subscriptions remaining."
    fi
    
    # Check for remaining CRDs
    # CRDs are cluster-scoped and OLM does not automatically clean them up.
    # They linger indefinitely but are harmless metadata.
    # Do NOT count them as errors - this is expected behavior.
    local crd_patterns=("argocds.argoproj.io" "gitopsservices.pipelines.openshift.io" "appprojects.argoproj.io" "applications.argoproj.io")
    local crds_remaining=0
    for pattern in "${crd_patterns[@]}"; do
        if oc get crd "$pattern" &>/dev/null; then
            crds_remaining=$((crds_remaining + 1))
        fi
    done
    
    if [ "$crds_remaining" -gt 0 ]; then
        warn "$crds_remaining CRD(s) still exist. This is expected - OLM does not automatically clean up CRDs."
        info "To remove them manually, run:"
        info "  oc delete crd argocds.argoproj.io gitopsservices.pipelines.openshift.io appprojects.argoproj.io applications.argoproj.io"
        info "WARNING: Only delete CRDs if you have no ArgoCD resources in other namespaces."
    else
        info "All CRDs removed."
    fi
    
    if [ "$errors" -eq 0 ]; then
        info "Cleanup verified - all resources removed successfully."
    else
        warn "$errors issue(s) found during verification. Check output above."
    fi
}

# ─── Main ──────────────────────────────────────────────────────────────────────

main() {
    # Handle flags
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=true ;;
            --delete-crds) DELETE_CRDS=true ;;
            --help|-h) usage ;;
        esac
    done
    
    if [ "$DRY_RUN" = true ]; then
        echo ""
        echo "========================================"
        info "OpenShift GitOps Uninstaller (DRY RUN)"
        echo "========================================"
        echo ""
        warn "No resources will be deleted."
        echo ""
    else
        echo ""
        echo "========================================"
        info "OpenShift GitOps Uninstaller"
        echo "========================================"
        echo ""
        warn "WARNING: This operation is irreversible."
        echo ""
    fi
    
    # Prerequisites
    check_oc_cli
    check_oc_login
    check_cluster_admin
    
    # Pre-flight
    check_gitops_installed
    echo ""
    info "Starting GitOps operator uninstallation..."
    echo ""
    
    # Step 1: Delete ArgoCD instances
    find_argocd_instances
    echo ""
    delete_argocd_instances
    echo ""
    
    # Step 2: Delete subscription
    delete_subscription
    echo ""
    
    # Step 3: Scale operator deployment to 0 so pods terminate immediately
    force_stop_operator
    echo ""
    
    # Step 4: Wait for pods to terminate
    wait_for_pods_terminated "$OPERATOR_NAMESPACE"
    wait_for_pods_terminated "$GITOPS_NAMESPACE"
    echo ""
    
    # Step 4: Delete namespaces
    # Deleting the namespaces removes the CSV, OperatorGroup, and all other resources
    # This is more reliable than deleting individual OLM resources which can hang
    delete_namespaces
    echo ""
    
    # Step 5: Wait for namespaces to be deleted
    wait_for_namespace_deletion "$OPERATOR_NAMESPACE"
    wait_for_namespace_deletion "$GITOPS_NAMESPACE"
    echo ""
    
    # Step 5.5: Optionally delete CRDs
    if [ "$DELETE_CRDS" = true ]; then
        delete_crds
        echo ""
    fi
    
    # Step 6: Verify cleanup
    verify_cleanup
}

main "$@"
