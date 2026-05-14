#!/usr/bin/env bash
#
# install-gitops-operator.sh
# Automates the installation of the OpenShift GitOps (Argo CD) operator.
#
# Usage: ./install-gitops-operator.sh [--help]
#

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
OPERATOR_NAMESPACE="openshift-gitops-operator"
GITOPS_NAMESPACE="openshift-gitops"
CSV_TIMEOUT=600   # seconds to wait for CSV
POD_TIMEOUT=600   # seconds to wait for pods
ARGOCD_TIMEOUT=300 # seconds to wait for ArgoCD instance
POLL_INTERVAL=10  # seconds between polls

# Script directory (for locating YAML files)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPERATORS_DIR="${SCRIPT_DIR}/../operators"

# ─── Helpers ────────────────────────────────────────────────────────────────────

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
check()   { echo -e "${GREEN}[CHECK]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Automatically install the OpenShift GitOps operator on your cluster.

Options:
  --help, -h    Show this help message and exit.

Prerequisites:
  - oc CLI installed and available in PATH
  - Logged in to an OpenShift cluster (oc whoami should succeed)
  - Cluster-admin privileges
  - OpenShift Container Platform Marketplace capability enabled

The script will:
  1. Validate prerequisites (oc CLI, login, cluster-admin role)
  2. Create the openshift-gitops-operator namespace
  3. Apply the OperatorGroup
  4. Apply the Subscription
  5. Wait for the CSV to reach Succeeded phase
  6. Wait for all pods in openshift-gitops and openshift-gitops-operator namespaces
  7. Wait for the ArgoCD instance to be created
  8. Display the Argo CD UI URL, admin password, and login command

Requires 'jq' to be installed to retrieve the admin password.

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

check_marketplace() {
    check "Checking Marketplace capability..."
    local caps
    caps=$(oc get clusterversion version -o jsonpath='{.status.capabilities.status}' 2>/dev/null || echo "")
    if [ "$caps" = "Full" ] || [ "$caps" = "Progressing" ]; then
        info "Marketplace capability: $caps"
    else
        warn "Could not verify Marketplace capability. It should be enabled by default."
    fi
}

# ─── Installation Steps ────────────────────────────────────────────────────────

create_namespace() {
    check "Creating namespace $OPERATOR_NAMESPACE..."
    if oc get namespace "$OPERATOR_NAMESPACE" &>/dev/null; then
        info "Namespace '$OPERATOR_NAMESPACE' already exists. Skipping."
    else
        oc create namespace "$OPERATOR_NAMESPACE"
        info "Namespace '$OPERATOR_NAMESPACE' created."
    fi
}

apply_operator_group() {
    check "Applying OperatorGroup..."
    local og_file="${OPERATORS_DIR}/gitops/operator-group.yaml"
    if [ ! -f "$og_file" ]; then
        error "OperatorGroup manifest not found at: $og_file"
        exit 1
    fi
    oc apply -f "$og_file"
    info "OperatorGroup applied."
}

apply_subscription() {
    check "Applying Subscription..."
    local sub_file="${OPERATORS_DIR}/gitops/subscription.yaml"
    if [ ! -f "$sub_file" ]; then
        error "Subscription manifest not found at: $sub_file"
        exit 1
    fi
    oc apply -f "$sub_file"
    info "Subscription applied."
}

wait_for_csv() {
    check "Waiting for CSV to reach Succeeded phase (timeout: ${CSV_TIMEOUT}s)..."
    local elapsed=0
    while [ "$elapsed" -lt "$CSV_TIMEOUT" ]; do
        local phase
        phase=$(oc get csv -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
        if [ "$phase" = "Succeeded" ]; then
            info "CSV phase: Succeeded"
            return 0
        fi
        if [ -n "$phase" ] && [ "$phase" != "" ]; then
            warn "CSV phase: $phase (${elapsed}s elapsed)"
        fi
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    error "CSV did not reach Succeeded phase within ${CSV_TIMEOUT}s."
    local final_phase
    final_phase=$(oc get csv -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "unknown")
    error "Final CSV phase: $final_phase"
    exit 1
}

wait_for_pods() {
    local namespace="$1"
    check "Waiting for all pods in '${namespace}' to be Running (timeout: ${POD_TIMEOUT}s)..."
    local elapsed=0
    while [ "$elapsed" -lt "$POD_TIMEOUT" ]; do
        local failing
        failing=$(oc get pods -n "$namespace" --no-headers 2>/dev/null | awk '$2 !~ /Running|Completed/ {print $1, $2}' || echo "")
        if [ -z "$failing" ]; then
            info "All pods in '${namespace}' are Running."
            return 0
        fi
        warn "Pods not yet ready in '${namespace}': $failing (${elapsed}s elapsed)"
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    error "Not all pods in '${namespace}' reached Running state within ${POD_TIMEOUT}s."
    oc get pods -n "$namespace"
    exit 1
}

wait_for_argocd() {
    check "Waiting for ArgoCD instance in '${GITOPS_NAMESPACE}' (timeout: ${ARGOCD_TIMEOUT}s)..."
    local elapsed=0
    while [ "$elapsed" -lt "$ARGOCD_TIMEOUT" ]; do
        local argocd
        argocd=$(oc get argocd -n "$GITOPS_NAMESPACE" -o name 2>/dev/null || echo "")
        if [ -n "$argocd" ]; then
            info "ArgoCD instance found: $argocd"
            # Also wait for the ArgoCD instance to be established
            local conditions
            conditions=$(oc get argocd "$argocd" -n "$GITOPS_NAMESPACE" -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || echo "")
            if echo "$conditions" | grep -q "Established"; then
                info "ArgoCD instance is Established."
                return 0
            fi
            warn "ArgoCD instance exists but not yet Established (${elapsed}s elapsed)"
            sleep "$POLL_INTERVAL"
            elapsed=$((elapsed + POLL_INTERVAL))
            return 0
        fi
        warn "ArgoCD instance not yet created (${elapsed}s elapsed)"
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    error "ArgoCD instance was not created within ${ARGOCD_TIMEOUT}s."
    error "Check operator logs: oc logs -n $OPERATOR_NAMESPACE -l app=openshift-gitops-operator"
    exit 1
}

# ─── Main ──────────────────────────────────────────────────────────────────────

main() {
    # Handle --help flag
    for arg in "$@"; do
        case "$arg" in
            --help|-h) usage ;;
        esac
    done

    echo ""
    echo "========================================"
    info "OpenShift GitOps Operator Installer"
    echo "========================================"
    echo ""

    # Prerequisites
    check_oc_cli
    check_oc_login
    check_cluster_admin
    check_marketplace

    echo ""
    info "Starting GitOps operator installation..."
    echo ""

    # Installation
    create_namespace
    apply_operator_group
    apply_subscription
    wait_for_csv
    wait_for_pods "$GITOPS_NAMESPACE"
    wait_for_pods "$OPERATOR_NAMESPACE"
    wait_for_argocd

    echo ""
    echo "========================================"
    info "GitOps operator installed successfully!"
    echo "========================================"
    echo ""

    # Post-install info — fetch actual values
    info "Retrieving Argo CD admin credentials..."
    
    # Fetch the admin password using jq (handles dotted keys correctly)
    local admin_password=""
    if command -v jq &>/dev/null; then
        admin_password=$(oc get secret openshift-gitops-cluster -n "$GITOPS_NAMESPACE" -o json | jq -r '.data["admin.password"]' | base64 -d 2>/dev/null || echo "")
    fi
    
    # Fetch the ArgoCD route — check TLS termination to determine scheme
    local route_url=""
    local route_host=""
    local tls_termination=""
    route_host=$(oc get route openshift-gitops-server -n "$GITOPS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    tls_termination=$(oc get route openshift-gitops-server -n "$GITOPS_NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "none")
    
    if [ -n "$route_host" ]; then
        # Use https if TLS termination is configured, otherwise http
        if [ "$tls_termination" != "none" ] && [ "$tls_termination" != "" ]; then
            route_url="https://$route_host"
        else
            route_url="http://$route_host"
        fi
    fi
    
    if [ -n "$route_url" ]; then
        info "Argo CD UI is available at: $route_url"
        echo ""
    else
        info "Could not determine Argo CD route URL."
        info "Try manually:"
        echo "  oc get route openshift-gitops-server -n $GITOPS_NAMESPACE"
        echo ""
    fi
    
    if [ -n "$admin_password" ]; then
        info "Argo CD admin password:"
        echo "  $admin_password"
        echo ""
    else
        info "Could not retrieve admin password automatically."
        info "Try manually:"
        echo "  oc get secret openshift-gitops-cluster -n $GITOPS_NAMESPACE -o json | jq -r '.data[\"admin.password\"]' | base64 -d"
        echo ""
    fi
    
    # Show the complete login command with actual values
    if [ -n "$route_url" ] && [ -n "$admin_password" ]; then
        info "Log in to Argo CD CLI with:"
        echo "  argocd login $route_url --username admin --password '$admin_password'"
        echo ""
    elif [ -n "$route_url" ]; then
        info "Log in to Argo CD CLI with:"
        echo "  argocd login $route_url --username admin --password <PASSWORD>"
        echo ""
    fi
}

main "$@"
