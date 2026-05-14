#!/usr/bin/env bash
#
# check-gitops-operator.sh
# Checks the status of the OpenShift GitOps (Argo CD) operator installation.
# Reports whether all required components are present (installed) or absent
# (fully uninstalled), or identifies any inconsistency.
#
# Usage: ./check-gitops-operator.sh [--help]
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

# Counters
CHECKS_TOTAL=0
CHECKS_PASS=0
CHECKS_FAIL=0
CHECKS_SKIP=0

# ─── Helpers ────────────────────────────────────────────────────────────────────

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
check()   { echo -e "${GREEN}[CHECK]${NC} $*"; }

pass()    {
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    CHECKS_PASS=$((CHECKS_PASS + 1))
    echo -e "  ${GREEN}[PASS]${NC} $*"
}

fail()    {
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    CHECKS_FAIL=$((CHECKS_FAIL + 1))
    echo -e "  ${RED}[FAIL]${NC} $*"
}

skip()    {
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
    CHECKS_SKIP=$((CHECKS_SKIP + 1))
    echo -e "  ${BLUE}[SKIP]${NC} $*"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Checks the status of the OpenShift GitOps (Argo CD) operator installation.
Reports whether all required components are present (installed), absent
(fully uninstalled), or if there are any inconsistencies.

Options:
  --help, -h    Show this help message and exit.

Prerequisites:
  - oc CLI installed and available in PATH
  - Logged in to an OpenShift cluster (oc whoami should succeed)

The script checks for:
  1. Namespaces (openshift-gitops-operator, openshift-gitops)
  2. Operator Subscription
  3. ClusterServiceVersion (CSV)
  4. CRDs (argocds, gitopsservices, appprojects, applications)
  5. Operator pods status
  6. ArgoCD instance(s)
  7. ArgoCD pods status
  8. OperatorGroup

Exit codes:
  0  - Consistent state (fully installed or fully uninstalled)
  1  - Inconsistent state (partial install/uninstall)
  2  - Prerequisite check failed (oc CLI not available, not logged in)

EOF
    exit 0
}

# ─── Prerequisite Checks ───────────────────────────────────────────────────────

check_prerequisites() {
    # Check oc CLI
    if ! command -v oc &>/dev/null; then
        error "oc CLI is not installed or not in PATH."
        exit 2
    fi

    # Check cluster login
    if ! oc whoami &>/dev/null; then
        error "Not logged in to an OpenShift cluster. Run 'oc login' first."
        exit 2
    fi
}

# ─── Component Checks ──────────────────────────────────────────────────────────

check_namespaces() {
    check "Checking namespaces..."
    
    local op_exists=false
    local gp_exists=false
    
    if oc get namespace "$OPERATOR_NAMESPACE" &>/dev/null; then
        op_exists=true
        pass "Namespace '$OPERATOR_NAMESPACE' exists"
    else
        fail "Namespace '$OPERATOR_NAMESPACE' missing"
    fi
    
    if oc get namespace "$GITOPS_NAMESPACE" &>/dev/null; then
        gp_exists=true
        pass "Namespace '$GITOPS_NAMESPACE' exists"
    else
        fail "Namespace '$GITOPS_NAMESPACE' missing"
    fi
    
    # Both must exist or both must be absent for consistent state
    if [ "$op_exists" = true ] && [ "$gp_exists" = true ]; then
        info "Both namespaces present."
    elif [ "$op_exists" = false ] && [ "$gp_exists" = false ]; then
        info "No namespaces found."
    else
        warn "Inconsistent namespace state - one exists, the other doesn't."
    fi
}

check_subscription() {
    check "Checking Operator Subscription..."
    
    local subs
    subs=$(oc get subscription -n "$OPERATOR_NAMESPACE" -o name 2>/dev/null || echo "")
    
    if [ -n "$subs" ]; then
        pass "Subscription found: $subs"
    else
        fail "No subscription found in '$OPERATOR_NAMESPACE'"
    fi
}

check_csv() {
    check "Checking ClusterServiceVersion (CSV)..."
    
    local csvs
    csvs=$(oc get csv -n "$OPERATOR_NAMESPACE" -o name 2>/dev/null || echo "")
    
    if [ -n "$csvs" ]; then
        for csv in $csvs; do
            local name
            name=$(echo "$csv" | sed 's|clusterserviceversion.operators.coreos.com/||')
            local phase
            phase=$(oc get csv "$name" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
            if [ "$phase" = "Succeeded" ]; then
                pass "CSV '$name' phase: $phase"
            else
                fail "CSV '$name' phase: $phase (expected: Succeeded)"
            fi
        done
    else
        fail "No CSV found in '$OPERATOR_NAMESPACE'"
    fi
}

check_crds() {
    check "Checking CRDs..."
    
    local crd_names=("argoproj.io_argocds" "pipelines.openshift.io_gitopsservices" "argoproj.io_appprojects" "argoproj.io_applications")
    
    for crd in "${crd_names[@]}"; do
        if oc get crd "$crd" &>/dev/null; then
            pass "CRD '$crd' exists"
        else
            fail "CRD '$crd' missing"
        fi
    done
}

check_operator_pods() {
    check "Checking operator pods in '$OPERATOR_NAMESPACE'..."
    
    local pods
    pods=$(oc get pods -n "$OPERATOR_NAMESPACE" --no-headers 2>/dev/null || echo "")
    
    if [ -z "$pods" ]; then
        fail "No pods found in '$OPERATOR_NAMESPACE'"
        return
    fi
    
    local total=0
    local running=0
    local issues=""
    
    while IFS= read -r line; do
        total=$((total + 1))
        local name status
        name=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $3}')
        if [ "$status" = "Running" ]; then
            running=$((running + 1))
        else
            issues="$issues $name=$status"
        fi
    done <<< "$pods"
    
    if [ "$total" -eq "$running" ]; then
        pass "$total operator pod(s) Running"
    else
        fail "$running/$total operator pods Running (issues:$issues)"
    fi
}

