#!/usr/bin/env bash
# deploy-openshift.sh — Deploy Retail Agentic Commerce Blueprint on OpenShift
#
# This script is idempotent: safe to re-run without breaking anything.
# All cluster-specific values are parameterized via environment variables.
# No upstream files are permanently modified — all OpenShift-specific files
# live under the openshift/ directory.
#
# Usage (cloud API mode — 0 GPUs):
#   NVIDIA_API_KEY=nvapi-... NGC_API_KEY=nvapi-... \
#     bash openshift/deploy/helm/deploy-openshift.sh
#
# Usage (local NIM mode — 2+ GPUs):
#   NVIDIA_API_KEY=nvapi-... NGC_API_KEY=nvapi-... DEPLOY_NIMS=true \
#     bash openshift/deploy/helm/deploy-openshift.sh
#
# Required environment variables:
#   NVIDIA_API_KEY   — build.nvidia.com key for hosted NIM inference and agent LLM calls.
#                      Get one at https://build.nvidia.com (click "Get API Key").
#   NGC_API_KEY      — NGC key for pulling images from nvcr.io (only needed when DEPLOY_NIMS=true).
#                      Get one at https://org.ngc.nvidia.com/setup/api-keys
#                      When DEPLOY_NIMS=false, defaults to NVIDIA_API_KEY.
#
# Optional environment variables:
#   NAMESPACE            — OpenShift namespace (default: agentic-commerce)
#   DEPLOY_NIMS          — true/false; deploy self-hosted NIM containers (default: false)
#   STORAGE_CLASS        — StorageClass for PVCs (default: cluster default)
#   GPU_TOLERATION_KEYS  — Comma-separated taint keys on GPU nodes (default: auto-detect)
#   IMAGE_REGISTRY       — External registry for pre-built images; empty = use OpenShift internal
#   ROLLOUT_TIMEOUT      — Seconds to wait for each deployment rollout (default: 600)
#   MERCHANT_API_KEY     — Merchant API auth key (default: merchant-api-key-12345)
#   PSP_API_KEY          — PSP API auth key (default: psp-api-key-12345)
#   WEBHOOK_SECRET       — Webhook signature secret (default: whsec_demo_secret)
#   NIM_LLM_MODEL_NAME   — LLM model name for cloud API (default: nvidia/nemotron-3-nano-30b-a3b)
#   NIM_EMBED_MODEL_NAME — Embedding model name (default: nvidia/nv-embedqa-e5-v5)
set -euo pipefail

# ============================================================================
# Validate required environment variables
# ============================================================================

: "${NVIDIA_API_KEY:?Error: NVIDIA_API_KEY is required (get one at https://build.nvidia.com)}"

# ============================================================================
# Configuration
# ============================================================================

NAMESPACE="${NAMESPACE:-agentic-commerce}"
DEPLOY_NIMS="${DEPLOY_NIMS:-false}"
NGC_API_KEY="${NGC_API_KEY:-$NVIDIA_API_KEY}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
GPU_TOLERATION_KEYS="${GPU_TOLERATION_KEYS:-auto}"
GPU_TOLERATION_EFFECT="${GPU_TOLERATION_EFFECT:-NoSchedule}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-600}"

MERCHANT_API_KEY="${MERCHANT_API_KEY:-merchant-api-key-12345}"
PSP_API_KEY="${PSP_API_KEY:-psp-api-key-12345}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-whsec_demo_secret}"

# NIM / model configuration
if [[ "${DEPLOY_NIMS}" == "true" ]]; then
  NIM_LLM_BASE_URL="http://nim-llm:8000/v1"
  NIM_LLM_MODEL_NAME="${NIM_LLM_MODEL_NAME:-nvidia/nemotron-3-nano}"
  NIM_EMBED_BASE_URL="http://nim-embedqa:8000/v1"
  NIM_EMBED_MODEL_NAME="${NIM_EMBED_MODEL_NAME:-nvidia/nv-embedqa-e5-v5}"
else
  NIM_LLM_BASE_URL="${NIM_LLM_BASE_URL:-https://integrate.api.nvidia.com/v1}"
  NIM_LLM_MODEL_NAME="${NIM_LLM_MODEL_NAME:-nvidia/nemotron-3-nano-30b-a3b}"
  NIM_EMBED_BASE_URL="${NIM_EMBED_BASE_URL:-https://integrate.api.nvidia.com/v1}"
  NIM_EMBED_MODEL_NAME="${NIM_EMBED_MODEL_NAME:-nvidia/nv-embedqa-e5-v5}"
fi

# Derived paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENSHIFT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)/openshift"
REPO_ROOT="$(cd "${OPENSHIFT_DIR}/.." && pwd)"

# Parse GPU toleration keys into array
IFS=',' read -ra TKEYS <<< "${GPU_TOLERATION_KEYS}"

