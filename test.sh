#!/usr/bin/env bash
# End-to-end checks: auth, routing, fallback, quota, metrics.  Run from Git Bash.
set -uo pipefail
kubectl config use-context kind-ai-gw >/dev/null

SVC=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-namespace=default,gateway.envoyproxy.io/owning-gateway-name=ai-gw \
  -o jsonpath='{.items[0].metadata.name}')
echo "Envoy service: $SVC"

kubectl port-forward -n envoy-gateway-system "svc/$SVC" 8080:80 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
sleep 3

URL=http://localhost:8080/v1/chat/completions
BODY='{"model":"llama-3-8b","messages":[{"role":"user","content":"Say hi in 5 words"}]}'
call() { curl -s -o /tmp/aigw.out -w "%{http_code}" "$URL" -H "Content-Type: application/json" "$@" -d "$BODY"; }

echo; echo "1) No API key            -> expect 401:  $(call)"
echo    "2) Wrong API key         -> expect 401:  $(call -H 'x-api-key: nope')"
echo    "3) tenant-a, primary up  -> expect 200:  $(call -H 'x-api-key: key-tenant-a-123')"
head -c 300 /tmp/aigw.out; echo

echo; echo "4) Fallback: scale primary (fake vLLM) to 0, request should be served by OpenRouter"
kubectl scale deploy/vllm --replicas=0 >/dev/null 2>&1 && sleep 8
echo    "   tenant-a, primary down -> expect 200: $(call -H 'x-api-key: key-tenant-a-123')"
grep -o '"model":"[^"]*"' /tmp/aigw.out | head -1   # should show meta-llama/llama-3.1-8b-instruct
kubectl scale deploy/vllm --replicas=1 >/dev/null 2>&1

echo; echo "5) Quota: tenant-b burst (set limit to 50 in 30-routing to see 429 quickly)"
for i in $(seq 1 10); do printf '%s ' "$(call -H 'x-api-key: key-tenant-b-456')"; done; echo

echo; echo "6) Metrics from Envoy (AI token metrics)"
POD=$(kubectl get pod -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=ai-gw -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n envoy-gateway-system "pod/$POD" 19001:19001 >/dev/null 2>&1 &
PF2=$!; sleep 3
curl -s localhost:19001/stats/prometheus | grep -E 'ratelimit|upstream_rq_retry' | head -8
kill $PF2 2>/dev/null

echo; echo "Prometheus UI:  kubectl port-forward -n monitoring svc/prometheus 9090:9090  ->  http://localhost:9090"
echo "Try queries:    sum by (gen_ai_token_type) (gen_ai_client_token_usage_sum)"
