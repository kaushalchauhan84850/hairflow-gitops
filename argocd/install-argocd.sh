#!/usr/bin/env bash

set -Eeuo pipefail

NAMESPACE="argocd"
CONTROLLER_NODE="controller"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
TIMEOUT="300s"
RESOURCE_TIMEOUT_SECONDS=180

ARGOCD_DEPLOYMENTS=(
  "argocd-server"
  "argocd-repo-server"
  "argocd-dex-server"
  "argocd-notifications-controller"
  "argocd-applicationset-controller"
  "argocd-redis"
)

ARGOCD_STATEFULSET="argocd-application-controller"

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

header() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

success() {
  echo -e "${GREEN}SUCCESS:${NC} $1"
}

warning() {
  echo -e "${YELLOW}WARNING:${NC} $1"
}

error() {
  echo -e "${RED}ERROR:${NC} $1"
}

info() {
  echo -e "${BLUE}INFO:${NC} $1"
}

diagnostics() {
  local exit_code=$?

  echo
  echo "============================================================"
  echo "INSTALLATION FAILED - DIAGNOSTICS"
  echo "============================================================"

  if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then

    echo
    echo "Argo CD Pods:"
    kubectl get pods -n "${NAMESPACE}" -o wide 2>/dev/null || true

    echo
    echo "Argo CD Deployments:"
    kubectl get deployments -n "${NAMESPACE}" 2>/dev/null || true

    echo
    echo "Argo CD StatefulSets:"
    kubectl get statefulsets -n "${NAMESPACE}" 2>/dev/null || true

    echo
    echo "Recent Argo CD Events:"
    kubectl get events \
      -n "${NAMESPACE}" \
      --sort-by='.lastTimestamp' \
      2>/dev/null | tail -40 || true

    echo
    echo "Non-Running Pods:"
    kubectl get pods \
      -n "${NAMESPACE}" \
      --no-headers 2>/dev/null \
      | awk '$3 != "Running" && $3 != "Completed" {print}' || true

  fi

  exit "${exit_code}"
}

trap diagnostics ERR

wait_for_resource() {
  local resource_type="$1"
  local resource_name="$2"
  local namespace="$3"
  local elapsed=0

  while ! kubectl get "${resource_type}" "${resource_name}" \
    -n "${namespace}" >/dev/null 2>&1
  do

    if [[ "${elapsed}" -ge "${RESOURCE_TIMEOUT_SECONDS}" ]]; then
      error "Timed out waiting for ${resource_type}/${resource_name}"
      return 1
    fi

    sleep 2
    elapsed=$((elapsed + 2))

  done
}

header "Checking Required Commands"

if ! command -v kubectl >/dev/null 2>&1; then
  error "kubectl is not installed or not in PATH."
  exit 1
fi

success "kubectl found"

if ! command -v base64 >/dev/null 2>&1; then
  warning "base64 command not found."
else
  success "base64 found"
fi

header "Checking Kubernetes Cluster Connection"

kubectl cluster-info >/dev/null

success "Kubernetes cluster connection successful"

header "Checking Controller Node"

if ! kubectl get node "${CONTROLLER_NODE}" >/dev/null 2>&1; then

  error "Controller node '${CONTROLLER_NODE}' does not exist."

  echo
  echo "Available nodes:"

  kubectl get nodes

  exit 1
fi

success "Controller node exists: ${CONTROLLER_NODE}"

header "Checking Controller Hostname Label"

NODE_HOSTNAME=$(
  kubectl get node "${CONTROLLER_NODE}" \
    -o jsonpath='{.metadata.labels.kubernetes\.io/hostname}'
)

if [[ -z "${NODE_HOSTNAME}" ]]; then

  error "Node does not have kubernetes.io/hostname label."

  kubectl get node \
    "${CONTROLLER_NODE}" \
    --show-labels

  exit 1
fi

if [[ "${NODE_HOSTNAME}" != "${CONTROLLER_NODE}" ]]; then

  error "Controller hostname label mismatch."

  echo
  echo "Expected: ${CONTROLLER_NODE}"
  echo "Actual:   ${NODE_HOSTNAME}"

  exit 1
fi

success "Controller hostname label verified"

header "Checking Controller Node Taints"

kubectl get node "${CONTROLLER_NODE}" \
  -o jsonpath='{range .spec.taints[*]}{.key}={.value}:{.effect}{"\n"}{end}' \
  2>/dev/null || true

header "Creating Argo CD Namespace"

kubectl create namespace "${NAMESPACE}" \
  --dry-run=client \
  -o yaml | kubectl apply -f -

success "Namespace ready: ${NAMESPACE}"

header "Installing Argo CD"

kubectl apply \
  --server-side \
  --force-conflicts \
  -n "${NAMESPACE}" \
  -f "${ARGOCD_MANIFEST}"

success "Argo CD manifests applied"

header "Waiting for Argo CD Deployments"

for deployment in "${ARGOCD_DEPLOYMENTS[@]}"; do

  info "Waiting for deployment/${deployment}"

  wait_for_resource \
    "deployment" \
    "${deployment}" \
    "${NAMESPACE}"

done

success "All Argo CD deployments created"

header "Waiting for Application Controller"

wait_for_resource \
  "statefulset" \
  "${ARGOCD_STATEFULSET}" \
  "${NAMESPACE}"

success "Application controller created"

header "Configuring Controller Scheduling"