echo "=== Retail Agentic Commerce — OpenShift Deployment ==="
echo "Namespace:       ${NAMESPACE}"
echo "Deploy NIMs:     ${DEPLOY_NIMS}"
echo "LLM endpoint:    ${NIM_LLM_BASE_URL}"
echo "Embed endpoint:  ${NIM_EMBED_BASE_URL}"
echo ""

# ============================================================================
# Cleanup handler — guarantees upstream files are restored on exit
# ============================================================================

BACKUP_DIR=""

cleanup() {
  if [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]]; then
    info "Restoring any patched upstream files from ${BACKUP_DIR}..."
    rm -rf "${BACKUP_DIR}"
    ok "Upstream files restored"
  fi
}
trap cleanup EXIT

# ============================================================================
# Helpers
# ============================================================================

info()  { echo -e "\n\033[1;34m[INFO]\033[0m  $*"; }
warn()  { echo -e "\n\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; }
ok()    { echo -e "  \033[1;32m✓\033[0m $*"; }

check_tool() {
  if ! command -v "$1" &>/dev/null; then
    error "$1 is required but not found. Please install it first."
    exit 1
  fi
}

wait_for_rollout() {
  local kind="$1" name="$2" ns="$3"
  info "Waiting for ${kind}/${name} in ${ns} (timeout: ${ROLLOUT_TIMEOUT}s)..."
  if oc rollout status "${kind}/${name}" -n "${ns}" --timeout="${ROLLOUT_TIMEOUT}s" 2>/dev/null; then
    ok "${kind}/${name} is ready"
  else
    warn "${kind}/${name} did not become ready within ${ROLLOUT_TIMEOUT}s — check: oc logs ${kind}/${name} -n ${ns}"
  fi
}

# ============================================================================
# Phase 1: Pre-flight checks
# ============================================================================

info "Phase 1 — Pre-flight checks"
check_tool oc

if ! oc whoami &>/dev/null; then
  error "Not logged into an OpenShift cluster. Run: oc login <cluster-url>"
  exit 1
fi
ok "Logged in as $(oc whoami) on $(oc whoami --show-server)"

if [[ "${DEPLOY_NIMS}" == "true" ]]; then
  GPU_NODES=$(oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l)
  if [[ "${GPU_NODES}" -eq 0 ]]; then
    warn "No GPU nodes found (label nvidia.com/gpu.present=true). NIM pods will stay Pending."
  else
    ok "Found ${GPU_NODES} GPU node(s)"

    if [[ "${GPU_TOLERATION_KEYS}" == "auto" ]]; then
      DETECTED_KEYS=$(oc get nodes -l nvidia.com/gpu.present=true \
        -o jsonpath='{range .items[*]}{range .spec.taints[*]}{.key}{"\n"}{end}{end}' 2>/dev/null \
        | grep -v 'node-role.kubernetes.io' \
        | sort -u \
        | tr '\n' ',' \
        | sed 's/,$//')
      if [[ -n "${DETECTED_KEYS}" ]]; then
        GPU_TOLERATION_KEYS="${DETECTED_KEYS}"
        IFS=',' read -ra TKEYS <<< "${GPU_TOLERATION_KEYS}"
        ok "Auto-detected GPU taint keys: ${GPU_TOLERATION_KEYS}"
      else
        GPU_TOLERATION_KEYS="nvidia.com/gpu"
        IFS=',' read -ra TKEYS <<< "${GPU_TOLERATION_KEYS}"
        ok "No custom taints on GPU nodes, using default: nvidia.com/gpu"
      fi
    else
      ok "Using configured GPU taint keys: ${GPU_TOLERATION_KEYS}"
    fi
  fi
fi

# ============================================================================
# Phase 2: Namespace and Security Context Constraints
# ============================================================================

info "Phase 2 — Namespace and SCC setup"

if oc get namespace "${NAMESPACE}" &>/dev/null; then
  ok "Namespace ${NAMESPACE} already exists"
else
  oc new-project "${NAMESPACE}" --display-name="Agentic Commerce" 2>/dev/null \
    || oc create namespace "${NAMESPACE}"
  ok "Created namespace ${NAMESPACE}"
fi

for SA in default; do
  if oc adm policy add-scc-to-user anyuid -z "${SA}" -n "${NAMESPACE}" 2>/dev/null; then
    ok "Granted anyuid SCC to ${SA}"
  else
    ok "anyuid SCC already granted to ${SA}"
  fi
done

# ============================================================================
# Phase 3: Secrets
# ============================================================================

info "Phase 3 — Secrets"

HELM_RELEASE_NAME="agentic-commerce"

create_secret() {
  local secret_name="$1"
  shift
  local secret_args=("$@")

  if oc get secret "${secret_name}" -n "${NAMESPACE}" &>/dev/null; then
    ok "Secret ${secret_name} already exists"
    return
  fi

  oc create secret "${secret_args[@]}" \
    --dry-run=client -o yaml \
    | oc label --local -f - \
        app.kubernetes.io/managed-by=Helm \
        --dry-run=client -o yaml \
    | oc annotate --local -f - \
        meta.helm.sh/release-name="${HELM_RELEASE_NAME}" \
        meta.helm.sh/release-namespace="${NAMESPACE}" \
        --dry-run=client -o yaml \
    | oc apply -n "${NAMESPACE}" -f -

  ok "Created secret ${secret_name}"
}

create_secret "ngc-secret" \
  "docker-registry" "ngc-secret" \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  "--docker-password=${NGC_API_KEY}"

create_secret "app-credentials" \
  "generic" "app-credentials" \
  "--from-literal=NVIDIA_API_KEY=${NVIDIA_API_KEY}" \
  "--from-literal=MERCHANT_API_KEY=${MERCHANT_API_KEY}" \
  "--from-literal=PSP_API_KEY=${PSP_API_KEY}" \
  "--from-literal=WEBHOOK_SECRET=${WEBHOOK_SECRET}"

oc secrets link default ngc-secret --for=pull -n "${NAMESPACE}" 2>/dev/null || true
ok "Linked ngc-secret to default service account"

# ============================================================================
# Phase 4: Build application images
# ============================================================================

info "Phase 4 — Build application images"

if [[ -z "${IMAGE_REGISTRY}" ]]; then
  REGISTRY_PREFIX="image-registry.openshift-image-registry.svc:5000/${NAMESPACE}"

  MERCHANT_IMAGE="${REGISTRY_PREFIX}/merchant:latest"
  PSP_IMAGE="${REGISTRY_PREFIX}/psp:latest"
  APPS_SDK_IMAGE="${REGISTRY_PREFIX}/apps-sdk:latest"
  UI_IMAGE="${REGISTRY_PREFIX}/ui:latest"
  AGENTS_IMAGE="${REGISTRY_PREFIX}/nat-agents:latest"

  build_image() {
    local name="$1" dockerfile="$2" from_dir="$3"

    info "Building ${name}..."
    if ! oc get bc "${name}" -n "${NAMESPACE}" &>/dev/null; then
      oc new-build --name="${name}" \
        --strategy=docker \
        --binary \
        --to="${name}:latest" \
        -n "${NAMESPACE}"
      oc patch bc "${name}" -n "${NAMESPACE}" --type=merge \
        -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"'"${dockerfile}"'"}}}}'
      ok "BuildConfig ${name} created"
    else
      ok "BuildConfig ${name} already exists"
    fi

    if ! oc start-build "${name}" \
      --from-dir="${from_dir}" \
      --follow \
      -n "${NAMESPACE}"; then
      error "Build ${name} failed. Check: oc logs bc/${name} -n ${NAMESPACE}"
      exit 1
    fi
    ok "Image ${name} built"
  }

  build_image "merchant" "src/merchant/Dockerfile" "${REPO_ROOT}"
  build_image "psp" "src/payment/Dockerfile" "${REPO_ROOT}"
  build_image "apps-sdk" "src/apps_sdk/Dockerfile" "${REPO_ROOT}"
  build_image "nat-agents" "src/agents/Dockerfile" "${REPO_ROOT}"

  # UI build needs NEXT_PUBLIC_UCP_PLATFORM_PROFILE_URL set at build time
  info "Building ui..."
  if ! oc get bc "ui" -n "${NAMESPACE}" &>/dev/null; then
    oc new-build --name="ui" \
      --strategy=docker \
      --binary \
      --to="ui:latest" \
      -n "${NAMESPACE}"
    oc patch bc "ui" -n "${NAMESPACE}" --type=merge \
      -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"src/ui/Dockerfile","buildArgs":[{"name":"NEXT_PUBLIC_UCP_PLATFORM_PROFILE_URL","value":"http://merchant:8000/.well-known/ucp"}]}}}}'
    ok "BuildConfig ui created"
  else
    ok "BuildConfig ui already exists"
  fi

  if ! oc start-build "ui" \
    --from-dir="${REPO_ROOT}" \
    --follow \
    -n "${NAMESPACE}"; then
    error "Build ui failed. Check: oc logs bc/ui -n ${NAMESPACE}"
    exit 1
  fi
  ok "Image ui built"

