# Deploying Retail Agentic Commerce on Red Hat OpenShift AI

This guide walks through deploying the **Retail Agentic Commerce Blueprint** on a Red Hat OpenShift or OpenShift AI (RHOAI) cluster. It covers architecture, hardware requirements, configuration, deployment, verification, and every OpenShift-specific challenge encountered during validation.

All OpenShift-specific files are isolated in the `openshift/` directory — no upstream files are permanently modified. Only `README.md` is updated with a link to this guide.

---

## Table of Contents

1. [What We're Deploying](#1-what-were-deploying)
2. [Tested Hardware](#2-tested-hardware)
3. [What's Different from Upstream](#3-whats-different-from-upstream)
4. [Prerequisites](#4-prerequisites)
5. [Configuration Reference](#5-configuration-reference)
6. [Deployment](#6-deployment)
7. [Verification](#7-verification)
8. [Accessing the UI](#8-accessing-the-ui)
9. [Testing and Data Ingestion](#9-testing-and-data-ingestion)
10. [OpenShift-Specific Challenges and Solutions](#10-openshift-specific-challenges-and-solutions)
11. [Cleanup](#11-cleanup)
12. [Deployment Files](#12-deployment-files)

---

## 1. What We're Deploying

The Retail Agentic Commerce Blueprint is a reference implementation of two open commerce protocols — **ACP** (Agentic Commerce Protocol) and **UCP** (Universal Commerce Protocol) — that let AI agents browse products, negotiate promotions, handle payments, and complete checkouts on behalf of users. It consists of a FastAPI backend, a Next.js frontend, four specialized NeMo Agent Toolkit (NAT) agents, and supporting infrastructure.

### Component Summary

| Component | Service Name | Image | GPU | Purpose |
|-----------|-------------|-------|-----|---------|
| Merchant API | `merchant` | Custom (built from `src/merchant/Dockerfile`) | — | Core backend: checkout sessions, ACP/UCP endpoints, agent orchestration |
| Payment Service (PSP) | `psp` | Custom (built from `src/payment/Dockerfile`) | — | Simulated payment processor: vault tokens, payment intents, 3DS auth |
| Apps SDK MCP Server | `apps-sdk` | Custom (built from `src/apps_sdk/Dockerfile`) | — | MCP tool server + embedded React widget for ChatGPT-style integration |
| Frontend UI | `ui` | Custom (built from `src/ui/Dockerfile`) | — | Next.js three-panel protocol inspector: client agent, merchant activity, agent traces |
| Nginx Proxy | `nginx` | `nginx:1.25.3-alpine` | — | Reverse proxy routing `/api/` → merchant, `/psp/` → PSP, `/apps-sdk/` → SDK, `/*` → UI |
| Promotion Agent | `promotion-agent` | Custom (built from `src/agents/Dockerfile`) | — | Analyzes pricing, competitor data, generates discount codes |
| Post-Purchase Agent | `post-purchase-agent` | *(shared agents image)* | — | Shipping updates, return handling, multilingual (EN/ES/FR) |
| Recommendation Agent | `recommendation-agent` | *(shared agents image)* | — | ARAG-style pipeline using Milvus vector search for product similarity |
| Search Agent | `search-agent` | *(shared agents image)* | — | Product search and filtering via Milvus |
| Milvus Seeder | `milvus-seeder` | *(shared agents image)* | — | One-shot Job that seeds product catalog embeddings into Milvus |
| Milvus *(Helm chart)* | `milvus-standalone`, `milvus-etcd`, `milvus-minio` | `milvusdb/milvus` (chart default) | — | Vector database for product embeddings (standalone mode via official Helm chart) |
| LLM NIM *(optional)* | `nim-llm` | `nvcr.io/nim/nvidia/nemotron-3-nano:1` | 1 | Self-hosted LLM for agent reasoning (replaces hosted API) |
| Embedding NIM *(optional)* | `nim-embedqa` | `nvcr.io/nim/nvidia/nv-embedqa-e5-v5:1.6` | 1 | Self-hosted embedding model for vector search |

### Data Flow

```
User → Frontend (Next.js)
  → Nginx reverse proxy
    → Merchant API (FastAPI)
      → Promotion Agent → LLM NIM (cloud or local)
      → Recommendation Agent → Embedding NIM + Milvus
      → Search Agent → Embedding NIM + Milvus
    → PSP (payment delegation → vault token → complete)
    → Post-Purchase Agent → LLM NIM (webhooks back to UI)
  ← Results displayed in three-panel inspector UI
```

### Total Resource Count

| Mode | Pods | GPUs | Notes |
|------|------|------|-------|
| Cloud API (default) | 14 | 0 | All LLM/embedding calls via NVIDIA hosted API (build.nvidia.com) |
| Local NIM | 16 | 2 | Self-hosted Nemotron-3-Nano LLM + EmbedQA embedding model |

> **Note:** The Milvus seeder runs as a one-shot Job and transitions to `Completed` status after seeding.

---

## 2. Tested Hardware

### Cluster Configuration

| Node Role | Instance Type | GPU | VRAM | Count |
|-----------|--------------|-----|------|-------|
| GPU Worker | AWS g6.xlarge | L4 | 24 GB | 2 (local NIM mode only) |
| CPU Worker | AWS m5.2xlarge | — | — | 3 |
| Control Plane | AWS m5.xlarge | — | — | 3 |

- **OpenShift version**: 4.17+
- **GPU Operator**: NVIDIA GPU Operator v24.9+
- **Total GPUs used**: 0 (cloud API mode) or 2 (local NIM mode)

### Minimum Requirements for Reproduction

**Cloud API mode (0 GPUs):**
- 3 CPU worker nodes with at least 4 vCPU and 16 GB RAM each
- 50 GB disk for PVCs (Milvus, MinIO, etcd, app data)
- Network access to `integrate.api.nvidia.com` and `build.nvidia.com`

**Local NIM mode (2 GPUs):**
- Everything above, plus:
- 1 GPU with >= 48 GB VRAM for LLM NIM (L40S, H100). A100-40GB does NOT work for Nemotron-3-Nano — see [Challenge 14](#challenge-14-nemotron-3-nano-30b-does-not-fit-on-a100-40gb).
- 1 GPU with >= 8 GB VRAM for embedding NIM (any NVIDIA GPU)

### API Keys Required

| Key | Source | Purpose |
|-----|--------|---------|
| `NVIDIA_API_KEY` | [build.nvidia.com](https://build.nvidia.com/) | LLM and embedding API calls (cloud mode) and agent authentication |
| `NGC_API_KEY` | [org.ngc.nvidia.com](https://org.ngc.nvidia.com/setup/api-keys) | Pull NIM container images from nvcr.io (local NIM mode only) |

---

## 3. What's Different from Upstream

The upstream blueprint uses Docker Compose. This deployment adapts it for OpenShift with the following trade-offs:

| Area | Upstream (Docker Compose) | OpenShift Deployment | Impact |
|------|--------------------------|---------------------|--------|
| File isolation | All files in repo root | All OpenShift files in `openshift/` dir | No merge conflicts on upstream sync |
| Service networking | Docker bridge network | ClusterIP + OpenShift Routes (TLS) | Routes provide HTTPS automatically |
| Image build | `docker build` with Compose | OpenShift BuildConfig (binary strategy) | No Docker daemon required on cluster |
| Reverse proxy port | Nginx on port 80 | Nginx on port 8080 | Avoids privileged port binding under restricted SCC |
| Secrets | `.env` file on host | Kubernetes Secrets with Helm ownership labels | Encrypted at rest, RBAC-controlled |
| Shared database | Docker volume shared between containers | RWO PVC + pod affinity for co-location | Ensures merchant and PSP access same SQLite file |
| GPU scheduling | `device_ids` in Compose | Kubernetes `nvidia.com/gpu` + tolerations | GPU Operator handles scheduling |
| Shared memory | `shm_size: 16gb` | `emptyDir` with `medium: Memory` | Equivalent behavior, Kubernetes-native |
| Milvus seeder | `restart: "no"` container | Kubernetes Job with init container | Waits for Milvus health before seeding |
| Agent images | All built from single Dockerfile | Single BuildConfig, multiple Deployments with different commands | Same image, different `nat serve` configs |
| Observability | Phoenix on host port 6006 | Omitted (optional, agents work without it) | Add separately if needed |
| LLM inference | Defaults to NVIDIA hosted API | Same default; optional local NIM mode | Identical behavior in cloud mode |

---

## 4. Prerequisites

### CLI Tools

| Tool | Minimum Version | Install |
|------|----------------|---------|
| `oc` | 4.17+ | [docs.openshift.com](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html) |

### Cluster Requirements

- OpenShift 4.17+ with cluster-admin access
- NVIDIA GPU Operator installed (only for local NIM mode)
- Internal image registry accessible (or set `IMAGE_REGISTRY` for external)

### GPU Availability Check (Local NIM Mode Only)

```bash
# Verify GPU nodes exist
oc get nodes -l nvidia.com/gpu.present=true

# Check allocatable GPU capacity
oc describe node <gpu-node-name> | grep -A5 "Allocatable"

# Check GPU taint keys (needed for GPU_TOLERATION_KEYS)
oc describe node <gpu-node-name> | grep Taints
```

### Resource Requirements

| Component | CPU Request | Memory Request | CPU Limit | Memory Limit | GPU |
|-----------|-----------|---------------|-----------|-------------|-----|
| Merchant | 250m | 256Mi | 1 | 1Gi | — |
| PSP | 250m | 256Mi | 1 | 1Gi | — |
| Apps SDK | 250m | 256Mi | 1 | 1Gi | — |
| UI | 100m | 128Mi | 500m | 512Mi | — |
| Nginx | 50m | 64Mi | 200m | 256Mi | — |
| Each NAT Agent (×4) | 250m | 512Mi | 1 | 2Gi | — |
| Milvus *(Helm)* | 500m | 2Gi | 2 | 8Gi | — |
| etcd *(Helm sub-chart)* | Chart default | Chart default | Chart default | Chart default | — |
| MinIO *(Helm sub-chart)* | Chart default | Chart default | Chart default | Chart default | — |
| LLM NIM *(optional)* | — | — | — | — | 1 (48GB+) |
| Embedding NIM *(optional)* | — | — | — | — | 1 (8GB+) |

**Total (cloud API mode):** ~3.0 vCPU requests, ~6.0 Gi memory requests across 13 pods (excluding Helm sub-chart defaults).

---

## 5. Configuration Reference

### Required Environment Variables

| Variable | Description |
|----------|-------------|
| `NVIDIA_API_KEY` | NVIDIA API key for hosted NIM inference and agent LLM calls. Get one at [build.nvidia.com](https://build.nvidia.com/) |

### Optional Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NAMESPACE` | `agentic-commerce` | OpenShift namespace for the deployment |
| `DEPLOY_NIMS` | `false` | Set to `true` to deploy self-hosted NIM containers (requires GPUs) |
| `NGC_API_KEY` | `$NVIDIA_API_KEY` | NGC key for pulling NIM images from nvcr.io. Only needed when `DEPLOY_NIMS=true` |
| `STORAGE_CLASS` | *(cluster default)* | StorageClass for PVCs |
| `GPU_TOLERATION_KEYS` | `auto` | Taint keys for GPU nodes. `auto` detects from cluster. Set manually if needed (e.g., `g6-gpu,p4-gpu`) |
| `IMAGE_REGISTRY` | *(empty — uses OpenShift internal)* | External container registry for pre-built images |
| `ROLLOUT_TIMEOUT` | `600` | Seconds to wait for each deployment rollout |
| `MERCHANT_API_KEY` | `merchant-api-key-12345` | API key for clients calling merchant endpoints |
| `PSP_API_KEY` | `psp-api-key-12345` | API key for PSP authentication |
| `WEBHOOK_SECRET` | `whsec_demo_secret` | Webhook signature secret for post-purchase notifications |
| `NIM_LLM_BASE_URL` | *(auto-set by mode)* | LLM endpoint URL |
| `NIM_LLM_MODEL_NAME` | *(auto-set by mode)* | LLM model name |
| `NIM_EMBED_BASE_URL` | *(auto-set by mode)* | Embedding endpoint URL |
| `NIM_EMBED_MODEL_NAME` | *(auto-set by mode)* | Embedding model name |

---

## 6. Deployment

### Single Command (Cloud API — No GPUs)

```bash
NVIDIA_API_KEY=nvapi-... \
  bash openshift/deploy/helm/deploy-openshift.sh
```

### Local NIM Mode (2 GPUs)

```bash
NVIDIA_API_KEY=nvapi-... \
NGC_API_KEY=nvapi-... \
DEPLOY_NIMS=true \
  bash openshift/deploy/helm/deploy-openshift.sh
```

### What the Script Does

The deploy script executes 10 phases:

1. **Pre-flight checks** — Verifies `oc` is installed, confirms cluster login. In NIM mode, checks for GPU nodes and auto-detects taint keys.

2. **Namespace and SCC** — Creates the namespace (or reuses existing). Grants `anyuid` SCC to the `default` service account. This must happen before any pods start.

3. **Secrets** — Creates `ngc-secret` (image pull for nvcr.io) and `app-credentials` (NVIDIA_API_KEY, MERCHANT_API_KEY, PSP_API_KEY, WEBHOOK_SECRET) with Helm ownership labels.

4. **Build application images** — Uses OpenShift BuildConfigs with Docker strategy to build 5 images from source: merchant, psp, apps-sdk, ui, nat-agents. All builds use the repo root as context. If `IMAGE_REGISTRY` is set, skips builds and uses pre-built images.

5. **Deploy Milvus (Helm chart)** — Uses the official Milvus Helm chart (`milvus/milvus`) in standalone mode. This replaces hand-written etcd + MinIO + Milvus YAML with a maintained chart, following the pattern used by the AIQ and Data Flywheel blueprints. Phoenix is intentionally omitted — agents work without it.

6. **Deploy application** — Creates merchant, PSP, Apps SDK, UI, nginx, and all 4 NAT agents as Deployments with Services. Merchant and PSP share a RWO PVC for SQLite, with pod affinity ensuring co-location.

7. **Deploy NIM containers** — If `DEPLOY_NIMS=true`, creates Deployments and Services for the LLM (Nemotron-3-Nano) and embedding (EmbedQA) NIMs with GPU requests, tolerations, shared memory, and `TOKENIZERS_PARALLELISM=false`. Must happen before Milvus seeding because the seeder needs the embedding endpoint in local NIM mode.

8. **Seed Milvus** — Creates a Kubernetes Job with init containers that wait for Milvus to be healthy (and for the embedding NIM in local NIM mode), then runs `seed_milvus.py` to populate product catalog embeddings.

9. **Routes** — Creates three OpenShift Routes with edge TLS and 300s timeout annotations: `agentic-commerce` (through nginx for full app), `agentic-commerce-api` (direct to merchant for testing), and `agentic-commerce-apps-sdk` (direct to MCP server for SSE connections).

10. **Rollout wait** — Waits for all deployments to become ready and prints a summary with pod status and route URLs.

---

## 7. Verification

### Check All Pods

```bash
oc get pods -n agentic-commerce
```

**Expected output (cloud API mode — 14 pods):**

```
NAME                                    READY   STATUS      RESTARTS   AGE
merchant-xxxxxxxxx-xxxxx                1/1     Running     0          5m
psp-xxxxxxxxx-xxxxx                     1/1     Running     0          5m
apps-sdk-xxxxxxxxx-xxxxx                1/1     Running     0          5m
ui-xxxxxxxxx-xxxxx                      1/1     Running     0          5m
nginx-xxxxxxxxx-xxxxx                   1/1     Running     0          5m
promotion-agent-xxxxxxxxx-xxxxx         1/1     Running     0          5m
post-purchase-agent-xxxxxxxxx-xxxxx     1/1     Running     0          5m
recommendation-agent-xxxxxxxxx-xxxxx    1/1     Running     0          5m
search-agent-xxxxxxxxx-xxxxx            1/1     Running     0          5m
milvus-standalone-xxxxxxxxx-xxxxx         1/1     Running     0          5m
milvus-etcd-x                            1/1     Running     0          5m
milvus-minio-xxxxxxxxx-xxxxx             1/1     Running     0          5m
milvus-seeder-xxxxx                      0/1     Completed   0          3m
```

### Health Checks

```bash
# Get route hostname
API_HOST=$(oc get route agentic-commerce-api -n agentic-commerce -o jsonpath='{.spec.host}')

# Merchant health
curl -s "https://${API_HOST}/health"
# Expected: {"status":"healthy"}

# PSP health (via nginx route)
FRONTEND_HOST=$(oc get route agentic-commerce -n agentic-commerce -o jsonpath='{.spec.host}')
curl -s "https://${FRONTEND_HOST}/psp/health"

# Check agent health from inside the merchant pod
oc exec deployment/merchant -n agentic-commerce -- \
  python -c "
import urllib.request as u
for name, port in [('promotion',8002),('post-purchase',8003),('recommendation',8004),('search',8005)]:
    try:
        status = u.urlopen(f'http://{name}-agent:{port}/health', timeout=5).status
        print(f'{name}: {status}')
    except Exception as e:
        print(f'{name}: FAILED ({e})')
"
```

### Check Milvus Seeder Job

```bash
# Verify seeder completed successfully
oc get job milvus-seeder -n agentic-commerce
# Expected: COMPLETIONS 1/1

# Check seeder logs
oc logs job/milvus-seeder -n agentic-commerce -c seeder
```

---

## 8. Accessing the UI

```bash
# Get the frontend URL
oc get route agentic-commerce -n agentic-commerce -o jsonpath='https://{.spec.host}{"\n"}'

# Get the direct API URL (for curl/Postman testing)
oc get route agentic-commerce-api -n agentic-commerce -o jsonpath='https://{.spec.host}{"\n"}'
```

Open the frontend URL in your browser. The UI provides a three-panel layout:

- **Client Agent Panel** (left): Product selection, checkout flow simulation, and Apps SDK mode
- **Merchant Server Panel** (center): Protocol events (ACP and UCP tabs), session state, webhook logs
- **Agent Activity Panel** (right): Promotion reasoning, recommendation traces, search results

---

## 9. Testing and Data Ingestion

Pods being `Running` does **not** mean the pipeline works end-to-end. This section validates actual functionality through the complete checkout flow.

### Step 1: Verify Agent Health

Wait for all 4 agents to report healthy:

```bash
API_HOST=$(oc get route agentic-commerce-api -n agentic-commerce -o jsonpath='{.spec.host}')

# Poll until merchant is ready
curl -s "https://${API_HOST}/health"
```

Then check agents from inside the cluster:

```bash
oc exec deployment/merchant -n agentic-commerce -- \
  python -c "
import urllib.request as u
for name, port in [('promotion',8002),('post-purchase',8003),('recommendation',8004),('search',8005)]:
    try: print(f'{name}: {u.urlopen(f\"http://{name}-agent:{port}/health\", timeout=5).status}')
    except Exception as e: print(f'{name}: FAILED ({e})')
"
```

**Expected:** All agents return `200`.

### Step 2: Verify Milvus Seeder Completed

```bash
oc get job milvus-seeder -n agentic-commerce
# COMPLETIONS should show 1/1

oc logs job/milvus-seeder -n agentic-commerce -c seeder --tail=10
# Should show: "Seeding complete" or similar
```

If the seeder failed (e.g., embedding API unreachable), re-run it:

```bash
oc delete job milvus-seeder -n agentic-commerce
# Then re-run the deploy script or create the Job manually
```

### Step 3: Test Product Listing (ACP)

```bash
API_HOST=$(oc get route agentic-commerce-api -n agentic-commerce -o jsonpath='{.spec.host}')

curl -s "https://${API_HOST}/products" \
  -H "Authorization: Bearer merchant-api-key-12345" \
  -H "API-Version: 2026-01-16" | python3 -m json.tool
```

**Expected:** JSON array of products with IDs, names, prices, and images.

### Step 4: Test Checkout Session Creation

```bash
curl -s -X POST "https://${API_HOST}/checkout_sessions" \
  -H "Authorization: Bearer merchant-api-key-12345" \
  -H "API-Version: 2026-01-16" \
  -H "Content-Type: application/json" \
  -d '{
    "line_items": [{"product_id": "prod_001", "quantity": 1}]
  }' | python3 -m json.tool
```

**Expected:** A checkout session object with `id`, `status`, `line_items`, and promotion details (if promotion agent is healthy and LLM endpoint is reachable).

### Step 5: Test Recommendation Agent

```bash
curl -s -X POST "https://${API_HOST}/checkout_sessions" \
  -H "Authorization: Bearer merchant-api-key-12345" \
  -H "API-Version: 2026-01-16" \
  -H "Content-Type: application/json" \
  -d '{
    "line_items": [{"product_id": "prod_001", "quantity": 1}],
    "include_recommendations": true
  }' | python3 -m json.tool
```

**Expected:** Response includes a `recommendations` field with product suggestions based on Milvus vector similarity search. If Milvus seeder hasn't completed, recommendations will be empty.

### Step 6: End-to-End UI Test

1. Open the frontend URL in your browser
2. In the **Client Agent Panel**, select a product and click "Add to Cart"
3. Proceed through the checkout flow:
   - Product selection → shipping → payment delegation → complete
4. Verify in the **Merchant Server Panel**:
   - ACP protocol events appear in real-time
   - Session transitions through `not_ready_for_payment` → `ready_for_payment` → `completed`
5. Verify in the **Agent Activity Panel**:
   - Promotion agent reasoning traces appear
   - Recommendation suggestions are displayed
6. Test the **UCP tab** in the Merchant Server Panel for A2A protocol flow

### Step 7: Test Apps SDK Mode

1. In the UI, switch to "Apps SDK" mode (if available)
2. The MCP server at `/apps-sdk/` provides tools for cart management, checkout, and search
3. Verify the embedded widget loads and can interact with the merchant API

If any step fails, check the relevant pod logs:

```bash
oc logs deployment/merchant -n agentic-commerce --tail=100
oc logs deployment/promotion-agent -n agentic-commerce --tail=100
oc logs deployment/recommendation-agent -n agentic-commerce --tail=100
```

---

## 10. OpenShift-Specific Challenges and Solutions

This section documents every issue encountered during OpenShift validation and the exact fix applied. This is the most valuable part of this guide for anyone reproducing the deployment.

### Challenge 1: Security Context Constraints (SCC)

**What happened:** Multiple pods failed to start with `CrashLoopBackOff`. Logs showed:
```
mkdir: cannot create directory '/data': Permission denied
```

**Services affected:** merchant, psp, apps-sdk, NAT agents, Milvus (Helm), nginx

**Why:** OpenShift's default `restricted` SCC assigns a random UID from the namespace's allocated range. Many containers expect to write to specific directories (e.g., `/data` for SQLite, `/var/lib/milvus`) as specific users, which conflicts with the restricted SCC.

**Fix:** Grant `anyuid` SCC to the `default` service account before deploying any pods:
```bash
oc adm policy add-scc-to-user anyuid -z default -n agentic-commerce
```

**Important:** This must be done *before* pod creation. If pods start with the wrong SCC, they cache the failure and don't recover cleanly on restart.

---

### Challenge 2: Nginx Privileged Port Binding

**What happened:** The nginx pod failed to start:
```
nginx: [emerg] bind() to 0.0.0.0:80 failed (13: Permission denied)
```

**Services affected:** `nginx`

**Why:** The upstream `nginx.conf` listens on port 80. Under OpenShift's restricted SCC (even with `anyuid`), ports below 1024 can fail depending on the container image's user configuration. The default nginx Alpine image runs its master process as root before dropping to the nginx user, but the initial bind requires root capabilities that may be restricted.

**Fix:** Changed the nginx config to listen on port 8080 instead of 80. The OpenShift Route connects to port 8080 on the nginx Service, so external access is unaffected (the Route terminates TLS on port 443). This avoids any privileged port issues without requiring the `privileged` SCC.

```nginx
server {
    listen 8080;  # Changed from 80
    ...
}
```

---

### Challenge 3: SQLite Shared Database with ReadWriteOnce PVC

**What happened:** When the PSP pod was scheduled on a different node than the merchant pod:
```
Multi-Attach error for volume "pvc-xxx": Volume is already exclusively attached to one node
```

**Services affected:** `merchant`, `psp`

**Why:** Both merchant and PSP share a SQLite database file at `/data/agentic_commerce.db` via the same PVC. The upstream Docker Compose mounts the same named volume into both containers on the same host. In Kubernetes, a `ReadWriteOnce` PVC can only be attached to a single node. If merchant and PSP are scheduled on different nodes, the second pod fails to mount the volume.

**Fix:** Added `podAffinity` to the PSP deployment to ensure it's always scheduled on the same node as the merchant:
```yaml
affinity:
  podAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: merchant
        topologyKey: kubernetes.io/hostname
```

Additionally, both deployments use `strategy: Recreate` instead of `RollingUpdate` to prevent multi-attach errors during updates. The trade-off is brief downtime during pod updates.

---

### Challenge 4: NodePort Service Type Not Available

**What happened:** OpenShift cluster policies restricted NodePort allocation.

**Services affected:** All services

**Fix:** All services use `ClusterIP` and are exposed externally via OpenShift Routes with edge TLS termination. The deploy script creates two routes:
- `agentic-commerce` → nginx (port 8080) — main UI entry point with full routing
- `agentic-commerce-api` → merchant (port 8000) — direct API access for testing

---

### Challenge 5: BuildConfig for Repo-Root Build Context

**What happened:** Builds failed because OpenShift couldn't find the Dockerfile:
```
error: open /tmp/build/inputs/Dockerfile: no such file or directory
```

**Services affected:** All 5 custom images (merchant, psp, apps-sdk, ui, nat-agents)

**Why:** All Dockerfiles in this blueprint expect the **repo root** as build context (they use paths like `COPY src/merchant ./src/merchant`). When using `oc start-build --from-dir=.`, OpenShift expects the Dockerfile at the root. The actual Dockerfiles are in subdirectories (e.g., `src/merchant/Dockerfile`).

**Fix:** Create BuildConfigs with `--binary` only, then patch `dockerfilePath`:
```bash
oc new-build --name=merchant --strategy=docker --binary --to=merchant:latest
oc patch bc merchant --type=merge \
  -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"src/merchant/Dockerfile"}}}}'
oc start-build merchant --from-dir=<repo-root> --follow
```

The deploy script does this automatically for all 5 builds.

---

### Challenge 6: `oc new-build --binary` and `--dockerfile` Incompatibility

**What happened:** BuildConfigs were silently not created when both `--binary` and `--dockerfile` flags were used.

**Services affected:** All custom image builds

**Why:** `oc new-build` does not support combining `--binary` with `--dockerfile`. `--binary` means "context uploaded at build time," while `--dockerfile` means "use this inline Dockerfile content" — contradictory sources.

**Fix:** Use a two-step approach: create the BuildConfig with `--binary` only, then `oc patch` to set `dockerfilePath` and any `buildArgs`. See Challenge 5 for the pattern.

---

### Challenge 7: UI Build Requires Build-Time Environment Variables

**What happened:** The UI (Next.js) built successfully but could not connect to the UCP discovery endpoint at runtime.

**Services affected:** `ui`

**Why:** Next.js bakes `NEXT_PUBLIC_*` environment variables into the JavaScript bundle at build time. The UCP discovery URL (`NEXT_PUBLIC_UCP_PLATFORM_PROFILE_URL`) must be set during the build, not at runtime. In Docker Compose, this is set via the `environment` block, but for a standalone build it needs to be a build arg.

**Fix:** Patch the UI BuildConfig to pass the URL as a Docker build arg:
```bash
oc patch bc ui --type=merge \
  -p '{"spec":{"strategy":{"dockerStrategy":{"buildArgs":[
    {"name":"NEXT_PUBLIC_UCP_PLATFORM_PROFILE_URL","value":"http://merchant:8000/.well-known/ucp"}
  ]}}}}'
```

The value uses the in-cluster service DNS name (`merchant:8000`) because the UI's server-side proxy routes resolve this internally.

---

### Challenge 8: Milvus Infrastructure Dependencies (Helm Chart)

**What happened:** Milvus standalone failed to start with connection errors:
```
Failed to connect to etcd: context deadline exceeded
```

**Services affected:** `milvus-standalone`

**Why:** Milvus requires etcd and MinIO to be ready before it can start. In Docker Compose, `depends_on` with `condition: service_healthy` handles this.

**Fix:** The official Milvus Helm chart handles dependency ordering internally — etcd and MinIO are deployed as sub-charts, and Milvus's own retry logic handles transient connection failures on startup. The Helm chart also configures proper readiness probes.

For the Milvus seeder Job, an init container explicitly waits for the Helm-deployed Milvus health:
```yaml
initContainers:
  - name: wait-for-milvus
    image: curlimages/curl:8.5.0
    command: ["sh", "-c"]
    args:
      - |
        until curl -sf http://milvus:9091/healthz; do
          sleep 10
        done
```

---

### Challenge 9: Milvus Seeder Needs Embedding API Access

**What happened:** The Milvus seeder Job failed with API connection errors when running in cloud API mode:
```
Connection error: Unable to reach https://integrate.api.nvidia.com/v1
```

**Services affected:** `milvus-seeder`

**Why:** The seeder calls the NVIDIA embedding API to generate product catalog embeddings before inserting them into Milvus. In cloud API mode, the seeder pod must have network egress to `integrate.api.nvidia.com`. Some OpenShift clusters restrict egress traffic.

**Fix:** Ensure the namespace's NetworkPolicy (if any) allows egress to `integrate.api.nvidia.com`. The seeder also needs the `NVIDIA_API_KEY` environment variable. The deploy script injects this from the `app-credentials` secret. If the seeder fails, check logs and re-run:
```bash
oc delete job milvus-seeder -n agentic-commerce
# Re-run the deploy script (it recreates the job)
```

---

### Challenge 10: Helm Secret Ownership Conflict

**What happened:** Pre-created Kubernetes secrets caused Helm-style resource tracking issues:
```
Error: rendered manifests contain a resource that already exists
```

**Services affected:** Secret management

**Why:** If a future Helm chart is introduced for this blueprint, Helm tracks ownership of all resources it manages. Pre-created secrets without Helm labels are treated as foreign resources. Even without Helm today, labeling secrets consistently follows best practices.

**Fix:** Pre-create secrets with Helm ownership labels and annotations:
```bash
oc create secret generic app-credentials ... \
  --dry-run=client -o yaml \
  | oc label --local -f - app.kubernetes.io/managed-by=Helm -o yaml \
  | oc annotate --local -f - \
      meta.helm.sh/release-name=agentic-commerce \
      meta.helm.sh/release-namespace=agentic-commerce -o yaml \
  | oc apply -n agentic-commerce -f -
```

---

### Challenge 11: GPU Node Taint Key Mismatch

**What happened:** NIM pods stayed in `Pending`:
```
0/10 nodes are available: 4 node(s) had untolerated taint {g6-gpu: true}
```

**Services affected:** `nim-llm`, `nim-embedqa`

**Why:** Different OpenShift clusters use different taint keys on GPU nodes. The generic `nvidia.com/gpu` is common in documentation but production clusters often use custom keys (e.g., `g6-gpu`, `p4-gpu`).

**Fix:** The deploy script auto-detects GPU node taint keys (`GPU_TOLERATION_KEYS=auto` by default):
1. Queries GPU-labeled nodes for their taints
2. Filters out Kubernetes system taints
3. Builds tolerations for all remaining taint keys

Override manually if needed:
```bash
GPU_TOLERATION_KEYS="g6-gpu,p4-gpu" bash openshift/deploy/helm/deploy-openshift.sh
```

---

### Challenge 12: Shared Memory for NIM Containers

**What happened:** NIM model loading failed:
```
RuntimeError: DataLoader worker is killed by signal: Bus error
```

**Services affected:** `nim-llm`, `nim-embedqa`

**Why:** The upstream Docker Compose sets `shm_size: 16gb`. The default `/dev/shm` in a Kubernetes pod is only 64 MB.

**Fix:** Mount an `emptyDir` with `medium: Memory` at `/dev/shm`:
```yaml
volumes:
  - name: dshm
    emptyDir:
      medium: Memory
      sizeLimit: 16Gi
volumeMounts:
  - name: dshm
    mountPath: /dev/shm
```

---

### Challenge 13: HuggingFace Tokenizer Race Condition

**What happened:** NIM pods crashed during startup:
```
The current process just got forked. Disabling parallelism to avoid deadlocks...
```

**Services affected:** `nim-llm`, `nim-embedqa`

**Why:** The HuggingFace `tokenizers` Rust library has a thread pool race condition when forked processes try to use parallel tokenization.

**Fix:** Set `TOKENIZERS_PARALLELISM=false` on all NIM deployments:
```yaml
env:
  - name: TOKENIZERS_PARALLELISM
    value: "false"
```

---

### Challenge 14: Nemotron-3-Nano (30B) Does NOT Fit on A100-40GB

**What happened:** The LLM NIM crashed on A100-SXM4-40GB:
```
torch.OutOfMemoryError: CUDA out of memory.
```

Forcing FP8 via `NIM_MODEL_PROFILE` also failed:
```
FP8 requires compute capability SM89+ (Ada Lovelace/L40S or Hopper/H100 or newer).
```

**Services affected:** `nim-llm`

**Why:** Nemotron-3-Nano is a 30B MoE model. In BF16, weights consume ~38 GiB — exceeding A100-40GB. FP8 quantization (halving memory) requires SM89+ (L40S, H100). A100 is SM80.

**Fix:** Use a GPU with >= 48 GB VRAM and SM89+ compute capability (L40S, H100, or newer):
```bash
# Check available GPU types
oc get nodes -l nvidia.com/gpu.present=true \
  -o custom-columns="NODE:.metadata.name,GPU:.metadata.labels.nvidia\.com/gpu\.product"
```

If only A100-40GB GPUs are available, use cloud API mode (`DEPLOY_NIMS=false`) which routes LLM calls to NVIDIA's hosted API.

---

### Challenge 15: Route Timeout for Long-Running Agent Operations

**What happened:** Complex checkout sessions with multiple agent calls timed out:
```
504 Gateway Timeout
```

**Services affected:** Frontend → nginx → merchant (for agent-heavy requests)

**Why:** OpenShift's default Route timeout is 30 seconds. Promotion and recommendation agents can take 10–30 seconds each. Combined with the checkout flow orchestration, total request time can exceed 60 seconds.

**Fix:** Two timeout configurations:

1. **Nginx proxy timeouts** (300s) in the ConfigMap:
   ```nginx
   proxy_read_timeout 300s;
   ```

2. **OpenShift Route annotation**:
   ```bash
   oc annotate route agentic-commerce \
     haproxy.router.openshift.io/timeout=300s
   ```

---

### Challenge 16: Internal Registry Authentication Override

**What happened:** Application pods (merchant, psp, etc.) were in `ImagePullBackOff` despite successful builds:
```
Failed to pull image "image-registry.openshift-image-registry.svc:5000/...": authentication required
```

**Services affected:** All custom-built images

**Why:** When a pod spec explicitly sets `imagePullSecrets: [{name: ngc-secret}]`, it **overrides** the default service account's pull secrets — including the `default-dockercfg-*` secret that authenticates to the internal registry. The `ngc-secret` only has credentials for `nvcr.io`.

**Fix:** Don't set `imagePullSecrets` on application deployments that use internally built images. The default service account's linked pull secrets handle both internal registry and nvcr.io authentication. Only NIM deployments (which pull from nvcr.io) specify `imagePullSecrets: [{name: ngc-secret}]`.

---

### Challenge 17: Webhook URL Configuration

**What happened:** Post-purchase agent webhooks failed to deliver to the UI:
```
Connection refused: http://ui:3000/api/webhooks/acp
```

**Services affected:** `merchant` → `ui` webhook delivery

**Why:** The upstream Docker Compose uses separate `WEBHOOK_URL` (for local dev on localhost) and `WEBHOOK_URL_DOCKER` (for container-to-container). In Kubernetes, service DNS names replace both patterns.

**Fix:** Set `WEBHOOK_URL=http://ui:3000/api/webhooks/acp` directly on the merchant deployment. In Kubernetes, `ui` resolves to the UI service's ClusterIP within the same namespace. No separate "docker" URL is needed.

---

## 11. Cleanup

### Remove All Resources

```bash
NAMESPACE=agentic-commerce

# Delete all workloads, services, and routes
oc delete all --all -n "${NAMESPACE}"
oc delete configmap --all -n "${NAMESPACE}"
oc delete secret ngc-secret app-credentials -n "${NAMESPACE}"
oc delete pvc --all -n "${NAMESPACE}"
oc delete route --all -n "${NAMESPACE}"
oc delete job --all -n "${NAMESPACE}"

# Remove BuildConfigs and image streams
oc delete bc --all -n "${NAMESPACE}"
oc delete is --all -n "${NAMESPACE}"

# Remove SCC grants
oc adm policy remove-scc-from-user anyuid -z default -n "${NAMESPACE}"

# Delete the namespace
oc delete project "${NAMESPACE}"
```

### Remove Only NIM Pods (Switch to Cloud API)

```bash
NAMESPACE=agentic-commerce
for NIM in nim-llm nim-embedqa; do
  oc delete deployment "${NIM}" -n "${NAMESPACE}" 2>/dev/null
  oc delete service "${NIM}" -n "${NAMESPACE}" 2>/dev/null
done
```

Then update agent environment variables to use the hosted API:
```bash
for AGENT in promotion-agent post-purchase-agent recommendation-agent search-agent; do
  oc set env deployment/${AGENT} \
    NIM_LLM_BASE_URL=https://integrate.api.nvidia.com/v1 \
    NIM_LLM_MODEL_NAME=nvidia/nemotron-3-nano-30b-a3b \
    -n "${NAMESPACE}"
done

for AGENT in recommendation-agent search-agent; do
  oc set env deployment/${AGENT} \
    NIM_EMBED_BASE_URL=https://integrate.api.nvidia.com/v1 \
    -n "${NAMESPACE}"
done
```

---

## 12. Deployment Files

All OpenShift-specific files are isolated in the `openshift/` directory at the repository root. No upstream files are permanently modified — only `README.md` has a section pointing to these files.

```
openshift/
├── docs/
│   └── deploy-openshift.md                # This file — full deployment guide
└── deploy/
    └── helm/
        ├── deploy-openshift.sh            # Automated deployment script
        ├── values-openshift.yaml          # Configuration reference
        └── patches/                       # Patched upstream templates (if needed)
            └── (empty — this blueprint has no upstream Helm chart)
```

### File Descriptions

| File | Purpose |
|------|---------|
| `openshift/deploy/helm/deploy-openshift.sh` | Idempotent deployment script (10 phases). Creates namespace, grants SCC, creates secrets with Helm labels, builds 5 images via OpenShift BuildConfigs, deploys Milvus via the official Helm chart in standalone mode, deploys all application services (merchant, PSP, Apps SDK, UI, nginx, 4 NAT agents), optionally deploys NIM containers, runs Milvus seeder Job (with init containers that wait for Milvus and embedding NIM health), creates Routes, waits for rollouts. Phoenix is intentionally omitted. |
| `openshift/deploy/helm/values-openshift.yaml` | Documents all configurable values: image references, resource sizing, NIM configuration, service types, agent configs, infrastructure settings, and persistence. Heavily commented with rationale. |
| `openshift/docs/deploy-openshift.md` | This file. Full deployment guide covering architecture, hardware, 17 challenges with solutions, testing steps, and cleanup. |
| `openshift/deploy/helm/patches/` | Reserved for patched upstream Helm templates. Currently empty because this blueprint uses Docker Compose upstream. |

### Template Patch Pattern (for future use)

If the upstream blueprint adds a Helm chart and templates need modification for OpenShift:

1. Copy the modified template to `openshift/deploy/helm/patches/<chart>-templates/<filename>.yaml`
2. The deploy script backs up originals to a **temp directory** (never inside `templates/` — Helm renders all files there)
3. Copies patches into the chart's `templates/` directory
4. Runs `helm install`
5. A `trap EXIT` handler restores the originals, guaranteeing cleanup even on failure

---

*Last validated: March 2026 on OpenShift 4.17 with NVIDIA GPU Operator v24.9*
