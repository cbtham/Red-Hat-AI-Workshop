#!/usr/bin/env bash
###############################################################################
# setup-workshop.sh
#
# Prepares a Red Hat Demo Platform (RHDP) "Field Sourced Content - OpenShift
# (Shared Clusters)" cluster for the RHOAI 3.5 Model Deployment & MaaS workshop,
# for any number of attendees (user1..userN). The limit is GPUs: every
# attendee deploys their own model on one GPU node.
#
# Read ENVIRONMENT-SETUP.md first. In short:
#
#   bash manifests/instructor/setup-workshop.sh --check            # read-only: what's ready, what's missing
#   bash manifests/instructor/setup-workshop.sh --users 20         # set up for user1..user20
#   bash manifests/instructor/setup-workshop.sh --users 20 --cleanup   # after the workshop
#
# Run it from your own terminal (not the OpenShift Web Terminal), logged in
# with `oc login` as a cluster-admin. Every step is safe to re-run: if
# anything stops part-way, run the same command again.
#
# It reuses four scripts from github.com/jingggg-wenn/rhoai-field-source-setup-guide,
# pinned to one commit and checked against a sha256 before they run, then adds
# the pieces this workshop needs (inference gateway, Web Terminals, shared MCP
# server, Open WebUI tiles, premium subscription placeholder, image pre-pull).
#
# Works with the bash that ships with macOS (3.2) and with Linux.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PINNED_REF=4d0a62aba3c7e7625816c6ff031c0e9068fd1004
FS_REF="${FIELD_SOURCE_REF:-$PINNED_REF}"
FS_RAW="https://raw.githubusercontent.com/jingggg-wenn/rhoai-field-source-setup-guide/$FS_REF/scripts"
MODEL_IMAGE="${MODEL_IMAGE:-registry.redhat.io/rhai/modelcar-redhatai-gemma-4-e4b-it:3.0}"
GPU_WAIT_MINUTES="${GPU_WAIT_MINUTES:-30}"
MAPI_NS=openshift-machine-api
RHOAI_NS=redhat-ods-applications

USERS=""
GPUS=""
MODE=setup
SKIP_PLATFORM=false
NO_WAIT=false
ASSUME_YES=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { printf "${CYAN}[INFO]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}   %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; WARNINGS=$((WARNINGS + 1)); }
fail()  { printf "${RED}[STOP]${NC} %s\n" "$*" >&2; exit 1; }
step()  { printf "\n${BOLD}=== %s ===${NC}\n" "$*"; }
WARNINGS=0

usage() {
  cat <<'EOF'
Usage: bash manifests/instructor/setup-workshop.sh [options]

  --users N         Number of attendees (user1..userN). Default: every userN in Keycloak.
  --gpus N          GPU nodes to have ready. Default: same as --users.
                    Add 1 if you want your own demo model (for example --gpus 21).
  --check           Read-only. Show what is ready and what is missing. Changes nothing.
  --skip-platform   Skip the two long platform scripts (use when re-running after they finished).
  --no-wait         Don't wait for the GPU nodes at the end.
  --yes             Don't ask for confirmation.
  --cleanup         After the workshop: remove tiles, Web Terminals and pre-pull pods,
                    and scale GPU nodes to 0. Attendee projects and accounts are kept.
  -h, --help        Show this help.

Environment variables (optional):
  FIELD_SOURCE_REF  Commit of jingggg-wenn/rhoai-field-source-setup-guide to use
                    (default: the pinned, verified commit).
  MODEL_IMAGE       Model image to pre-pull (default: the gemma-4-E4B-it modelcar the guide uses).
  GPU_WAIT_MINUTES  How long to wait for GPU nodes at the end (default: 30).
EOF
}

is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --users)         USERS="${2:-}"; shift 2 ;;
    --gpus)          GPUS="${2:-}"; shift 2 ;;
    --check)         MODE=check; shift ;;
    --cleanup)       MODE=cleanup; shift ;;
    --skip-platform) SKIP_PLATFORM=true; shift ;;
    --no-wait)       NO_WAIT=true; shift ;;
    --yes|-y)        ASSUME_YES=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) usage; fail "Unknown option: $1" ;;
  esac