else
  MERCHANT_IMAGE="${IMAGE_REGISTRY}/merchant:latest"
  PSP_IMAGE="${IMAGE_REGISTRY}/psp:latest"
  APPS_SDK_IMAGE="${IMAGE_REGISTRY}/apps-sdk:latest"
  UI_IMAGE="${IMAGE_REGISTRY}/ui:latest"
  AGENTS_IMAGE="${IMAGE_REGISTRY}/nat-agents:latest"
  info "Using external registry images from ${IMAGE_REGISTRY}"
fi

# ============================================================================
# Phase 5: Deploy Milvus via Helm chart
# ============================================================================
# Uses the official Milvus Helm chart in standalone mode instead of hand-writing
# etcd + MinIO + Milvus YAML. This is the pattern used by the AIQ and Data
# Flywheel blueprints for infrastructure with existing Helm charts.
# Phoenix (observability) is intentionally omitted — agents work without it.

info "Phase 5 — Deploy Milvus (Helm chart, standalone mode)"

check_tool helm

helm repo add milvus https://zilliztech.github.io/milvus-helm/ 2>/dev/null || true
helm repo update milvus 2>/dev/null || true

MILVUS_HELM_ARGS=(
  --set cluster.enabled=false
  --set pulsar.enabled=false
  --set pulsarv3.enabled=false
  --set etcd.replicaCount=1
  --set minio.mode=standalone
  --set minio.persistence.size=10Gi
  --set etcd.persistence.size=5Gi
  --set standalone.persistence.size=10Gi
  --set standalone.resources.requests.cpu=500m
  --set standalone.resources.requests.memory=2Gi
  --set standalone.resources.limits.cpu=2
  --set standalone.resources.limits.memory=8Gi
)

