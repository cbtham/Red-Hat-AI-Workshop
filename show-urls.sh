#!/bin/bash
# Print the URLs participants need for Part 7 (Open WebUI + MaaS).
# Everything is read from the cluster, so it works on any workshop cluster.
# Prints no secrets: you paste your own sk-oai-... API key into Open WebUI.
NS="${NAMESPACE:-$(oc project -q 2>/dev/null)}"
OWUI_HOST="$(oc get route open-webui -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null)"
MAAS_HOST="$(oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.listeners[0].hostname}' 2>/dev/null)"
# Fallback if the gateway can't be read: MaaS lives at maas.<apps domain>
[ -z "$MAAS_HOST" ] && [ -n "$OWUI_HOST" ] && MAAS_HOST="maas.${OWUI_HOST#*.}"
echo ""
echo "=== Workshop URLs for $NS ==="
echo ""
echo "Open WebUI:"
if [ -n "$OWUI_HOST" ]; then
  echo "  https://$OWUI_HOST"
else
  echo "  (not deployed yet - see Step 7.5)"
fi
echo ""
echo "MaaS base URL (paste in Open WebUI > Connections > URL):"
echo "  https://${MAAS_HOST:-<not found>}/v1"
echo ""
echo "MaaS model ID:"
echo "  publishers/$NS/models/gemma-4-e4b-it"
echo ""
echo "API key: create it in OpenShift AI > Gen AI studio > API keys (starts with sk-oai-)"
echo ""