done
[ -z "$USERS" ] || is_int "$USERS" || fail "--users needs a whole number (got '$USERS')"
[ -z "$GPUS" ]  || is_int "$GPUS"  || fail "--gpus needs a whole number (got '$GPUS')"

confirm() {
  [ "$ASSUME_YES" = true ] && return 0
  [ -t 0 ] || fail "No terminal to ask for confirmation. Re-run with --yes."
  printf "\n%s [y/N] " "$1"
  read -r answer
  case "$answer" in y|Y|yes|YES) return 0 ;; *) echo "Nothing changed."; exit 0 ;; esac
}

# wait_for "<what>" <seconds> <command...>: re-run the command every 10s until it succeeds
wait_for() {
  local what=$1 timeout=$2; shift 2
  local waited=0
  until "$@" >/dev/null 2>&1; do
    if [ "$waited" -ge "$timeout" ]; then echo; return 1; fi
    [ "$waited" -eq 0 ] && printf "       waiting for %s " "$what"
    printf "."
    sleep 10; waited=$((waited + 10))
  done
  [ "$waited" -gt 0 ] && echo
  return 0
}

###############################################################################
# Cluster facts (all read-only)
###############################################################################
apps_domain()  { oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}' 2>/dev/null; }
cert_secret()  { oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null; }
keycloak_users() {
  oc get keycloakrealmimport sso -n keycloak -o jsonpath='{.spec.realm.users[*].username}' 2>/dev/null \
    | tr ' ' '\n' | grep -E '^user[0-9]+$' || true
}

