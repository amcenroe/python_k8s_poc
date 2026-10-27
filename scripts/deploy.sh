#!/usr/bin/env bash
# Provision GCP prerequisites, build, push, and deploy the PoC to GKE.
#
# Required:
#   gcloud auth login
#   gcloud config set project YOUR_PROJECT_ID
#   An active GCP project with billing enabled.
#
# Optional environment variables:
#   PROJECT_ID, REGION, LOCATION, CLUSTER, REPO, TAG, PLATFORM,
#   MACHINE_TYPE, NUM_NODES, DISK_SIZE
set -Eeuo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
REGION="${REGION:-asia-southeast2}"
LOCATION="${LOCATION:-asia-southeast2-a}"
CLUSTER="${CLUSTER:-python-poc-cluster}"
REPO="${REPO:-python-poc}"
TAG="${TAG:-$(date +%Y%m%d-%H%M%S)}"
PLATFORM="${PLATFORM:-linux/amd64}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-small}"
NUM_NODES="${NUM_NODES:-2}"
DISK_SIZE="${DISK_SIZE:-30}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/pod-info:${TAG}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

for tool in gcloud docker kubectl sed curl; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' tidak ditemukan di PATH."
done

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  die "PROJECT_ID belum diset. Jalankan: export PROJECT_ID=... atau gcloud config set project ..."
fi