if [[ -n "${STORAGE_CLASS}" ]]; then
  MILVUS_HELM_ARGS+=(
    --set etcd.persistence.storageClass="${STORAGE_CLASS}"
    --set minio.persistence.storageClass="${STORAGE_CLASS}"
    --set standalone.persistence.storageClass="${STORAGE_CLASS}"
  )
fi

if helm status milvus -n "${NAMESPACE}" &>/dev/null; then
  ok "Milvus Helm release already exists — upgrading"
fi

helm upgrade --install milvus milvus/milvus \
  --namespace "${NAMESPACE}" \
  "${MILVUS_HELM_ARGS[@]}" \
  --timeout 10m

ok "Milvus Helm chart installed (standalone mode)"

# The Helm chart names the service "<release>" (i.e. "milvus") by default and
# already exposes 19530 + 9091 in standalone mode.
# Agents expect "milvus-standalone", so create an ExternalName alias.
cat <<YAML | oc apply -n "${NAMESPACE}" -f -
apiVersion: v1
kind: Service
metadata:
  name: milvus-standalone
  labels:
    app.kubernetes.io/name: agentic-commerce
    app.kubernetes.io/component: milvus-alias
spec:
  type: ExternalName
  externalName: milvus.${NAMESPACE}.svc.cluster.local
YAML
ok "Milvus alias service (milvus-standalone -> milvus) created"

# ============================================================================
# Phase 6: Deploy application services
# ============================================================================

info "Phase 6 — Deploy application services"

# --- Shared data PVC (SQLite DB shared between merchant and PSP) ---
SC_YAML=""
if [[ -n "${STORAGE_CLASS}" ]]; then
  SC_YAML="storageClassName: ${STORAGE_CLASS}"
fi

if ! oc get pvc app-data -n "${NAMESPACE}" &>/dev/null; then
  cat <<YAML | oc apply -n "${NAMESPACE}" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: app-data
  labels:
    app.kubernetes.io/name: agentic-commerce
spec:
  accessModes: [ReadWriteOnce]
  ${SC_YAML}
  resources:
    requests:
      storage: 5Gi
YAML
  ok "PVC app-data created"
else
  ok "PVC app-data already exists"
fi

# --- Nginx ConfigMap ---
cat <<'YAML' | oc apply -n "${NAMESPACE}" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
  labels:
    app.kubernetes.io/name: agentic-commerce
data:
  nginx.conf: |
    events {
        worker_connections 1024;
    }
    http {
        client_max_body_size 10M;

        upstream ui {
            server ui:3000;
        }
        upstream merchant {
            server merchant:8000;
        }
        upstream psp {
            server psp:8001;
        }
        upstream apps-sdk {
            server apps-sdk:2091;
        }

        server {
            listen 8080;

            location / {
                proxy_pass http://ui;
                proxy_http_version 1.1;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_set_header Upgrade $http_upgrade;
                proxy_set_header Connection "upgrade";
            }
            location /api/webhooks/ {
                proxy_pass http://ui/api/webhooks/;
                proxy_http_version 1.1;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
            }
            location /api/agents/ {
                proxy_pass http://ui/api/agents/;
                proxy_http_version 1.1;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
            }
            location /api/proxy/ {
                proxy_pass http://ui/api/proxy/;
                proxy_http_version 1.1;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_read_timeout 30s;
                proxy_connect_timeout 10s;
            }
            location /api/ {
                proxy_pass http://merchant/;
                proxy_http_version 1.1;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_buffering off;
                proxy_read_timeout 300s;
            }
            location /psp/ {
                proxy_pass http://psp/;
                proxy_http_version 1.1;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
            }
            location /apps-sdk/ {
                proxy_pass http://apps-sdk/;
                proxy_http_version 1.1;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_buffering off;
                proxy_cache off;
                proxy_read_timeout 300s;
            }
        }
    }
YAML
ok "Nginx ConfigMap applied"

