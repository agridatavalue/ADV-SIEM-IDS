#!/usr/bin/env bash
# Verify a deployment on a real cluster.
#
#   ./verify.sh --context <kube-context> [--namespace ids] [--values chart/values.yaml]
#
# Everything is checked through `kubectl port-forward` rather than the ingress
# hostnames, so this works before DNS is pointed at the cluster and from a
# machine that cannot resolve the internal names. The ingress objects are
# inspected for correctness separately.
#
# It creates a test asset, policy and contract definition on each connector to
# exercise negotiation, then deletes the offers it made.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:$PATH"

CTX=""
NS="ids"
VALUES="$HERE/chart/values.yaml"
while [ $# -gt 0 ]; do
  case "$1" in
    --context)   CTX="${2:-}"; shift 2 ;;
    --namespace) NS="${2:-}"; shift 2 ;;
    --values)    VALUES="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$CTX" ] || { echo "ERROR: --context is required" >&2; exit 1; }

K="kubectl --context $CTX -n $NS"
FAILED=0
check() {
  if [ "$1" = "0" ]; then echo "  PASS  $2${3:+   [$3]}"
  else echo "  FAIL  $2${3:+   [$3]}"; FAILED=$((FAILED+1)); fi
}

KEY=$(grep -E '^\s+edcApiAuthKey:' "$VALUES" | head -1 | awk '{print $2}' | tr -d "'\"")
# No fallback on purpose. Defaulting to sovity's public demo key would make the
# authentication checks below pass against a connector that is wide open, which is
# the opposite of what this script is for.
[ -n "$KEY" ] || { echo "ERROR: could not read edcApiAuthKey from $VALUES" >&2; exit 1; }
case "$KEY" in CHANGEME*) echo "ERROR: $VALUES still holds a CHANGEME api key" >&2; exit 1 ;; esac

echo "context: $CTX   namespace: $NS"

echo
echo "=============== pods ==============="
$K get pods --no-headers 2>/dev/null | awk '{print "  "$1"  "$2"  "$3}'
NOTREADY=$($K get pods --no-headers --field-selector=status.phase!=Succeeded 2>/dev/null \
  | awk '{split($2,a,"/"); if (a[1]!=a[2]) print $1}' | wc -l)
check "$([ "$NOTREADY" -eq 0 ] && echo 0 || echo 1)" "every long-running pod is Ready" "$NOTREADY not ready"

echo
echo "=============== helm release ==============="
ST=$(helm --kube-context "$CTX" -n "$NS" status sovity-ui-connector -o json 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['info']['status'])" 2>/dev/null)
check "$([ "$ST" = "deployed" ] && echo 0 || echo 1)" "release status" "$ST"

echo
echo "=============== ingress wiring ==============="
$K get ingress 2>/dev/null | sed 's/^/  /'
python3 - "$CTX" "$NS" <<'PY'
import json, subprocess, sys
ctx, ns = sys.argv[1], sys.argv[2]
def kget(kind):
    out = subprocess.run(["kubectl", "--context", ctx, "-n", ns, "get", kind, "-o", "json"],
                         capture_output=True, text=True)
    return json.loads(out.stdout)["items"] if out.returncode == 0 else []
svc = {s["metadata"]["name"]: {p["port"] for p in s["spec"]["ports"]} for s in kget("svc")}
bad = 0
for ing in kget("ingress"):
    n = ing["metadata"]["name"]
    sp = ing["spec"]
    if not sp.get("ingressClassName"):
        print(f"  FAIL  {n} has no ingressClassName"); bad += 1
    else:
        print(f"  PASS  {n} class={sp['ingressClassName']}")
    if sp.get("tls"):
        print(f"  PASS  {n} TLS host(s) {sp['tls'][0].get('hosts')} secret {sp['tls'][0].get('secretName')}")
    else:
        print(f"  WARN  {n} has no TLS block")
    for rule in sp["rules"]:
        for path in rule["http"]["paths"]:
            b = path["backend"]["service"]; port = b["port"]["number"]
            ok = port in svc.get(b["name"], set())
            print(f"  {'PASS' if ok else 'FAIL'}  {n} {rule['host']}{path['path']} -> {b['name']}:{port}"
                  + ("" if ok else f"   [service exposes {sorted(svc.get(b['name'], []))}]"))
            if not ok: bad += 1
sys.exit(1 if bad else 0)
PY
check "$?" "ingress backends resolve to real Service ports"

echo
echo "=============== management API (via port-forward) ==============="
$K port-forward svc/sovity-ui-consumer-service 21002:11002 >/dev/null 2>&1 & PFC=$!
$K port-forward svc/sovity-ui-provider-service 21012:11002 >/dev/null 2>&1 & PFP=$!
sleep 6
BASE_C=http://localhost:21002/api/management/v3
BASE_P=http://localhost:21012/api/management/v3
cat >/tmp/q.json <<'JSON'
{ "@context": { "@vocab": "https://w3id.org/edc/v0.0.1/ns/" }, "@type": "QuerySpec", "limit": 50 }
JSON
C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -H 'Content-Type: application/json' \
  -X POST --data @/tmp/q.json "${BASE_C}/assets/request")
check "$([ "$C" = "401" ] && echo 0 || echo 1)" "rejected without an api key" "HTTP $C"
C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -H "X-Api-Key: $KEY" \
  -H 'Content-Type: application/json' -X POST --data @/tmp/q.json "${BASE_C}/assets/request")
check "$([ "$C" = "200" ] && echo 0 || echo 1)" "accepted with the api key" "HTTP $C"