# Machinesets as name|replicas|instanceType|gpusPerNode, split into CPU workers and GPU.
# Same rule as spin-up-workernodes.sh: a GPU MachineSet has "gpu" in its name or a g*/p* instance type.
machinesets() {
  oc get machinesets -n "$MAPI_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.replicas}{"|"}{.spec.template.spec.providerSpec.value.instanceType}{"|"}{.metadata.annotations.machine\.openshift\.io/GPU}{"|"}{.spec.template.metadata.labels.machine\.openshift\.io/cluster-api-machine-role}{"\n"}{end}' 2>/dev/null || true
}
is_gpu_ms() { case "$1" in *gpu*) return 0 ;; esac; echo "$2" | grep -qE '^(g[0-9]|p[0-9])'; }
cpu_workers() {
  local n=0 name rep it gpu role
  while IFS='|' read -r name rep it gpu role; do
    [ -n "$name" ] && [ "$role" = worker ] || continue
    is_gpu_ms "$name" "$it" && continue
    n=$((n + ${rep:-0}))
  done <<EOF
$(machinesets)
EOF
  echo "$n"
}
gpu_configured() {  # GPUs the GPU MachineSets will provide once all their nodes are up
  local n=0 name rep it gpu role
  while IFS='|' read -r name rep it gpu role; do
    [ -n "$name" ] || continue
    is_gpu_ms "$name" "$it" || continue
    n=$((n + ${rep:-0} * ${gpu:-1}))
  done <<EOF
$(machinesets)
EOF
  echo "$n"
}
gpu_machineset_names() {
  local name rep it gpu role
  while IFS='|' read -r name rep it gpu role; do
    [ -n "$name" ] || continue
    is_gpu_ms "$name" "$it" && echo "$name"
  done <<EOF
$(machinesets)
EOF
  return 0
}
gpu_ready() {  # GPUs usable right now (driver installed, node labelled)
  oc get nodes -l nvidia.com/gpu.present=true \
    -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
    | awk '{s += $1} END {print s + 0}'
}
recommended_workers() { echo $(( 2 + ($1 + 9) / 10 )); }   # 3 for <=10 users, 4 for <=20, 5 for <=30
vllm_image() {
  local t
  t=$(oc get llminferenceserviceconfig -n "$RHOAI_NS" -o name 2>/dev/null | grep 'kserve-config-llm-template$' | head -1 || true)
  [ -n "$t" ] && oc get -n "$RHOAI_NS" "$t" -o jsonpath='{.spec.template.containers[?(@.name=="main")].image}' 2>/dev/null
  return 0
}
dashboard_url() {
  local h
  h=$(oc get route data-science-gateway -n openshift-ingress -o jsonpath='{.spec.host}' 2>/dev/null || true)
  [ -n "$h" ] || h=$(oc get route rhods-dashboard -n "$RHOAI_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  [ -n "$h" ] && echo "https://$h" || echo "(not found yet)"
}
guide_url() {  # the workshop guide on GitHub, for whichever fork and branch you cloned
  local remote branch
  remote=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null) || return 0
  branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
  remote=$(echo "$remote" | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##')
  case "$remote" in https://github.com/*) echo "$remote/blob/$branch/RHOAI-MODEL-DEPLOYMENT-WORKSHOP.md" ;; esac
}

###############################################################################
# Preflight
###############################################################################
preflight() {
  command -v oc >/dev/null 2>&1 || fail "The 'oc' command is not installed. Download it from the OpenShift Console: ? (help icon, top right) > Command Line Tools."
  oc whoami >/dev/null 2>&1 || fail "You are not logged in. In the OpenShift Console click your user name (top right) > Copy login command, paste the 'oc login ...' line into this terminal, then run this script again."
  [ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null || true)" = yes ] \
    || fail "You are logged in as '$(oc whoami)', which is not a cluster-admin. Log in as the admin user shown on your RHDP service page."
  oc get datasciencecluster -o name 2>/dev/null | grep -q . \
    || fail "OpenShift AI is not installed on this cluster. Order the RHDP environment with 'Select Base Workloads > OpenShift AI' checked (ENVIRONMENT-SETUP.md, Step 1)."

  KC_COUNT=$(keycloak_users | grep -c . || true)
  if [ -z "$USERS" ]; then
    [ "$KC_COUNT" -gt 0 ] || fail "No workshop users found in Keycloak. Pass --users N."
    USERS=$KC_COUNT
  fi
  [ "$USERS" -gt 0 ] || fail "--users must be at least 1."
  if [ "$KC_COUNT" -gt 0 ] && [ "$USERS" -gt "$KC_COUNT" ]; then
    fail "Keycloak has only $KC_COUNT workshop users (user1..user$KC_COUNT), so --users $USERS won't work. Use --users $KC_COUNT or fewer, or order an environment with more users."
  fi
  [ -n "$GPUS" ] || GPUS=$USERS
}

setup_tools() {
  local t
  for t in curl python3; do
    command -v "$t" >/dev/null 2>&1 || fail "'$t' is not installed. It is needed to run the setup scripts."
  done
  if command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then SHA="shasum -a 256"
  else fail "Neither sha256sum nor shasum is installed."; fi
  # Kept in the repo folder (git-ignored), not a temp folder, so the logs are still
  # there at cleanup time (spin-up-workernodes.log ends with the scale-back commands)
  WORK_DIR="$REPO_ROOT/setup-logs/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$WORK_DIR"
  info "Logs and downloaded scripts: setup-logs/$(basename "$WORK_DIR")"
}

###############################################################################
# Reused scripts from jingggg-wenn/rhoai-field-source-setup-guide
###############################################################################
expected_sha() {
  case "$1" in
    setup_workshop_users_rbac.sh)            echo b78314f0a674b96a86a1d00bd71f2bbb15315c0f0b8a4a10154780c5288c73a5 ;;
    spin-up-workernodes.sh)                  echo c3443b5dc5acb053e475e7f97d574ca3fd669b6ac33655e433f09139e787e7a7 ;;
    gpu_machineset_hardwareprofiles.sh)      echo 5002877d2e4bed6ede8955ce4043d5e7af5c32015bd1040b52cfca7d8208b5e5 ;;
    field-source-enable-all-features-35.sh)  echo 6b29c3e2f3a1781649d5a646abff036f78c19b6f2328dc6860142f729ef07af7 ;;
    field-source-setup-maas-35.sh)           echo 7c1c5af93ac6d17dc94dd03b800a812f2dd281c79151b388467cbe2febc5b54c ;;
  esac
}