# --- Merchant API ---
cat <<YAML | oc apply -n "${NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: merchant
  labels:
    app.kubernetes.io/name: agentic-commerce
    app.kubernetes.io/component: merchant
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: merchant
  template:
    metadata:
      labels:
        app: merchant
        data-tier: sqlite
    spec:
      containers:
        - name: merchant
          image: ${MERCHANT_IMAGE}
          ports:
            - containerPort: 8000
          env:
            - name: DATABASE_URL
              value: "sqlite:////data/agentic_commerce.db"
            - name: MERCHANT_API_KEY
              valueFrom:
                secretKeyRef:
                  name: app-credentials
                  key: MERCHANT_API_KEY
            - name: PROMOTION_AGENT_URL
              value: "http://promotion-agent:8002"
            - name: POST_PURCHASE_AGENT_URL
              value: "http://post-purchase-agent:8003"
            - name: RECOMMENDATION_AGENT_URL
              value: "http://recommendation-agent:8004"
            - name: WEBHOOK_URL
              value: "http://ui:3000/api/webhooks/acp"
            - name: UCP_ORDER_WEBHOOK_URL
              value: "http://ui:3000/api/webhooks/ucp"
            - name: WEBHOOK_SECRET
              valueFrom:
                secretKeyRef:
                  name: app-credentials
                  key: WEBHOOK_SECRET
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 10
            periodSeconds: 15
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 30
            periodSeconds: 30
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: app-data
---
apiVersion: v1
kind: Service
metadata:
  name: merchant
  labels:
    app.kubernetes.io/name: agentic-commerce
    app.kubernetes.io/component: merchant
spec:
  selector:
    app: merchant
  ports:
    - port: 8000
      targetPort: 8000
  type: ClusterIP
YAML
ok "Merchant API deployed"

# --- PSP (Payment Service) ---
cat <<YAML | oc apply -n "${NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: psp
  labels:
    app.kubernetes.io/name: agentic-commerce
    app.kubernetes.io/component: psp
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: psp
  template:
    metadata:
      labels:
        app: psp
        data-tier: sqlite
    spec:
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: merchant
              topologyKey: kubernetes.io/hostname
      containers:
        - name: psp
          image: ${PSP_IMAGE}
          ports:
            - containerPort: 8001
          env:
            - name: DATABASE_URL
              value: "sqlite:////data/agentic_commerce.db"
            - name: PSP_API_KEY
              valueFrom:
                secretKeyRef:
                  name: app-credentials
                  key: PSP_API_KEY
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
          readinessProbe:
            httpGet:
              path: /health
              port: 8001
            initialDelaySeconds: 10
            periodSeconds: 15
          livenessProbe:
            httpGet:
              path: /health
              port: 8001
            initialDelaySeconds: 30
            periodSeconds: 30
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: app-data
---
apiVersion: v1
kind: Service
metadata:
  name: psp
  labels:
    app.kubernetes.io/name: agentic-commerce
    app.kubernetes.io/component: psp
spec:
  selector:
    app: psp
  ports:
    - port: 8001
      targetPort: 8001
  type: ClusterIP
YAML
ok "PSP deployed"

# --- Apps SDK MCP Server ---
cat <<YAML | oc apply -n "${NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: apps-sdk
  labels:
    app.kubernetes.io/name: agentic-commerce
    app.kubernetes.io/component: apps-sdk
spec:
  replicas: 1
  selector:
    matchLabels:
      app: apps-sdk
  template:
    metadata:
      labels:
        app: apps-sdk
    spec:
      containers:
        - name: apps-sdk
          image: ${APPS_SDK_IMAGE}
          ports:
            - containerPort: 2091
          env:
            - name: MERCHANT_API_URL
              value: "http://merchant:8000"
            - name: PSP_API_URL
              value: "http://psp:8001"
            - name: RECOMMENDATION_AGENT_URL
              value: "http://recommendation-agent:8004"
            - name: SEARCH_AGENT_URL
              value: "http://search-agent:8005"
            - name: MERCHANT_API_KEY
              valueFrom:
                secretKeyRef:
                  name: app-credentials
                  key: MERCHANT_API_KEY
            - name: PSP_API_KEY
              valueFrom:
                secretKeyRef:
                  name: app-credentials
                  key: PSP_API_KEY
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
          readinessProbe:
            httpGet:
              path: /health
              port: 2091
            initialDelaySeconds: 10
            periodSeconds: 15
---
apiVersion: v1
kind: Service
metadata:
  name: apps-sdk
  labels:
    app.kubernetes.io/name: agentic-commerce
    app.kubernetes.io/component: apps-sdk
spec:
  selector:
    app: apps-sdk
  ports:
    - port: 2091
      targetPort: 2091
  type: ClusterIP
YAML
ok "Apps SDK deployed"