api() { # base method path [datafile]
  if [ -n "${4:-}" ]; then
    curl -s -o /tmp/v.out -w '%{http_code}' --max-time 60 -H "X-Api-Key: $KEY" \
      -H 'Content-Type: application/json' -X "$2" --data @"$4" "$1$3"
  else
    curl -s -o /tmp/v.out -w '%{http_code}' --max-time 60 -H "X-Api-Key: $KEY" \
      -H 'Content-Type: application/json' -X "$2" "$1$3"
  fi
}

publish() { # base tag
  local b="$1" tag="$2"
  cat >/tmp/a.json <<JSON
{ "@context": { "@vocab": "https://w3id.org/edc/v0.0.1/ns/" }, "@id": "${tag}-asset",
  "properties": { "name": "${tag}" },
  "dataAddress": { "@type": "DataAddress", "type": "HttpData", "baseUrl": "https://example.com/${tag}" } }
JSON
  cat >/tmp/p.json <<JSON
{ "@context": { "@vocab": "https://w3id.org/edc/v0.0.1/ns/", "odrl": "http://www.w3.org/ns/odrl/2/" },
  "@id": "${tag}-policy",
  "policy": { "@context": "http://www.w3.org/ns/odrl.jsonld", "@type": "Set",
              "permission": [], "prohibition": [], "obligation": [] } }
JSON
  cat >/tmp/c.json <<JSON
{ "@context": { "@vocab": "https://w3id.org/edc/v0.0.1/ns/" }, "@id": "${tag}-cd",
  "accessPolicyId": "${tag}-policy", "contractPolicyId": "${tag}-policy",
  "assetsSelector": [ { "@type": "Criterion",
    "operandLeft": "https://w3id.org/edc/v0.0.1/ns/id", "operator": "=",
    "operandRight": "${tag}-asset" } ] }
JSON
  api "$b" POST /assets /tmp/a.json >/dev/null
  api "$b" POST /policydefinitions /tmp/p.json >/dev/null
  api "$b" POST /contractdefinitions /tmp/c.json >/dev/null
}

negotiate() { # requesting-base counterparty-service counterparty-id tag
  local b="$1" svc="$2" cpid="$3" tag="$4"
  cat >/tmp/cat.json <<JSON
{ "@context": { "@vocab": "https://w3id.org/edc/v0.0.1/ns/" }, "@type": "CatalogRequest",
  "counterPartyAddress": "http://${svc}:11003/api/v1/dsp", "counterPartyId": "${cpid}",
  "protocol": "dataspace-protocol-http" }
JSON
  api "$b" POST /catalog/request /tmp/cat.json >/dev/null
  cp /tmp/v.out /tmp/catalog.out
  python3 - "$tag" "$cpid" "$svc" <<'PY' >/tmp/neg.json 2>/tmp/neg.err
import json, sys
tag, cpid, svc = sys.argv[1:4]
c = json.load(open('/tmp/catalog.out'))
ds = c.get('dcat:dataset') or []
ds = ds if isinstance(ds, list) else [ds]
d = next((x for x in ds if x.get('@id') == f"{tag}-asset"), None)
if d is None:
    raise SystemExit(f"{tag}-asset not offered")
pol = d.get('odrl:hasPolicy'); pol = pol[0] if isinstance(pol, list) else pol
print(json.dumps({
  "@context": {"@vocab": "https://w3id.org/edc/v0.0.1/ns/", "odrl": "http://www.w3.org/ns/odrl/2/"},
  "@type": "ContractRequest",
  "counterPartyAddress": f"http://{svc}:11003/api/v1/dsp",
  "protocol": "dataspace-protocol-http",
  "policy": {"@context": "http://www.w3.org/ns/odrl.jsonld", "@id": pol.get("@id"),
             "@type": "Offer", "assigner": cpid, "target": d.get("@id"),
             "odrl:permission": pol.get("odrl:permission", []),
             "odrl:prohibition": pol.get("odrl:prohibition", []),
             "odrl:obligation": pol.get("odrl:obligation", [])}}))
PY
  [ -s /tmp/neg.err ] && { echo 1; return; }
  api "$b" POST /contractnegotiations /tmp/neg.json >/dev/null
  local nid st=""
  nid=$(python3 -c "import json;print(json.load(open('/tmp/v.out')).get('@id',''))" 2>/dev/null)
  [ -z "$nid" ] && { echo 1; return; }
  for i in $(seq 1 20); do
    sleep 3
    api "$b" GET "/contractnegotiations/${nid}" >/dev/null
    st=$(python3 -c "import json;print(json.load(open('/tmp/v.out')).get('state',''))" 2>/dev/null)
    [ "$st" = "FINALIZED" ] && { echo 0; return; }
    [ "$st" = "TERMINATED" ] && { echo 1; return; }
  done
  echo 1
}

echo
echo "=============== DSP negotiation, both directions ==============="
publish "$BASE_P" advverify-p2c
R=$(negotiate "$BASE_C" sovity-ui-provider-service provider advverify-p2c)
check "$R" "consumer -> provider negotiation FINALIZED"
publish "$BASE_C" advverify-c2p
R=$(negotiate "$BASE_P" sovity-ui-consumer-service consumer advverify-c2p)
check "$R" "provider -> consumer negotiation FINALIZED"

echo
echo "  cleaning up the offers this script created"
for pair in "$BASE_P:advverify-p2c" "$BASE_C:advverify-c2p"; do
  b="${pair%:*}"; t="${pair##*:}"
  api "$b" DELETE "/contractdefinitions/${t}-cd" >/dev/null
  api "$b" DELETE "/policydefinitions/${t}-policy" >/dev/null
done
echo "  (the two ${t}-asset assets are left in place, unpublished)"

kill $PFC $PFP 2>/dev/null

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "$FAILED CHECK(S) FAILED"; fi
exit "$FAILED"
