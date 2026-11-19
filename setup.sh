#!/usr/bin/env bash
# Envoy AI Gateway on kind cluster "ai-gw": auth + quotas + fallback + metrics
# Run from Git Bash inside this folder:
#   export OPENROUTER_API_KEY=sk-or-...
#   USE_FAKE_VLLM=1 ./setup.sh        # USE_FAKE_VLLM=0 if you already run a real "vllm" Service on :8000
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER=ai-gw
EG_VERSION=v1.9.2      # Envoy Gateway (minimum for Agent Router / AI Gateway v1.2.x)
AIEG_VERSION=v1.2.1    # Envoy AI Gateway
USE_FAKE_VLLM="${USE_FAKE_VLLM:-1}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---------- 0. Preflight ----------
step "Preflight"
for b in kubectl helm kind; do command -v "$b" >/dev/null || { echo "missing: $b"; exit 1; }; done
: "${OPENROUTER_API_KEY:?export OPENROUTER_API_KEY=sk-or-... first}"

kind get clusters | grep -qx "$CLUSTER" || { echo "kind cluster '$CLUSTER' not found"; exit 1; }
kubectl config use-context "kind-$CLUSTER" >/dev/null
kubectl cluster-info >/dev/null

MINOR=$(kubectl version -o json | grep -A6 '"serverVersion"' | grep '"minor"' | head -1 | tr -dc '0-9')
echo "Kubernetes server minor version: 1.$MINOR"
if [ "${MINOR:-0}" -lt 32 ]; then
  echo "ERROR: Envoy AI Gateway needs Kubernetes 1.32+. Your ai-gw cluster is 1.$MINOR."
  echo "Recreate it, e.g.:  kind delete cluster --name ai-gw && kind create cluster --name ai-gw --image kindest/node:v1.33.1"
  exit 1
fi

# ---------- 1. Redis (backend for global token quotas) ----------
step "Redis for rate limiting"
kubectl apply -f 00-install/redis.yaml
kubectl wait --timeout=2m -n redis-system deployment/redis --for=condition=Available

# ---------- 2. Envoy Gateway with AI Gateway extension + rate limit addon ----------
step "Envoy Gateway $EG_VERSION"
helm upgrade -i eg oci://docker.io/envoyproxy/gateway-helm \
  --version "$EG_VERSION" \
  --namespace envoy-gateway-system --create-namespace \
  -f 00-install/envoy-gateway-values.yaml \
  -f 00-install/envoy-gateway-ratelimit-addon.yaml
kubectl wait --timeout=3m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

# ---------- 3. Envoy AI Gateway CRDs + controller ----------
step "Envoy AI Gateway $AIEG_VERSION"
helm upgrade -i aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm \
  --version "$AIEG_VERSION" --namespace envoy-ai-gateway-system --create-namespace
helm upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm \
  --version "$AIEG_VERSION" --namespace envoy-ai-gateway-system --create-namespace
kubectl wait --timeout=3m -n envoy-ai-gateway-system deployment/ai-gateway-controller --for=condition=Available

# Envoy Gateway must reach the AI Gateway extension server; restart so it picks it up cleanly.
kubectl rollout restart -n envoy-gateway-system deployment/envoy-gateway
kubectl rollout status  -n envoy-gateway-system deployment/envoy-gateway --timeout=3m

# ---------- 4. Gateway layer: metrics + client auth ----------
step "Gateway, EnvoyProxy (metrics), SecurityPolicy (client API keys)"
kubectl apply -f 10-gateway/gateway.yaml

# ---------- 5. Backends: vLLM primary + OpenRouter fallback ----------
step "Backends"
if [ "$USE_FAKE_VLLM" = "1" ]; then
  kubectl apply -f 20-backends/fake-vllm.yaml
  kubectl wait --timeout=2m deployment/vllm --for=condition=Available
fi
kubectl create secret generic openrouter-apikey \
  --from-literal=apiKey="$OPENROUTER_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f 20-backends/vllm-primary.yaml
kubectl apply -f 20-backends/openrouter-fallback.yaml

# ---------- 6. Route: priority fallback + token accounting + quota ----------
step "AIGatewayRoute + BackendTrafficPolicy (retry/fallback + token quota)"
kubectl apply -f 30-routing/route-and-policies.yaml

# ---------- 7. Prometheus ----------
step "Prometheus (scrapes Envoy + gen_ai metrics)"
kubectl apply -f 40-monitoring/prometheus.yaml

# ---------- 8. Wait for gateway ----------
step "Waiting for Gateway to be Programmed"
kubectl wait --timeout=3m gateway/ai-gw --for=condition=Programmed
kubectl wait --timeout=3m -n envoy-gateway-system pods \
  -l gateway.envoyproxy.io/owning-gateway-name=ai-gw --for=condition=Ready

step "Status"
kubectl get gateway,aigatewayroute,aiservicebackend,backendsecuritypolicy,securitypolicy,backendtrafficpolicy
echo
echo "Done. Now run:  ./test.sh"