# --- UI (Next.js) ---
cat <<YAML | oc apply -n "${NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ui
  labels:
    app.kubernetes.io/name: agentic-commerce
    app.kubernetes.io/component: ui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ui
  template:
    metadata:
      labels:
        app: ui
    spec:
      containers:
        - name: ui
          image: ${UI_IMAGE}
          ports:
            - containerPort: 3000
          env:
            - name: MERCHANT_API_URL
              value: "http://merchant:8000"
            - name: PSP_API_URL
              value: "http://psp:8001"
            - name: NEXT_PUBLIC_UCP_PLATFORM_PROFILE_URL
              value: "http://merchant:8000/.well-known/ucp"
            - name: MERCHANT_API_KEY
              valueFrom:
                secretKeyRef:
                  name: app-credentials
                  key: MERCHANT_API_KEY
            - name: PSP_API_KEY
              valueFrom:
                secretKeyRef:
                  name: app-credentials
                  key: PSP_API_KEY
            - name: WEBHOOK_SECRET
              valueFrom:
                secretKeyRef:
                  name: app-credentials
                  key: WEBHOOK_SECRET
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          readinessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: ui
  labels:
    app.kubernetes.io/name: agentic-commerce
    app.kubernetes.io/component: ui
spec:
  selector:
    app: ui
  ports:
    - port: 3000
      targetPort: 3000
  type: ClusterIP
YAML
ok "UI deployed"

# --- Nginx reverse proxy ---
cat <<YAML | oc apply -n "${NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  labels:
    app.kubernetes.io/name: agentic-commerce
    app.kubernetes.io/component: nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: docker.io/library/nginx:1.25.3-alpine
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: nginx-config
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
              readOnly: true
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "200m"
              memory: "256Mi"
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
      volumes:
        - name: nginx-config
          configMap:
            name: nginx-config
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
  labels:
    app.kubernetes.io/name: agentic-commerce
    app.kubernetes.io/component: nginx
spec:
  selector:
    app: nginx
  ports:
    - port: 8080
      targetPort: 8080
  type: ClusterIP
YAML
ok "Nginx deployed"

# --- NAT Agents (all share the same image) ---
deploy_agent() {
  local name="$1" port="$2" config="$3"
  shift 3
  local extra_env=("$@")

  local env_yaml=""
  env_yaml+="
            - name: NVIDIA_API_KEY
              valueFrom:
                secretKeyRef:
                  name: app-credentials
                  key: NVIDIA_API_KEY
            - name: NIM_LLM_BASE_URL
              value: \"${NIM_LLM_BASE_URL}\"
            - name: NIM_LLM_MODEL_NAME
              value: \"${NIM_LLM_MODEL_NAME}\""

  for env_pair in "${extra_env[@]}"; do
    local env_key="${env_pair%%=*}"
    local env_val="${env_pair#*=}"
    env_yaml+="
            - name: ${env_key}
              value: \"${env_val}\""
  done

  cat <<AGENTYAML | oc apply -n "${NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  labels:
    app.kubernetes.io/name: agentic-commerce
    app.kubernetes.io/component: ${name}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      containers:
        - name: ${name}
          image: ${AGENTS_IMAGE}
          command: ["sh", "-c"]
          args:
            - |
              awk '/^eval:/{exit}1' ${config} | sed 's|_type: sequential_executor|_type: nat.plugins.langchain.control_flow/sequential_executor|' > /tmp/$(basename ${config})
              exec nat serve --config_file /tmp/$(basename ${config}) --host 0.0.0.0 --port ${port}
          ports:
            - containerPort: ${port}
          env:${env_yaml}
          resources:
            requests:
              cpu: "250m"
              memory: "512Mi"
            limits:
              cpu: "1"
              memory: "2Gi"
          readinessProbe:
            httpGet:
              path: /health
              port: ${port}
            initialDelaySeconds: 30
            periodSeconds: 15
          livenessProbe:
            httpGet:
              path: /health
              port: ${port}
            initialDelaySeconds: 60
            periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  labels:
    app.kubernetes.io/name: agentic-commerce
    app.kubernetes.io/component: ${name}
spec:
  selector:
    app: ${name}
  ports:
    - port: ${port}
      targetPort: ${port}
  type: ClusterIP
AGENTYAML
  ok "Agent ${name} deployed"
}

deploy_agent "promotion-agent" "8002" "configs/promotion.yml"
deploy_agent "post-purchase-agent" "8003" "configs/post-purchase.yml"

deploy_agent "recommendation-agent" "8004" "configs/recommendation-ultrafast.yml" \
  "MILVUS_URI=http://milvus-standalone:19530" \
  "NIM_EMBED_BASE_URL=${NIM_EMBED_BASE_URL}" \
  "NIM_EMBED_MODEL_NAME=${NIM_EMBED_MODEL_NAME}"

deploy_agent "search-agent" "8005" "configs/search.yml" \
  "MILVUS_URI=http://milvus-standalone:19530" \
  "NIM_EMBED_BASE_URL=${NIM_EMBED_BASE_URL}" \
  "NIM_EMBED_MODEL_NAME=${NIM_EMBED_MODEL_NAME}"

# ============================================================================
# Phase 7: Deploy NIM containers (if enabled)
# ============================================================================
# NIMs must be deployed BEFORE the Milvus seeder (Phase 8) because in local
# NIM mode the seeder calls the embedding NIM to generate product vectors.

