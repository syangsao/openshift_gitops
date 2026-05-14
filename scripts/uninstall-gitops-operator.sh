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
CSV_TIMEOUT=300   # seconds to wait for CSV removal
POD_TIMEOUT=300   # seconds to wait for pods to terminate
POLL_INTERVAL=10  # seconds between polls
DRY_RUN=false

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
  --help, -h   Show this help message and exit.

Prerequisites:
  - oc CLI installed and available in PATH
  - Logged in to an OpenShift cluster (oc whoami should succeed)
  - Cluster-admin privileges

The script will:
  1. Validate prerequisites (oc CLI, login, cluster-admin role)
  2. Delete ArgoCD instances in all namespaces
  3. Delete the Operator Subscription
  4. Wait for the CSV to be removed
  5. Wait for operator pods to terminate
  6. Delete the OperatorGroup
  7. Delete the operator namespace
  8. Verify cleanup

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

wait_for_csv_removal() {
    check "Waiting for CSV to be removed (timeout: ${CSV_TIMEOUT}s)..."
    
    if [ "$DRY_RUN" = true ]; then
        info "[DRY-RUN] Would wait for CSV removal."
        return 0
    fi
    
    local elapsed=0
    while [ "$elapsed" -lt "$CSV_TIMEOUT" ]; do
        local csv_count
        csv_count=$(oc get csv -n "$OPERATOR_NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$csv_count" -eq 0 ]; then
            info "CSV has been removed."
            return 0
        fi
        
        local phase
        phase=$(oc get csv -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "unknown")
        warn "CSV still present (phase: $phase, ${elapsed}s elapsed)"
        
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    
    error "CSV was not removed within ${CSV_TIMEOUT}s."
    oc get csv -n "$OPERATOR_NAMESPACE" 2>/dev/null || true
    exit 1
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

delete_operator_group() {
    check "Deleting OperatorGroup..."
    
    local ogs
    ogs=$(oc get operatorgroup -n "$OPERATOR_NAMESPACE" -o name 2>/dev/null || echo "")
    
    if [ -z "$ogs" ]; then
        info "No OperatorGroup found in '$OPERATOR_NAMESPACE'. Skipping."
        return 0
    fi
    
    for og in $ogs; do
        local name
        name=$(echo "$og" | sed 's|operatorgroup.operators.coreos.com/||')
        dry "Deleting OperatorGroup '$name' in '$OPERATOR_NAMESPACE'..."
        if [ "$DRY_RUN" != true ]; then
            if oc delete operatorgroup "$name" -n "$OPERATOR_NAMESPACE" 2>/dev/null; then
                info "Deleted OperatorGroup '$name'."
            else
                warn "Failed to delete OperatorGroup '$name'."
            fi
        fi
    done
}

delete_namespace() {
    local namespace="$1"
    check "Deleting namespace '${namespace}'..."
    
    if ! oc get namespace "$namespace" &>/dev/null; then
        info "Namespace '${namespace}' does not exist. Skipping."
        return 0
    fi
    
    dry "Deleting namespace '${namespace}'..."
    if [ "$DRY_RUN" != true ]; then
        if oc delete namespace "$namespace" 2>/dev/null; then
            info "Namespace '${namespace}' deletion initiated."
            # Wait for namespace to be fully deleted
            wait_for_namespace_deletion "$namespace"
        else
            error "Failed to delete namespace '${namespace}'."
        fi
    fi
}

wait_for_namespace_deletion() {
    local namespace="$1"
    check "Waiting for namespace '${namespace}' to be deleted..."
    
    local elapsed=0
    local timeout=120
    while [ "$elapsed" -lt "$timeout" ]; do
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
    
    warn "Namespace '${namespace}' has not been fully deleted within ${timeout}s."
    warn "It will be cleaned up by the garbage collector."
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
    
    # Check gitops namespace (may still exist if user created resources there)
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
        error "WARNING: This will permanently remove OpenShift GitOps"
        echo "========================================"
        echo ""
        echo ""
        echo "========================================"
        info "OpenShift GitOps Uninstaller"
        echo "========================================"
        echo ""
    fi
    
    # Prerequisites
    check_oc_cli
    check_oc_login
    check_cluster_admin
    
    echo ""
    check_gitops_installed
    
    if [ "$DRY_RUN" != true ]; then
        echo ""
        info "Starting GitOps operator uninstallation..."
        echo ""
    else
        echo ""
        info "Showing what would be removed..."
        echo ""
    fi
    
    # Scan for ArgoCD instances
    find_argocd_instances
    
    # Step 1: Delete ArgoCD instances
    delete_argocd_instances
    
    # Step 2: Delete subscription
    delete_subscription
    
    # Step 3: Wait for CSV removal
    wait_for_csv_removal
    
    # Step 4: Wait for operator pods to terminate
    wait_for_pods_terminated "$OPERATOR_NAMESPACE"
    wait_for_pods_terminated "$GITOPS_NAMESPACE"
    
    # Step 5: Delete OperatorGroup
    delete_operator_group
    
    # Step 6: Delete namespaces
    delete_namespace "$OPERATOR_NAMESPACE"
    delete_namespace "$GITOPS_NAMESPACE"
    
    echo ""
    if [ "$DRY_RUN" = true ]; then
        echo "========================================"
        info "Dry run complete. No changes were made."
        echo "========================================"
    else
        # Step 7: Verify cleanup
        verify_cleanup
        
        echo ""
        echo "========================================"
        info "GitOps operator uninstalled successfully!"
        echo "========================================"
    fi
    echo ""
}

main "$@"