[[ "$NUM_NODES" =~ ^[0-9]+$ ]] && (( 10#$NUM_NODES >= 2 )) \
  || die "NUM_NODES minimal 2 agar kedua Pod bisa dijadwalkan pada node berbeda."

log "Project : $PROJECT_ID"
log "Cluster : $CLUSTER ($LOCATION)"
log "Image   : $IMAGE"
log "Node    : $NUM_NODES x $MACHINE_TYPE"

log "Memastikan API GCP yang dibutuhkan aktif..."
gcloud services enable \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  compute.googleapis.com \
  --project "$PROJECT_ID"

log "Memastikan Artifact Registry repository ada..."
if ! REPO_OUTPUT="$(gcloud artifacts repositories describe "$REPO" \
  --location "$REGION" \
  --project "$PROJECT_ID" 2>&1)"; then
  if grep -qiE 'not[ -]?found|NOT_FOUND|404' <<<"$REPO_OUTPUT"; then
    gcloud artifacts repositories create "$REPO" \
      --repository-format docker \
      --location "$REGION" \
      --description "GKE load balancing PoC images" \
      --project "$PROJECT_ID"
  else
    printf '%s\n' "$REPO_OUTPUT" >&2
    die "Gagal memeriksa Artifact Registry. Periksa region dan izin GCP."
  fi
fi

log "Memeriksa cluster GKE..."
if ! CLUSTER_OUTPUT="$(gcloud container clusters describe "$CLUSTER" \
  --location "$LOCATION" \
  --project "$PROJECT_ID" 2>&1)"; then
  if grep -qiE 'not[ -]?found|NOT_FOUND|404' <<<"$CLUSTER_OUTPUT"; then
    log "Cluster belum ada; membuat cluster GKE (${NUM_NODES} node, ${MACHINE_TYPE})..."
    echo "PERHATIAN: pembuatan cluster GKE dan Load Balancer menimbulkan biaya GCP." >&2
    gcloud container clusters create "$CLUSTER" \
      --zone "$LOCATION" \
      --num-nodes "$NUM_NODES" \
      --machine-type "$MACHINE_TYPE" \
      --disk-size "$DISK_SIZE" \
      --release-channel regular \
      --project "$PROJECT_ID"
  else
    printf '%s\n' "$CLUSTER_OUTPUT" >&2
    die "Gagal memeriksa cluster. Periksa project, lokasi, dan izin GCP."
  fi
else
  log "Cluster sudah ada; akan digunakan kembali."
fi

log "Mengambil kredensial cluster..."
gcloud container clusters get-credentials "$CLUSTER" \
  --location "$LOCATION" \
  --project "$PROJECT_ID"

log "Menunggu node siap..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
READY_NODES="$(kubectl get nodes --no-headers | awk '$2 == "Ready" {count++} END {print count+0}')"
if (( READY_NODES < 2 )); then
  die "Cluster hanya memiliki ${READY_NODES} node Ready; minimal 2 node diperlukan."
fi

log "Memberi node pool akses baca terbatas ke repository image..."
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
NODE_POOLS="$(gcloud container node-pools list \
  --cluster "$CLUSTER" \
  --location "$LOCATION" \
  --project "$PROJECT_ID" \
  --format='value(name)')"
[[ -n "$NODE_POOLS" ]] || die "Tidak ada node pool pada cluster '$CLUSTER'."

while IFS= read -r NODE_POOL; do
  [[ -n "$NODE_POOL" ]] || continue
  NODE_SERVICE_ACCOUNT="$(gcloud container node-pools describe "$NODE_POOL" \
    --cluster "$CLUSTER" \
    --location "$LOCATION" \
    --project "$PROJECT_ID" \
    --format='value(config.serviceAccount)')"
  if [[ -z "$NODE_SERVICE_ACCOUNT" || "$NODE_SERVICE_ACCOUNT" == "default" ]]; then
    NODE_SERVICE_ACCOUNT="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
  fi
  gcloud artifacts repositories add-iam-policy-binding "$REPO" \
    --location "$REGION" \
    --member "serviceAccount:${NODE_SERVICE_ACCOUNT}" \
    --role roles/artifactregistry.reader \
    --project "$PROJECT_ID" \
    --quiet >/dev/null
done <<< "$NODE_POOLS"

log "Mengonfigurasi Docker auth untuk Artifact Registry..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

log "Build image (${PLATFORM})..."
docker build --pull --platform "$PLATFORM" -t "$IMAGE" "$ROOT_DIR"

log "Push image..."
docker push "$IMAGE"

log "Render manifest dan apply..."
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT
sed "s|IMAGE_PLACEHOLDER|${IMAGE}|g" "$ROOT_DIR/k8s/app.yaml" > "$RENDERED"
kubectl apply -f "$RENDERED"

log "Menunggu rollout Deployment/pod-info..."
kubectl rollout status deployment/pod-info --timeout=180s

echo
kubectl get pods -l app.kubernetes.io/name=pod-info -o wide

log "Menunggu External IP dari GCP Load Balancer (maks. 10 menit)..."
EXTERNAL_IP=""
for ((i=0; i<120; i++)); do
  EXTERNAL_IP="$(kubectl get service pod-info -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$EXTERNAL_IP" ]] && break
  sleep 5
done

if [[ -z "$EXTERNAL_IP" ]]; then
  echo "ERROR: External IP belum tersedia setelah 10 menit." >&2
  echo "Cek dengan: kubectl get service pod-info -w" >&2
  exit 1
fi

echo "External IP : $EXTERNAL_IP"
echo "URL         : http://${EXTERNAL_IP}/"
echo

log "Menunggu endpoint merespons melalui load balancer (maks. 3 menit)..."
ENDPOINT_READY=""
for ((i=0; i<36; i++)); do
  if curl -fsS --max-time 5 -o /dev/null "http://${EXTERNAL_IP}/healthz" 2>/dev/null; then
    ENDPOINT_READY=1
    break
  fi
  sleep 5
done

if [[ -z "$ENDPOINT_READY" ]]; then
  echo "ERROR: External IP ada, tetapi aplikasi belum merespons." >&2
  kubectl get service pod-info >&2 || true
  kubectl get endpoints pod-info >&2 || true
  kubectl describe service pod-info >&2 | tail -30 || true
  exit 1
fi

echo
echo "Bukti:"
bash "$ROOT_DIR/scripts/verify.sh" "http://${EXTERNAL_IP}"