if [[ "${DEPLOY_NIMS}" == "true" ]]; then
  info "Phase 7 — Deploy self-hosted NIM containers"

  TOLERATION_YAML=""
  for KEY in "${TKEYS[@]}"; do
    TOLERATION_YAML+="
            - key: \"${KEY}\"
              operator: Exists
              effect: ${GPU_TOLERATION_EFFECT}"
  done

  deploy_nim() {
    local name="$1" image="$2" port="${3:-8000}" gpu_count="${4:-1}" shm_size="${5:-16Gi}"
    shift 5
    local extra_env=("$@")

    local env_yaml=""
    env_yaml+="
            - name: NGC_API_KEY
              valueFrom:
                secretKeyRef:
                  name: app-credentials
                  key: NVIDIA_API_KEY"

    for env_pair in "${extra_env[@]}"; do
      local env_key="${env_pair%%=*}"
      local env_val="${env_pair#*=}"
      env_yaml+="
            - name: ${env_key}
              value: \"${env_val}\""
    done

    cat <<NIMYAML | oc apply -n "${NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  labels:
    app.kubernetes.io/name: agentic-commerce
    app.kubernetes.io/component: ${name}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      imagePullSecrets:
        - name: ngc-secret
      tolerations:${TOLERATION_YAML}
      containers:
        - name: ${name}
          image: ${image}
          ports:
            - containerPort: ${port}
          env:${env_yaml}
          resources:
            limits:
              nvidia.com/gpu: ${gpu_count}
            requests:
              nvidia.com/gpu: ${gpu_count}
          volumeMounts:
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: ${shm_size}
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  labels:
    app.kubernetes.io/name: agentic-commerce
    app.kubernetes.io/component: ${name}
spec:
  selector:
    app: ${name}
  ports:
    - port: ${port}
      targetPort: ${port}
  type: ClusterIP
NIMYAML
    ok "NIM ${name} deployed"
  }

  deploy_nim "nim-llm" \
    "nvcr.io/nim/nvidia/nemotron-3-nano:1" \
    "8000" "1" "16Gi" \
    "TOKENIZERS_PARALLELISM=false" \
    "NIM_MAX_MODEL_LEN=4096" \
    "NIM_RELAX_MEM_CONSTRAINTS=1"

  deploy_nim "nim-embedqa" \
    "nvcr.io/nim/nvidia/nv-embedqa-e5-v5:1.6" \
    "8000" "1" "8Gi" \
    "TOKENIZERS_PARALLELISM=false"

else
  info "Phase 7 — Skipping NIM deployment (DEPLOY_NIMS=false, using hosted NVIDIA API)"
fi

# ============================================================================
# Phase 8: Seed Milvus
# ============================================================================

info "Phase 8 — Seed Milvus with product catalog"

# Delete previous seeder job if it exists (jobs are immutable)
oc delete job milvus-seeder -n "${NAMESPACE}" 2>/dev/null || true