# run_reused <path under scripts/> [args...]: download, verify, run, log
run_reused() {
  local path=$1; shift
  local name; name=$(basename "$path")
  local file="$WORK_DIR/$name" log="$WORK_DIR/${name%.sh}.log"
  if [ ! -s "$file" ]; then
    curl -fsSL "$FS_RAW/$path" -o "$file" || fail "Could not download $FS_RAW/$path"
    if [ "$FS_REF" = "$PINNED_REF" ]; then
      local got; got=$($SHA "$file" | awk '{print $1}')
      [ "$got" = "$(expected_sha "$name")" ] || fail "$name does not match the verified copy (sha256 $got). Not running it."
    else
      warn "FIELD_SOURCE_REF=$FS_REF is not the pinned commit, so $name is not checksum-verified."
    fi
  fi
  info "Running $name $* (log: $log)"
  if ! bash "$file" "$@" 2>&1 | tee "$log"; then
    fail "$name stopped with an error (log: $log). Fix what it reports, then run the same setup command again. Finished steps are skipped or re-applied safely."
  fi
}

###############################################################################
# --check: read-only status
###############################################################################
CHECK_BAD=0
row() {  # row <ok|bad|info> <item> <detail> [fix]
  local state=$1 item=$2 detail=$3 fix=${4:-}
  case "$state" in
    ok)   printf "  ${GREEN}[OK]${NC}  %-28s %s\n" "$item" "$detail" ;;
    bad)  printf "  ${RED}[!!]${NC}  %-28s %s\n" "$item" "$detail"; CHECK_BAD=$((CHECK_BAD + 1))
          [ -n "$fix" ] && printf "        %-28s ${YELLOW}fix:${NC} %s\n" "" "$fix" ;;
    *)    printf "  ${CYAN}[--]${NC}  %-28s %s\n" "$item" "$detail" ;;
  esac
  return 0
}

