#!/usr/bin/env bash
# Pre-create a Web Terminal (the >_ icon in the OpenShift Console) for user1..userN
#
# Attendees are cluster admins, so the console keeps their terminal in the
# openshift-terminal namespace and finds it by the label
# controller.devfile.io/creator=<user UID>. The DevWorkspace webhook sets that
# label from whoever creates the object, so this script creates each terminal
# while impersonating the attendee (--as / --as-uid). When the attendee clicks
# >_ the terminal is already running: no "Initialize terminal" step.
#
# A user's UID exists only after their first login, so users who have not
# logged in yet are skipped. Re-run the script after they log in; users who
# already have a terminal are left alone.
#
# The idle timeout is raised from 15m to 4h (override with
# WEB_TERMINAL_IDLE_TIMEOUT=...). A stopped terminal restarts when opened.
#
# Usage (cluster admin, from the repo root):
#   bash manifests/instructor/web-terminals.sh 20          # create for user1..user20
#   bash manifests/instructor/web-terminals.sh 20 delete   # remove them
set -euo pipefail

COUNT=${1:-20}
ACTION=${2:-apply}
NS=openshift-terminal
TIMEOUT=${WEB_TERMINAL_IDLE_TIMEOUT:-4h}

oc get namespace "$NS" >/dev/null 2>&1 || oc create namespace "$NS"

for i in $(seq 1 "$COUNT"); do
  U="user$i"
  if ! UID_=$(oc get user "$U" -o jsonpath='{.metadata.uid}' 2>/dev/null) || [ -z "$UID_" ]; then
    echo "$U: skipped (has not logged in yet)"
    continue
  fi
  SELECTOR="console.openshift.io/terminal=true,controller.devfile.io/creator=$UID_"
  if [ "$ACTION" = "delete" ]; then
    oc delete devworkspace -n "$NS" -l "$SELECTOR" --ignore-not-found
    continue
  fi
  if [ -n "$(oc get devworkspace -n "$NS" -l "$SELECTOR" -o name)" ]; then
    echo "$U: terminal already exists"
    continue
  fi
  cat <<EOF | oc create --as="$U" --as-uid="$UID_" -f -
apiVersion: workspace.devfile.io/v1alpha2
kind: DevWorkspace
metadata:
  name: terminal-$U
  namespace: $NS
  labels:
    console.openshift.io/terminal: "true"
  annotations:
    controller.devfile.io/restricted-access: "true"
    controller.devfile.io/devworkspace-source: web-terminal
spec:
  started: true
  routingClass: web-terminal
  template:
    components:
      - name: web-terminal-exec
        plugin:
          kubernetes:
            name: web-terminal-exec
            namespace: openshift-operators
          components:
            - name: web-terminal-exec
              container:
                env:
                  - name: WEB_TERMINAL_IDLE_TIMEOUT
                    value: "$TIMEOUT"
      - name: web-terminal-tooling
        plugin:
          kubernetes:
            name: web-terminal-tooling
            namespace: openshift-operators
EOF
done