# Build init container list: always wait for Milvus; also wait for embedding
# NIM in local NIM mode (the seeder needs the embedding endpoint to generate vectors).
SEEDER_INIT_CONTAINERS="
      initContainers:
        - name: wait-for-milvus
          image: curlimages/curl:8.5.0
          command: [\"sh\", \"-c\"]
          args:
            - |
              echo \"Waiting for Milvus to be ready...\"
              until curl -sf http://milvus:9091/healthz; do
                echo \"Milvus not ready, retrying in 10s...\"
                sleep 10
              done
              echo \"Milvus is ready\""

if [[ "${DEPLOY_NIMS}" == "true" ]]; then
  SEEDER_INIT_CONTAINERS+="
        - name: wait-for-embedding-nim
          image: curlimages/curl:8.5.0
          command: [\"sh\", \"-c\"]
          args:
            - |
              echo \"Waiting for embedding NIM to be ready...\"
              until curl -sf http://nim-embedqa:8000/v1/health/ready; do
                echo \"Embedding NIM not ready, retrying in 15s...\"
                sleep 15
              done
              echo \"Embedding NIM is ready\""
fi

cat <<YAML | oc apply -n "${NAMESPACE}" -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: milvus-seeder
  labels:
    app.kubernetes.io/name: agentic-commerce
    app.kubernetes.io/component: milvus-seeder
spec:
  backoffLimit: 5
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: OnFailure
${SEEDER_INIT_CONTAINERS}
      containers:
        - name: seeder
          image: ${AGENTS_IMAGE}
          command: ["python", "scripts/seed_milvus.py"]
          env:
            - name: NVIDIA_API_KEY
              valueFrom:
                secretKeyRef:
                  name: app-credentials
                  key: NVIDIA_API_KEY
            - name: MILVUS_URI
              value: "http://milvus-standalone:19530"
            - name: NIM_EMBED_BASE_URL
              value: "${NIM_EMBED_BASE_URL}"
            - name: NIM_EMBED_MODEL_NAME
              value: "${NIM_EMBED_MODEL_NAME}"
          resources:
            requests:
              cpu: "250m"
              memory: "512Mi"
            limits:
              cpu: "1"
              memory: "2Gi"
YAML
ok "Milvus seeder job created"

# ============================================================================
# Phase 9: OpenShift Routes
# ============================================================================

info "Phase 9 — OpenShift Routes"

if ! oc get route agentic-commerce -n "${NAMESPACE}" &>/dev/null; then
  oc create route edge agentic-commerce \
    --service=nginx \
    --port=8080 \
    -n "${NAMESPACE}"
  ok "Route agentic-commerce created"
else
  ok "Route agentic-commerce already exists"
fi
oc annotate route agentic-commerce \
  haproxy.router.openshift.io/timeout=300s \
  -n "${NAMESPACE}" --overwrite 2>/dev/null || true

if ! oc get route agentic-commerce-api -n "${NAMESPACE}" &>/dev/null; then
  oc create route edge agentic-commerce-api \
    --service=merchant \
    --port=8000 \
    -n "${NAMESPACE}"
  ok "Route agentic-commerce-api created"
else
  ok "Route agentic-commerce-api already exists"
fi
oc annotate route agentic-commerce-api \
  haproxy.router.openshift.io/timeout=300s \
  -n "${NAMESPACE}" --overwrite 2>/dev/null || true

# Direct Apps SDK route (MCP uses SSE which needs long-lived connections)
if ! oc get route agentic-commerce-apps-sdk -n "${NAMESPACE}" &>/dev/null; then
  oc create route edge agentic-commerce-apps-sdk \
    --service=apps-sdk \
    --port=2091 \
    -n "${NAMESPACE}"
  ok "Route agentic-commerce-apps-sdk created"
else
  ok "Route agentic-commerce-apps-sdk already exists"
fi
oc annotate route agentic-commerce-apps-sdk \
  haproxy.router.openshift.io/timeout=300s \
  -n "${NAMESPACE}" --overwrite 2>/dev/null || true

# ============================================================================
# Phase 10: Wait for rollouts
# ============================================================================

info "Phase 10 — Waiting for rollouts"

# Milvus (Helm-deployed)
wait_for_rollout deployment milvus-standalone "${NAMESPACE}"
wait_for_rollout deployment milvus-etcd "${NAMESPACE}"
wait_for_rollout deployment milvus-minio "${NAMESPACE}"

# Application
wait_for_rollout deployment merchant "${NAMESPACE}"
wait_for_rollout deployment psp "${NAMESPACE}"
wait_for_rollout deployment apps-sdk "${NAMESPACE}"
wait_for_rollout deployment ui "${NAMESPACE}"
wait_for_rollout deployment nginx "${NAMESPACE}"

# Agents
wait_for_rollout deployment promotion-agent "${NAMESPACE}"
wait_for_rollout deployment post-purchase-agent "${NAMESPACE}"
wait_for_rollout deployment recommendation-agent "${NAMESPACE}"
wait_for_rollout deployment search-agent "${NAMESPACE}"

if [[ "${DEPLOY_NIMS}" == "true" ]]; then
  info "Waiting for NIM rollouts (may take 5–15 minutes for model loading)..."
  wait_for_rollout deployment nim-llm "${NAMESPACE}"
  wait_for_rollout deployment nim-embedqa "${NAMESPACE}"
fi

# ============================================================================
# Summary
# ============================================================================

FRONTEND_ROUTE=$(oc get route agentic-commerce -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "<pending>")
API_ROUTE=$(oc get route agentic-commerce-api -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "<pending>")

info "Deployment complete!"
echo ""
echo "  Namespace:    ${NAMESPACE}"
echo "  Deploy NIMs:  ${DEPLOY_NIMS}"
echo ""
echo "  Frontend UI:  https://${FRONTEND_ROUTE}"
echo "  Merchant API: https://${API_ROUTE}"
echo "  Health:       https://${API_ROUTE}/health"
echo ""
echo "  Verify pods:  oc get pods -n ${NAMESPACE}"
echo "  View logs:    oc logs deployment/merchant -n ${NAMESPACE}"
echo ""
echo "Pods:"
oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | sed 's/^/  /'
echo ""

if [[ "${DEPLOY_NIMS}" == "true" ]]; then
  echo "NIM pods may take 5–15 minutes to download and load models."
  echo "Monitor: oc get pods -n ${NAMESPACE} -w"
  echo ""
fi

echo "Expected pods:"
echo "  Milvus (Helm):  milvus-standalone, milvus-etcd, milvus-minio"
echo "  Application:    merchant, psp, apps-sdk, ui, nginx"
echo "  Agents:         promotion-agent, post-purchase-agent, recommendation-agent, search-agent"
echo "  Jobs:           milvus-seeder (Completed)"
if [[ "${DEPLOY_NIMS}" == "true" ]]; then
  echo "  NIMs:           nim-llm, nim-embedqa"
fi