run_check() {
  local me; me="bash manifests/instructor/setup-workshop.sh --users $USERS"
  CHECK_BAD=0
  step "Workshop readiness for $USERS attendees (user1..user$USERS), $GPUS GPUs"

  # One query per resource type, then count per user (fast even for 30 users)
  local crbs grp nss ocusers dws odhapps
  crbs=$(oc get clusterrolebinding -o name 2>/dev/null || true)
  grp=$(oc get group rhods-admins -o jsonpath='{.users}' 2>/dev/null || true)
  nss=$(oc get namespaces -o name 2>/dev/null || true)
  ocusers=$(oc get users -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.uid}{"\n"}{end}' 2>/dev/null || true)
  dws=$(oc get devworkspace -n openshift-terminal -l console.openshift.io/terminal=true \
        -o jsonpath='{range .items[*]}{.metadata.labels.controller\.devfile\.io/creator}{"\n"}{end}' 2>/dev/null || true)
  odhapps=$(oc get odhapplication -n "$RHOAI_NS" -o name 2>/dev/null || true)
  local i uid crb=0 in_grp=0 pre="" logged=0 term=0 tiles=0
  for i in $(seq 1 "$USERS"); do
    echo "$crbs" | grep -q "/cluster-admin-user$i\$" && crb=$((crb + 1))
    echo "$grp" | grep -q "\"user$i\"" && in_grp=$((in_grp + 1))
    echo "$nss" | grep -q "^namespace/user$i\$" && pre="$pre user$i"
    echo "$odhapps" | grep -q "/open-webui-user$i\$" && tiles=$((tiles + 1))
    uid=$(echo "$ocusers" | awk -v u="user$i" '$1 == u {print $2}')
    if [ -n "$uid" ]; then
      logged=$((logged + 1))
      echo "$dws" | grep -qx "$uid" && term=$((term + 1))
    fi
  done

  # Users
  if [ "$KC_COUNT" -ge "$USERS" ]; then row ok "Keycloak users" "$KC_COUNT found"
  else row bad "Keycloak users" "$KC_COUNT found, need $USERS" "order the environment with more users"; fi
  [ "$crb" -ge "$USERS" ] && row ok "Attendee cluster-admin" "$crb/$USERS" || row bad "Attendee cluster-admin" "$crb/$USERS" "$me"
  [ "$in_grp" -ge "$USERS" ] && row ok "rhods-admins group" "$in_grp/$USERS" || row bad "rhods-admins group" "$in_grp/$USERS" "$me"
  local sp; sp=$(oc get clusterrolebinding self-provisioners -o jsonpath='{.subjects[*].name}' 2>/dev/null || true)
  echo "$sp" | grep -q 'system:authenticated' && row ok "Users can create projects" "self-provisioners" \
    || row bad "Users can create projects" "self-provisioners binding missing" "oc adm policy add-cluster-role-to-group self-provisioner system:authenticated:oauth"
  [ -z "$pre" ] && row ok "No pre-created projects" "attendees create userN in Part 2" \
    || row info "Projects already exist" "${pre# } (fine if attendees made them; Part 2 tells them to create it)"

  # Capacity
  local cw rw gc gr
  cw=$(cpu_workers); rw=$(recommended_workers "$USERS")
  [ "$cw" -ge "$rw" ] && row ok "CPU workers" "$cw (recommended $rw)" || row bad "CPU workers" "$cw, recommended $rw" "$me   (adds workers)"
  gc=$(gpu_configured); gr=$(gpu_ready)
  [ "$gc" -ge "$GPUS" ] && row ok "GPU nodes requested" "$gc (need $GPUS)" || row bad "GPU nodes requested" "$gc, need $GPUS" "$me --gpus $GPUS"
  [ "$gr" -ge "$GPUS" ] && row ok "GPUs ready" "$gr (need $GPUS)" \
    || row bad "GPUs ready" "$gr of $GPUS" "wait 15-20 min after scaling; then: oc get machines -n $MAPI_NS"
  oc get hardwareprofile gpu-profile -n "$RHOAI_NS" >/dev/null 2>&1 && row ok "Hardware profile" "gpu-profile" \
    || row bad "Hardware profile" "gpu-profile missing" "$me"

  # Platform
  oc get clusterpolicy -o name 2>/dev/null | grep -q . && row ok "NVIDIA GPU Operator" "installed" \
    || row bad "NVIDIA GPU Operator" "missing" "$me   (platform step)"
  oc get gateway maas-default-gateway -n openshift-ingress >/dev/null 2>&1 && row ok "MaaS gateway" "maas-default-gateway" \
    || row bad "MaaS gateway" "missing" "$me   (platform step)"
  oc get kuadrant -A -o name 2>/dev/null | grep -q . && row ok "Connectivity Link (RHCL)" "installed" \
    || row bad "Connectivity Link (RHCL)" "missing" "$me   (platform step)"
  oc get secret maas-db-config -n redhat-ai-gateway-infra >/dev/null 2>&1 && row ok "MaaS database" "configured" \
    || row bad "MaaS database" "missing" "$me   (platform step)"

  # Workshop add-ons
  local pg; pg=$(oc get gateway openshift-ai-inference -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
  [ "$pg" = True ] && row ok "Inference gateway" "openshift-ai-inference" || row bad "Inference gateway" "${pg:-missing}" "$me --skip-platform"
  oc get devworkspacetemplate web-terminal-tooling -n openshift-operators >/dev/null 2>&1 && row ok "Web Terminal operator" "installed" \
    || row bad "Web Terminal operator" "missing" "$me --skip-platform"
  if [ "$logged" -eq 0 ]; then row info "Web Terminals" "no attendee has logged in yet; run after Part 1: bash manifests/instructor/web-terminals.sh $USERS"
  elif [ "$term" -ge "$logged" ]; then row ok "Web Terminals" "$term ready ($logged of $USERS attendees have logged in)"
  else row bad "Web Terminals" "$term of $logged logged-in attendees" "bash manifests/instructor/web-terminals.sh $USERS"; fi
  local mcp; mcp=$(oc get deployment openshift-mcp-server -n workshop-mcp -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  [ "${mcp:-0}" -ge 1 ] && row ok "Shared MCP server" "running" || row bad "Shared MCP server" "not running" "$me --skip-platform"
  [ "$tiles" -ge "$USERS" ] && row ok "Open WebUI tiles" "$tiles/$USERS" || row bad "Open WebUI tiles" "$tiles/$USERS" "bash manifests/instructor/open-webui-tiles.sh $USERS"
  oc get maassubscription premium-subscription -n models-as-a-service >/dev/null 2>&1 && row ok "Premium placeholder" "premium subscription (shows Failed, expected)" \
    || row bad "Premium placeholder" "missing" "oc apply -f manifests/instructor/premium-subscription.yaml"
  local want have
  want=$(oc get daemonset model-prepull -n workshop-prepull -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || true)
  have=$(oc get daemonset model-prepull -n workshop-prepull -o jsonpath='{.status.numberReady}' 2>/dev/null || true)
  if [ -z "$want" ]; then row bad "Model image pre-pull" "missing" "$me --skip-platform"
  elif [ "${have:-0}" -ge "$want" ] && [ "$want" -gt 0 ]; then row ok "Model image pre-pull" "cached on $have/$want GPU nodes"
  else row bad "Model image pre-pull" "cached on ${have:-0}/$want GPU nodes" "still pulling (~15 min per node); check again later"; fi

  echo
  if [ "$CHECK_BAD" -eq 0 ]; then ok "Everything is ready."; else warn "$CHECK_BAD item(s) need attention (see fix: lines above)."; fi
}

print_handout() {
  local idp guide
  idp=$(oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' 2>/dev/null || true)
  guide=$(guide_url)
  step "Attendee handout (share this, not the admin login)"
  cat <<EOF
  OpenShift AI dashboard : $(dashboard_url)
  OpenShift Console      : $(oc whoami --show-console 2>/dev/null || echo "(not found)")
  Log in with            : ${idp:-the workshop login provider}
  Username               : user1 ... user$USERS (one per attendee)
  Password               : the user password on your RHDP service page
  Workshop guide         : ${guide:-RHOAI-MODEL-DEPLOYMENT-WORKSHOP.md in this repo}
EOF
}

###############################################################################
# --cleanup
###############################################################################
run_cleanup() {
  step "Clean up after the workshop"
  echo "  This removes, for user1..user$USERS:"
  echo "    - the Open WebUI tiles and the pre-created Web Terminals"
  echo "    - the image pre-pull pods (namespace workshop-prepull)"
  echo "  and scales every GPU MachineSet to 0 (GPU nodes are the most expensive part)."
  echo "  Attendee projects, models, accounts and permissions are NOT touched."
  echo "  Skip this if you are deleting the whole RHDP environment anyway."
  confirm "Clean up now?"
  bash "$SCRIPT_DIR/open-webui-tiles.sh" "$USERS" delete || warn "Some tiles were not removed"
  bash "$SCRIPT_DIR/web-terminals.sh" "$USERS" delete || warn "Some Web Terminals were not removed"
  oc delete project workshop-prepull --ignore-not-found || warn "workshop-prepull not removed"
  local ms
  for ms in $(gpu_machineset_names); do
    oc scale machineset "$ms" -n "$MAPI_NS" --replicas=0 || warn "Could not scale $ms to 0"
  done
  ok "Done. To also remove what attendees created, see 'Clean up' in ENVIRONMENT-SETUP.md."
}

###############################################################################
# Main setup
###############################################################################
run_setup() {
  local cw rw gc add_gpu gpu_vcpu
  cw=$(cpu_workers); rw=$(recommended_workers "$USERS")
  gc=$(gpu_configured); add_gpu=$(( GPUS > gc ? GPUS - gc : 0 ))
  gpu_vcpu=$(( 8 * (gc + add_gpu) ))

  step "Plan"
  echo "  Cluster        : $(oc whoami --show-server)  (logged in as $(oc whoami))"
  echo "  Attendees      : $USERS  (user1..user$USERS; Keycloak has $KC_COUNT)"
  if [ "$cw" -lt "$rw" ]; then echo "  CPU workers    : $cw now, $rw recommended -> add $((rw - cw))"
  else echo "  CPU workers    : $cw (recommended $rw) -> no change"; fi
  if [ "$add_gpu" -gt 0 ]; then echo "  GPU nodes      : $gc now, $GPUS wanted -> add $add_gpu g6.2xlarge (1 NVIDIA L4 each)"
  else echo "  GPU nodes      : $gc (wanted $GPUS) -> no change"; fi
  if [ "$SKIP_PLATFORM" = true ]; then echo "  Platform       : skipped (--skip-platform)"
  else echo "  Platform       : operators, MaaS and Connectivity Link (20-40 min on a new cluster)"; fi
  echo "  Workshop parts : inference gateway, Web Terminals, shared MCP server, Open WebUI tiles,"
  echo "                   premium subscription placeholder, model image pre-pull"
  echo "  Total time     : about 45-60 min on a new cluster, mostly waiting"
  if [ "$gpu_vcpu" -gt 64 ]; then
    echo
    printf "  ${YELLOW}Note:${NC} %s GPU nodes use %s vCPU of AWS's G/VT instance quota. Without the RHDP\n" "$((gc + add_gpu))" "$gpu_vcpu"
    echo "        'OPEN environment' option that quota can be 64 vCPU (8 GPU nodes), and the extra"
    echo "        GPU machines stay in Provisioning/Failed. See ENVIRONMENT-SETUP.md, Step 1."
  fi
  confirm "Start?"
  setup_tools

  step "1/6 Attendee permissions (cluster-admin + rhods-admins)"
  run_reused workshop-prep/setup_workshop_users_rbac.sh

  step "2/6 CPU worker nodes"
  if [ "$cw" -lt "$rw" ]; then
    run_reused workshop-prep/spin-up-workernodes.sh --workers "$rw" --no-wait
  else
    ok "$cw workers already, enough for $USERS attendees"
  fi

  step "3/6 GPU nodes and the gpu-profile hardware profile"
  run_reused workshop-prep/gpu_machineset_hardwareprofiles.sh
  # The guide says "gpu-profile", so drop the GPU model from the display name
  oc annotate hardwareprofile gpu-profile -n "$RHOAI_NS" --overwrite \
    opendatahub.io/display-name=gpu-profile \
    opendatahub.io/description="One NVIDIA GPU for workshop model deployments." >/dev/null
  ok "gpu-profile display name set"
  gc=$(gpu_configured)
  if [ "$gc" -lt "$GPUS" ]; then
    local infra ms cur
    infra=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
    ms=$(gpu_machineset_names | grep "^${infra}-worker-gpu-" | head -1 || true)
    [ -n "$ms" ] || ms=$(gpu_machineset_names | head -1)
    [ -n "$ms" ] || fail "No GPU MachineSet found after gpu_machineset_hardwareprofiles.sh. Check its log in $WORK_DIR."
    cur=$(oc get machineset "$ms" -n "$MAPI_NS" -o jsonpath='{.spec.replicas}')
    oc scale machineset "$ms" -n "$MAPI_NS" --replicas=$(( cur + GPUS - gc ))
    ok "Scaled $ms to $(( cur + GPUS - gc )) node(s). They boot while the platform installs."
  else
    ok "$gc GPU node(s) already requested"
  fi

  step "4/6 Platform: operators, MaaS, Connectivity Link"
  if [ "$SKIP_PLATFORM" = true ]; then
    info "Skipped (--skip-platform)"
  else
    run_reused field-source-enable-all-features-35.sh
    run_reused field-source-setup-maas-35.sh
  fi

  step "5/6 Workshop add-ons"
  local domain cert
  domain=$(apps_domain); cert=$(cert_secret)
  [ -n "$domain" ] || fail "Could not read the cluster's apps domain."
  sed -e "s/\${APPS_DOMAIN}/$domain/g" -e "s/\${CERT_SECRET}/${cert:-router-certs-default}/g" \
    "$SCRIPT_DIR/inference-gateway.yaml" | oc apply -f - && ok "Inference gateway (inference.$domain)" || warn "Inference gateway not applied"

  oc apply -f "$SCRIPT_DIR/web-terminal-subscription.yaml" >/dev/null || warn "Web Terminal subscription not applied"
  if wait_for "the Web Terminal operator" 600 oc get devworkspacetemplate web-terminal-tooling -n openshift-operators; then
    ok "Web Terminal operator"
    # Terminals can only be created for attendees who have logged in once, so on a new cluster this creates none yet
    if bash "$SCRIPT_DIR/web-terminals.sh" "$USERS" >"$WORK_DIR/web-terminals.log" 2>&1; then
      ok "Web Terminals ready for attendees who have logged in (the rest: re-run after Part 1)"
    else
      warn "Some Web Terminals were not created (log: $WORK_DIR/web-terminals.log)"
    fi
  else
    warn "Web Terminal operator not ready after 10 min. Later run: bash manifests/instructor/web-terminals.sh $USERS"
  fi

  oc apply -f "$SCRIPT_DIR/mcp-server-shared.yaml" >/dev/null && ok "Shared MCP server" || warn "Shared MCP server not applied"
  bash "$SCRIPT_DIR/open-webui-tiles.sh" "$USERS" >/dev/null && ok "Open WebUI tiles for user1..user$USERS" || warn "Open WebUI tiles not created"

  if wait_for "the MaaS subscription API" 300 oc get crd maassubscriptions.maas.opendatahub.io; then
    oc apply -f "$SCRIPT_DIR/premium-subscription.yaml" >/dev/null && ok "Premium subscription placeholder" || warn "Premium subscription not applied"
  else
    warn "MaaS subscriptions are not available. Is the platform step done? Later run: oc apply -f manifests/instructor/premium-subscription.yaml"
  fi

  local vllm; vllm=$(vllm_image)
  if [ -n "$vllm" ]; then
    sed -e "s|\${VLLM_IMAGE}|$vllm|g" -e "s|\${MODEL_IMAGE}|$MODEL_IMAGE|g" "$SCRIPT_DIR/model-prepull.yaml" \
      | oc apply -f - >/dev/null && ok "Model image pre-pull on every GPU node" || warn "Pre-pull not applied"
  else
    warn "Could not find the vLLM runtime image; skipped the pre-pull. Re-run with --skip-platform once RHOAI is fully up."
  fi

  step "6/6 GPU nodes"
  if [ "$NO_WAIT" = true ]; then
    info "Not waiting (--no-wait). Check later with: bash manifests/instructor/setup-workshop.sh --check"
  else
    info "New GPU nodes take 15-20 min (boot, then the NVIDIA driver). Waiting up to $GPU_WAIT_MINUTES min; Ctrl+C is safe."
    local waited=0 ready
    while :; do
      ready=$(gpu_ready)
      printf "\r       GPUs ready: %s of %s " "$ready" "$GPUS"
      [ "$ready" -ge "$GPUS" ] && { echo; ok "All $GPUS GPUs ready"; break; }
      if [ "$waited" -ge $(( GPU_WAIT_MINUTES * 60 )) ]; then
        echo; warn "Only $ready of $GPUS GPUs ready. See 'GPU nodes don't come up' in ENVIRONMENT-SETUP.md."
        break
      fi
      sleep 30; waited=$((waited + 30))
    done
  fi

  run_check
  print_handout
  cat <<EOF

Next:
  1. Do the dry run in ENVIRONMENT-SETUP.md as one test user, then clean it up.
  2. Once attendees have logged in (Part 1), start their Web Terminals:
       bash manifests/instructor/web-terminals.sh $USERS
  3. Any time: bash manifests/instructor/setup-workshop.sh --users $USERS --check
EOF
}

preflight
case "$MODE" in
  check)   run_check; print_handout ;;
  cleanup) run_cleanup ;;
  *)       run_setup ;;
esac
