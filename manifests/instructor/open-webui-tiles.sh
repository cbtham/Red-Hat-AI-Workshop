#!/usr/bin/env bash
# Open WebUI tiles in the OpenShift AI dashboard (Applications > Enabled)
#
# Creates one "Open WebUI" tile per attendee (user1..userN). Each tile opens
# https://open-webui-userN.<apps domain>, the route that manifests/open-webui.yaml
# creates in project userN in Part 7. The description starts with "userN:" so
# attendees can find their own tile: every tile is visible to every user.
#
# How it works (RHOAI docs, "Adding an application to the dashboard"):
#   - an OdhApplication in redhat-ods-applications defines the tile
#   - spec.endpoint is the URL behind "Open application"
#   - spec.enable.validationConfigMap names a ConfigMap whose
#     validation_result is "true"; that marks the tile enabled, so it shows
#     on Applications > Enabled without anyone clicking Enable
# The dashboard picks up changes within about 1-2 minutes.
#
# Usage (cluster admin, from the repo root):
#   bash manifests/instructor/open-webui-tiles.sh 20          # create user1..user20
#   bash manifests/instructor/open-webui-tiles.sh 20 delete   # remove them
set -euo pipefail

COUNT=${1:-20}
ACTION=${2:-apply}
NS=redhat-ods-applications
APPS_DOMAIN=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}')

for i in $(seq 1 "$COUNT"); do
  U="user$i"
  if [ "$ACTION" = "delete" ]; then
    oc delete odhapplication "open-webui-$U" -n "$NS" --ignore-not-found
    oc delete configmap "open-webui-$U-enable" -n "$NS" --ignore-not-found
    oc patch configmap odh-enabled-applications-config -n "$NS" --type json \
      -p "[{\"op\":\"remove\",\"path\":\"/data/open-webui-$U\"}]" 2>/dev/null || true
    continue
  fi
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: open-webui-$U-enable
  namespace: $NS
data:
  validation_result: "true"
---
apiVersion: dashboard.opendatahub.io/v1
kind: OdhApplication
metadata:
  name: open-webui-$U
  namespace: $NS
  labels:
    app: rhods-dashboard
    app.kubernetes.io/part-of: rhods-dashboard
    app.opendatahub.io/rhods-dashboard: "true"
spec:
  displayName: Open WebUI
  provider: Workshop
  support: third party support
  category: Self-managed
  description: "$U: your Open WebUI chat interface, connected to your model through Models-as-a-Service."
  endpoint: https://open-webui-$U.$APPS_DOMAIN
  enable:
    validationConfigMap: open-webui-$U-enable
  docsLink: https://docs.openwebui.com
  getStartedLink: https://docs.openwebui.com
  getStartedMarkDown: |-
    # Open WebUI
    Deployed in your project ($U) in Part 7 of the workshop. The link works once
    "oc rollout status deployment/open-webui" reports "successfully rolled out".
  img: >-
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36"><rect width="36" height="36" rx="6" fill="#151515"/><text x="18" y="24" font-size="14" text-anchor="middle" fill="#fff" font-family="sans-serif">OI</text></svg>
EOF
done