check_argocd_instance() {
    check "Checking ArgoCD instances..."
    
    local instances
    instances=$(oc get argocd -n "$GITOPS_NAMESPACE" -o name 2>/dev/null || echo "")
    
    if [ -n "$instances" ]; then
        for instance in $instances; do
            local name
            name=$(echo "$instance" | sed 's|argocd/||')
            local conditions
            conditions=$(oc get argocd "$name" -n "$GITOPS_NAMESPACE" -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || echo "")
            if echo "$conditions" | grep -q "Established"; then
                pass "ArgoCD instance '$name' is Established"
            else
                fail "ArgoCD instance '$name' is not Established (conditions: $conditions)"
            fi
        done
    else
        fail "No ArgoCD instance found in '$GITOPS_NAMESPACE'"
    fi
}

check_argocd_pods() {
    check "Checking ArgoCD pods in '$GITOPS_NAMESPACE'..."
    
    local pods
    pods=$(oc get pods -n "$GITOPS_NAMESPACE" --no-headers 2>/dev/null || echo "")
    
    if [ -z "$pods" ]; then
        fail "No pods found in '$GITOPS_NAMESPACE'"
        return
    fi
    
    local total=0
    local running=0
    local issues=""
    
    while IFS= read -r line; do
        total=$((total + 1))
        local name status
        name=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $3}')
        if [ "$status" = "Running" ]; then
            running=$((running + 1))
        else
            issues="$issues $name=$status"
        fi
    done <<< "$pods"
    
    if [ "$total" -eq "$running" ]; then
        pass "$total ArgoCD pod(s) Running"
    else
        fail "$running/$total ArgoCD pods Running (issues:$issues)"
    fi
}

check_operator_group() {
    check "Checking OperatorGroup..."
    
    local ogs
    ogs=$(oc get operatorgroup -n "$OPERATOR_NAMESPACE" -o name 2>/dev/null || echo "")
    
    if [ -n "$ogs" ]; then
        for og in $ogs; do
            local name
            name=$(echo "$og" | sed 's|operatorgroup.operators.coreos.com/||')
            pass "OperatorGroup found: $name"
        done
    else
        fail "No OperatorGroup found in '$OPERATOR_NAMESPACE'"
    fi
}

# ─── State Analysis ────────────────────────────────────────────────────────────

analyze_state() {
    echo ""
    echo "========================================"
    check "Analysis Results"
    echo "========================================"
    echo ""
    info "Total checks: $CHECKS_TOTAL"
    info "Passed: $CHECKS_PASS"
    info "Failed: $CHECKS_FAIL"
    info "Skipped: $CHECKS_SKIP"
    echo ""
    
    if [ "$CHECKS_FAIL" -eq 0 ]; then
        echo "========================================"
        info "State: FULLY INSTALLED"
        echo "========================================"
        info "All components are present and healthy."
        return 0
    fi
    
    # Check if everything is missing (fully uninstalled)
    if [ "$CHECKS_PASS" -eq 0 ] && [ "$CHECKS_FAIL" -eq "$CHECKS_TOTAL" ]; then
        echo "========================================"
        info "State: FULLY UNINSTALLED"
        echo "========================================"
        info "No GitOps operator components found on the cluster."
        return 0
    fi
    
    # Partial state
    echo "========================================"
    error "State: INCONSISTENT (partial install/uninstall)"
    echo "========================================"
    echo ""
    warn "Some components are present while others are missing."
    warn "This may indicate an incomplete installation or uninstallation."
    echo ""
    info "To install, run: ./scripts/install-gitops-operator.sh"
    info "To uninstall, run: ./scripts/uninstall-gitops-operator.sh"
    return 1
}

# ─── Main ──────────────────────────────────────────────────────────────────────

main() {
    # Handle flags
    for arg in "$@"; do
        case "$arg" in
            --help|-h) usage ;;
        esac
    done
    
    echo ""
    echo "========================================"
    info "OpenShift GitOps Operator Status Check"
    echo "========================================"
    echo ""
    
    # Prerequisites
    check_prerequisites
    info "Logged in as: $(oc whoami)"
    echo ""
    
      # Run all checks
    check_namespaces
    echo ""
    check_subscription
    echo ""
    check_csv
    echo ""
    check_crds
    echo ""
    check_operator_pods
    echo ""
    check_argocd_instance
    echo ""
    check_argocd_pods
    echo ""
    check_operator_group
    echo ""
    
    # Analyze and report
    analyze_state
}

main "$@"
