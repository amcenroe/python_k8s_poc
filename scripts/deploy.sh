#!/usr/bin/env bash
# Build, push, and deploy the PoC to an existing GKE cluster.
#
# Required:
#   gcloud auth login
#   gcloud config set project YOUR_PROJECT_ID
#   A GKE cluster with >= 2 schedulable nodes (see README).
#
# Optional environment variables:
#   PROJECT_ID, REGION, LOCATION, CLUSTER, REPO, TAG, PLATFORM
set -Eeuo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
REGION="${REGION:-asia-southeast2}"
LOCATION="${LOCATION:-asia-southeast2-a}"
CLUSTER="${CLUSTER:-python-poc-cluster}"
REPO="${REPO:-python-poc}"
TAG="${TAG:-$(date +%Y%m%d-%H%M%S)}"
PLATFORM="${PLATFORM:-linux/amd64}"

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

log "Project : $PROJECT_ID"
log "Cluster : $CLUSTER ($LOCATION)"
log "Image   : $IMAGE"

gcloud container clusters describe "$CLUSTER" \
  --location "$LOCATION" \
  --project "$PROJECT_ID" >/dev/null \
  || die "Cluster '$CLUSTER' tidak ditemukan di $LOCATION. Buat cluster dulu (lihat README)."

log "Mengambil kredensial cluster..."
gcloud container clusters get-credentials "$CLUSTER" \
  --location "$LOCATION" \
  --project "$PROJECT_ID"

log "Memastikan Artifact Registry repository ada..."
if ! gcloud artifacts repositories describe "$REPO" \
  --location "$REGION" \
  --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$REPO" \
    --repository-format docker \
    --location "$REGION" \
    --description "GKE load balancing PoC images" \
    --project "$PROJECT_ID"
fi

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

log "Menunggu External IP dari GCP Load Balancer (maks. 3 menit)..."
EXTERNAL_IP=""
for ((i=0; i<36; i++)); do
  EXTERNAL_IP="$(kubectl get service pod-info -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$EXTERNAL_IP" ]] && break
  sleep 5
done

if [[ -z "$EXTERNAL_IP" ]]; then
  echo "ERROR: External IP belum tersedia setelah 3 menit." >&2
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
