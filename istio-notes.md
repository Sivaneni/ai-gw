==================== AIGatewayRoute ====================
NAMESPACE   NAME          STATUS
default     ai-gw-route   Accepted
default     llm-route     Accepted

==================== AIServiceBackend ====================
NAMESPACE   NAME           STATUS
default     external-llm   Accepted
default     local-sim      Accepted
default     openrouter     Accepted
default     vllm           Accepted

==================== BackendSecurityPolicy ====================
NAMESPACE   NAME                  STATUS
default     external-llm-apikey   Accepted
default     openrouter-apikey     Accepted

==================== Backend ====================
NAMESPACE   NAME           STATUS     AGE
default     external-llm   Accepted   3d23h
default     local-sim      Accepted   3d23h
default     openrouter     Accepted   3d23h
default     vllm           Accepted   3d23h

==================== BackendTrafficPolicy ====================
NAMESPACE   NAME                 AGE
default     ai-gw-route-policy   3d23h

==================== ClientTrafficPolicy ====================
NAMESPACE   NAME           AGE
default     ai-gw-buffer   3d23h

==================== EnvoyProxy ====================
NAMESPACE   NAME           AGE
default     ai-gw          3d23h
default     proxy-config   4d

==================== HTTPRouteFilter ====================
NAMESPACE   NAME                                         AGE
default     ai-eg-host-rewrite-ai-gw-route               3d23h
default     ai-eg-host-rewrite-llm-route                 3d23h
default     ai-eg-route-not-found-response-ai-gw-route   3d23h
default     ai-eg-route-not-found-response-llm-route     3d23h

==================== SecurityPolicy ====================
NAMESPACE   NAME                AGE
default     ai-gw-apikey-auth   3d23h

==================== BackendTLSPolicy ====================
NAMESPACE   NAME               AGE
default     external-llm-tls   3d23h
default     openrouter-tls     3d23h

==================== GatewayClass ====================
NAME         CONTROLLER                                      ACCEPTED   AGE
ai-gateway   gateway.envoyproxy.io/gatewayclass-controller   True       4d
ai-gw        gateway.envoyproxy.io/gatewayclass-controller   True       3d23h

==================== Gateway ====================
NAMESPACE   NAME         CLASS        ADDRESS       PROGRAMMED   AGE
default     ai-gateway   ai-gateway   10.96.96.14   True         4d
default     ai-gw        ai-gw        10.96.55.47   True         3d23h

==================== HTTPRoute ====================
NAMESPACE   NAME          HOSTNAMES   AGE
default     ai-gw-route               3d23h
default     llm-route                 3d23h


| Resource | What it is | Why it's used in your setup |
|---|---|---|
| **GatewayClass** | Says which controller manages Gateways of this class, here `gateway.envoyproxy.io/gatewayclass-controller`. | Without it, Envoy Gateway wouldn't pick up and run your `ai-gw` Gateway. |
| **Gateway** | The entry point: a listener on HTTP port 80 that becomes an Envoy proxy Deployment and Service. | It's where every client request enters, and the object the auth, buffer and route rules attach to. |
| **EnvoyProxy** | Settings for the Envoy pods that a Gateway creates (Service type, resources, telemetry). | You used it to make the Service `ClusterIP` (kind has no LoadBalancer), keep Prometheus metrics on, and clear the large default CPU/memory requests. |
| **ClientTrafficPolicy** | Rules for the client-to-Envoy connection (buffer limits, timeouts, keepalives). | It raises `bufferLimit` to 50Mi so large LLM prompts and responses aren't rejected. |
| **SecurityPolicy** | Authentication and authorization for incoming requests (API key, JWT, OIDC, ext_authz). | It checks `x-api-key` against the `client-api-keys` Secret, returns `401` for bad keys, and sets `x-tenant-id` so quotas are per tenant. |
| **AIGatewayRoute** | An AI-specific route that picks backends by model name and records token usage. | It sends `llama-3-8b` to vLLM (priority 0) or OpenRouter (priority 1) and stores token counts for the quota. |
| **HTTPRoute** | The standard Gateway API routing object Envoy Gateway actually runs. | You didn't write it: the AI Gateway controller generates it from `AIGatewayRoute`, and your BackendTrafficPolicy targets it. |
| **HTTPRouteFilter** | An Envoy Gateway extension for request changes, like URL or host rewrites, or direct responses. | You didn't apply one. As far as I know, the AI Gateway controller creates one so the upstream `Host` header matches each backend, for example `openrouter.ai`. |
| **AIServiceBackend** | Describes an LLM provider: its API schema (OpenAI), path prefix and the Backend it uses. | It tells the gateway how to talk to each provider: `/v1` for vLLM, `/api/v1` for OpenRouter, with request translation if needed. |
| **Backend** | An Envoy Gateway object for an upstream address (FQDN or IP plus port). | It points to `vllm.default:8000` inside the cluster and to `openrouter.ai:443` outside it. |
| **BackendTLSPolicy** | How Envoy checks the upstream's TLS certificate (CA and hostname). | It makes the call to OpenRouter use HTTPS with the system CA and `openrouter.ai` as the hostname. |
| **BackendSecurityPolicy** | An AI Gateway object that adds provider credentials to outgoing requests. | It adds the OpenRouter API key from a Secret, so clients never see or send the provider key. |
| **BackendTrafficPolicy** | Rules for Envoy-to-upstream traffic (retries, rate limits, timeouts, circuit breaking). | It handles fallback (retry on 5xx or connection failure, then try the next priority) and enforces the per-tenant token quota through Redis. |

To check which HTTPRouteFilter exists in your cluster and who created it:

```bash
kubectl get httproutefilter -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].kind
```