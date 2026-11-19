Here's what `./switch-auth.sh jwt` and the JWT part of `test.sh` do, as commands you run one at a time.

### 0. Set your values

```bash
kubectl config use-context kind-ai-gw

export AUTH0_DOMAIN=dev-xxxx.us.auth0.com      # no https://, no trailing /
export AUTH0_AUDIENCE=https://ai-gw.local      # your Auth0 API Identifier
export A_CLIENT_ID=...    A_CLIENT_SECRET=...  # M2M app with tenant=tenant-a
export B_CLIENT_ID=...    B_CLIENT_SECRET=...  # M2M app with tenant=tenant-b

# Envoy must be able to fetch this: expect {"keys":[...]}
curl -s https://$AUTH0_DOMAIN/.well-known/jwks.json | head -c 100; echo
```

### 1. Remove the API-key auth

Only one SecurityPolicy should target the Gateway:

```bash
kubectl get securitypolicy
kubectl delete securitypolicy ai-gw-apikey-auth --ignore-not-found
kubectl delete securitypolicy ai-gw-auth --ignore-not-found   # in case you applied auth-apikey.yaml
```

### 2. Strip spoofed tenant headers (ClientTrafficPolicy)

```bash
kubectl apply -f - <<'EOF'
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: ai-gw-buffer
  namespace: default
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ai-gw
  connection:
    bufferLimit: 50Mi
  headers:
    earlyRequestHeaders:
      remove:
        - x-tenant-id
        - x-user-tier
EOF
```

### 3. Apply the Auth0 JWT SecurityPolicy

The heredoc isn't quoted this time, so `$AUTH0_DOMAIN` and `$AUTH0_AUDIENCE` are filled in:

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: ai-gw-auth
  namespace: default
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ai-gw
  jwt:
    providers:
      - name: auth0
        issuer: https://$AUTH0_DOMAIN/
        audiences:
          - $AUTH0_AUDIENCE
        remoteJWKS:
          uri: https://$AUTH0_DOMAIN/.well-known/jwks.json
        claimToHeaders:
          - header: x-tenant-id
            claim: gw_tenant
          - header: x-user-tier
            claim: gw_tier
  authorization:
    defaultAction: Deny
    rules:
      - name: require-gateway-claims
        action: Allow
        principal:
          jwt:
            provider: auth0
            claims:
              - name: gw_tier
                values: ["free", "premium"]
EOF
```

### 4. Check that it was accepted

```bash
kubectl get securitypolicy ai-gw-auth \
  -o jsonpath='{range .status.ancestors[*].conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

You should see `Accepted=True`. If it says `False`, the message explains why, usually a typo in the issuer or a field.

### 5. Get the tokens and check their claims

```bash
token() {
  curl -s "https://$AUTH0_DOMAIN/oauth/token" -H 'Content-Type: application/json' \
    -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"$1\",\"client_secret\":\"$2\",\"audience\":\"$AUTH0_AUDIENCE\"}" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}
claims() { p=$(echo "$1" | cut -d. -f2 | tr '_-' '/+'); while [ $(( ${#p} % 4 )) -ne 0 ]; do p="$p="; done; echo "$p" | base64 -d; echo; }

TA=$(token "$A_CLIENT_ID" "$A_CLIENT_SECRET")
TB=$(token "$B_CLIENT_ID" "$B_CLIENT_SECRET")
claims "$TA" | grep -o '"\(iss\|aud\|gw_[a-z]*\)":"[^"]*"'
claims "$TB" | grep -o '"gw_[a-z]*":"[^"]*"'
```

Expect `iss` = `https://<domain>/`, `aud` = your audience, and the `gw_tenant` and `gw_tier` claims. If `TA` is empty, run the `curl` without the `sed` to see Auth0's error.

### 6. Port-forward the gateway

Use a separate terminal, or run it in the background:

```bash
SVC=$(kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=ai-gw -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n envoy-gateway-system svc/$SVC 8080:80 >/dev/null 2>&1 &
sleep 3
URL=http://localhost:8080/v1/chat/completions
BODY='{"model":"llama-3-8b","messages":[{"role":"user","content":"Say hi in 5 words"}]}'
```

### 7. Test

```bash
# No token: expect 401
curl -s -o /dev/null -w "%{http_code}\n" $URL -H 'Content-Type: application/json' -d "$BODY"

# Old API key: expect 401 (API keys are off now)
curl -s -o /dev/null -w "%{http_code}\n" $URL -H 'x-api-key: key-tenant-a-123' -H 'Content-Type: application/json' -d "$BODY"

# Valid tenant-a token: expect 200 and a model answer
curl -s $URL -H "Authorization: Bearer $TA" -H 'Content-Type: application/json' -d "$BODY"; echo

# Spoof attempt: tenant-a token pretending to be tenant-b. Expect 200, but counted as tenant-a
curl -s -o /dev/null -w "%{http_code}\n" $URL -H "Authorization: Bearer $TA" -H 'x-tenant-id: tenant-b' -H 'Content-Type: application/json' -d "$BODY"

# Valid tenant-b token: expect 200
curl -s -o /dev/null -w "%{http_code}\n" $URL -H "Authorization: Bearer $TB" -H 'Content-Type: application/json' -d "$BODY"
```

### 8. Confirm the quota counts by tenant from the token

```bash
kubectl exec -n redis-system deploy/redis -- redis-cli FLUSHALL   # optional: start clean, then re-run step 7
kubectl exec -n redis-system deploy/redis -- sh -c \
  'for k in $(redis-cli --scan --pattern "*"); do echo "$k = $(redis-cli get "$k")"; done' | grep -o 'tenant-[a-z]*_[0-9]* = [0-9]*'
```

You should see separate counters for `tenant-a` and `tenant-b`, with the spoofed call counted under **tenant-a**.

### 9. Quota test (optional)

```bash
kubectl patch backendtrafficpolicy ai-gw-route-policy --type json -p '[{"op":"replace","path":"/spec/rateLimit/global/rules/0/limit/requests","value":300}]'
sleep 10
for i in 1 2 3 4 5 6; do curl -s -o /dev/null -w "%{http_code} " $URL -H "Authorization: Bearer $TB" -H 'Content-Type: application/json' -d "$BODY"; done; echo
kubectl patch backendtrafficpolicy ai-gw-route-policy --type json -p '[{"op":"replace","path":"/spec/rateLimit/global/rules/0/limit/requests","value":100000}]'
```

Expect `200`s, then `429`.

### Undo: go back to API keys

```bash
kubectl delete securitypolicy ai-gw-auth
kubectl apply -f 10-gateway/auth-apikey.yaml
```

### If you get an unexpected status

```bash
POD=$(kubectl get pod -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=ai-gw -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n envoy-gateway-system $POD -c envoy --tail=30 | grep -iE 'jwt|rbac|401|403'
```

| Result | Likely cause |
|---|---|
| `401` with a valid token | `iss` or `aud` doesn't match exactly. The issuer needs the trailing `/`, and the audience must equal the API Identifier. |
| `403` with a valid token | `gw_tier` is missing, so the Action isn't bound. Check with step 5. |
| `200` but no tenant counter in Redis | `gw_tenant` is missing from the token, or the claim name has a typo. |
