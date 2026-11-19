# Envoy AI Gateway on kind `ai-gw`: auth, quotas, fallback and metrics

## Run it (Git Bash)

```bash
cd ai-gw-bundle
export OPENROUTER_API_KEY=sk-or-xxxxxxxx
chmod +x setup.sh test.sh
USE_FAKE_VLLM=1 ./setup.sh     # use 0 if a real "vllm" Service already listens on :8000 in default
./test.sh
```

Requirements: Kubernetes **1.32 or newer** on the `ai-gw` cluster (`setup.sh` checks this), plus `kubectl`, `helm` and `kind`.

## Where each policy attaches

| Feature | Resource | File | Attached to |
|---|---|---|---|
| Client auth | `SecurityPolicy` (apiKeyAuth, `x-api-key`) | 10-gateway/gateway.yaml | Gateway `ai-gw` |
| Tenant identity | `forwardClientIDHeader: x-tenant-id` | 10-gateway/gateway.yaml | Gateway `ai-gw` |
| Metrics | `EnvoyProxy` (Prometheus) + Prometheus | 10-gateway, 40-monitoring | Gateway infra |
| Upstream auth | `BackendSecurityPolicy` (APIKey) | 20-backends/openrouter-fallback.yaml | AIServiceBackend `openrouter` |
| Token accounting | `llmRequestCosts` (TotalToken) | 30-routing | AIGatewayRoute `ai-gw-route` |
| Fallback | `priority` 0/1 + `retry.numAttemptsPerPriority` | 30-routing | HTTPRoute `ai-gw-route` |
| Quota | `rateLimit.type: Global` (Redis) | 30-routing | HTTPRoute `ai-gw-route` |

## Client call

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "x-api-key: key-tenant-a-123" -H "Content-Type: application/json" \
  -d '{"model":"llama-3-8b","messages":[{"role":"user","content":"hi"}]}'
```

## Debug

```bash
kubectl get aigatewayroute ai-gw-route -o yaml | grep -A20 status
kubectl get backendtrafficpolicy,securitypolicy -o wide
kubectl describe backendtrafficpolicy ai-gw-route-policy | grep -A10 Conditions
kubectl logs -n envoy-ai-gateway-system deploy/ai-gateway-controller --tail=50
kubectl logs -n envoy-gateway-system deploy/envoy-gateway --tail=50
kubectl logs -n envoy-gateway-system -l app.kubernetes.io/component=ratelimit --tail=50
```

## Clean up

```bash
kubectl delete -f 30-routing -f 20-backends -f 10-gateway -f 40-monitoring
helm uninstall aieg aieg-crd -n envoy-ai-gateway-system
helm uninstall eg -n envoy-gateway-system
kubectl delete -f 00-install/redis.yaml
```