PATCH=$(cat <<EOF
{
  "spec": {
    "template": {
      "spec": {
        "nodeSelector": {
          "kubernetes.io/hostname": "${CONTROLLER_NODE}"
        },
        "tolerations": [
          {
            "key": "node-role.kubernetes.io/control-plane",
            "operator": "Exists",
            "effect": "NoSchedule"
          }
        ]
      }
    }
  }
}
EOF
)

header "Scheduling Argo CD Deployments on Controller"

for deployment in "${ARGOCD_DEPLOYMENTS[@]}"; do

  info "Patching deployment/${deployment}"

  kubectl patch deployment \
    "${deployment}" \
    -n "${NAMESPACE}" \
    --type=merge \
    -p "${PATCH}"

done

success "Deployments patched"

header "Scheduling Application Controller on Controller"

kubectl patch statefulset \
  "${ARGOCD_STATEFULSET}" \
  -n "${NAMESPACE}" \
  --type=merge \
  -p "${PATCH}"

success "Application controller patched"

header "Waiting for Argo CD Deployments"

for deployment in "${ARGOCD_DEPLOYMENTS[@]}"; do

  info "Waiting for deployment/${deployment}"

  kubectl rollout status \
    deployment/"${deployment}" \
    -n "${NAMESPACE}" \
    --timeout="${TIMEOUT}"

done

success "All Argo CD deployments are ready"

header "Waiting for Application Controller"

kubectl rollout status \
  statefulset/"${ARGOCD_STATEFULSET}" \
  -n "${NAMESPACE}" \
  --timeout="${TIMEOUT}"

success "Application controller is ready"

header "Waiting for Old Pods to Terminate"

ELAPSED=0

while true; do

  TERMINATING_PODS=$(
    kubectl get pods \
      -n "${NAMESPACE}" \
      --no-headers 2>/dev/null \
      | awk '$3 == "Terminating" {print $1}'
  )

  if [[ -z "${TERMINATING_PODS}" ]]; then
    success "No terminating Argo CD pods remaining"
    break
  fi

  if [[ "${ELAPSED}" -ge "${RESOURCE_TIMEOUT_SECONDS}" ]]; then
    warning "Some old pods are still terminating:"
    echo "${TERMINATING_PODS}"
    break
  fi

  info "Waiting for old terminating pods to disappear..."

  sleep 2

  ELAPSED=$((ELAPSED + 2))

done

header "Argo CD Pod Status"

kubectl get pods \
  -n "${NAMESPACE}" \
  -o wide

header "Verifying Running Pod Placement"

BAD_PODS=0

while read -r POD NODE PHASE; do

  [[ -z "${POD}" ]] && continue

  if [[ "${PHASE}" != "Running" ]]; then
    continue
  fi

  if [[ "${NODE}" != "${CONTROLLER_NODE}" ]]; then

    warning \
      "Running pod ${POD} is on ${NODE}, expected ${CONTROLLER_NODE}"

    BAD_PODS=1
  fi

done < <(
  kubectl get pods \
    -n "${NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{" "}{.status.phase}{"\n"}{end}'
)

if [[ "${BAD_PODS}" -ne 0 ]]; then

  error "Some running Argo CD pods are not running on the controller."

  kubectl get pods \
    -n "${NAMESPACE}" \
    -o wide

  exit 1
fi

success "All running Argo CD pods are on controller"

header "Verifying Running Pod Readiness"

NOT_READY=""

while read -r POD READY; do

  [[ -z "${POD}" ]] && continue

  if [[ "${READY}" != "true" ]]; then
    NOT_READY="${NOT_READY}${POD}=${READY}"$'\n'
  fi

done < <(
  kubectl get pods \
    -n "${NAMESPACE}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.containerStatuses[*]}{.ready}{" "}{end}{"\n"}{end}' \
  | awk '
      {
        ready="true"
        for (i=2; i<=NF; i++) {
          if ($i != "true") {
            ready="false"
          }
        }
        print $1, ready
      }
    '
)

if [[ -n "${NOT_READY}" ]]; then

  error "Some running Argo CD pods are not ready."

  printf "%s" "${NOT_READY}"

  exit 1
fi

success "All running Argo CD pods are ready"

header "Argo CD Installation Completed Successfully"

kubectl get pods \
  -n "${NAMESPACE}" \
  -o wide

echo
echo "============================================================"
echo "Argo CD UI Access"
echo "============================================================"

echo
echo "STEP 1: On the Kubernetes controller, start Argo CD port-forward:"
echo

echo "kubectl port-forward svc/argocd-server -n argocd 8443:443"

echo
echo "Keep this terminal OPEN."
echo "Do not stop the port-forward process."

echo
echo "============================================================"
echo "STEP 2: On your LOCAL machine, create an SSH tunnel:"
echo "============================================================"

echo
echo "ssh -L 8443:127.0.0.1:8443 \\"
echo "  -i ~/.ssh/id_ed25519 \\"
echo "  azureuser@20.39.61.124"

echo
echo "Keep this SSH connection OPEN."

echo
echo "============================================================"
echo "STEP 3: Open Argo CD in your LOCAL browser:"
echo "============================================================"

echo
echo "https://localhost:8443"

echo
echo "============================================================"
echo "LOGIN"
echo "============================================================"

echo
echo "Username:"
echo "admin"

echo
echo "Initial password command:"
echo

echo "kubectl -n argocd get secret argocd-initial-admin-secret \\"
echo "  -o jsonpath=\"{.data.password}\" | base64 -d"

echo
echo "============================================================"
echo "ARGOCD DONE "
echo "============================================================"
