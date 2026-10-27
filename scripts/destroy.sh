#!/usr/bin/env bash
# Destroy the GKE PoC resources safely.
#
# Default behaviour:
#   1. Delete Deployment/Service (releases the GCP load balancer).
#   2. Delete the GKE cluster (removes nodes and the load balancer).
#   3. Keep Artifact Registry so images are not deleted unexpectedly.
#
# This script never deletes local files or the working directory.
#
# Options:
#   -y, --yes          Skip the interactive confirmation (for automation).
#   --delete-repo      Also delete the remote Artifact Registry repository and
#                      images (not local files, not a Git repository).
#   --dry-run          Print the plan without changing anything.
#   -h, --help         Show this help.
#
# Environment variables (same defaults as deploy.sh):
#   PROJECT_ID, REGION, LOCATION, CLUSTER, REPO, NAMESPACE
set -Eeuo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
REGION="${REGION:-asia-southeast2}"
LOCATION="${LOCATION:-asia-southeast2-a}"
CLUSTER="${CLUSTER:-python-poc-cluster}"
REPO="${REPO:-python-poc}"
NAMESPACE="${NAMESPACE:-default}"
DELETE_REPO="${DELETE_REPO:-0}"
ASSUME_YES=0
DRY_RUN=0

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

usage() {
  cat <<'EOF'
Usage: ./scripts/destroy.sh [options]

Delete the GKE PoC workload and cluster. The remote GCP Artifact Registry
repository is kept by default. This script never deletes local files.

Options:
  -y, --yes       Skip the interactive confirmation (for CI/automation).
  --delete-repo   Also delete the remote GCP Artifact Registry repository and
                  all images. IRREVERSIBLE. Does NOT delete local files.
  --dry-run       Show what would be deleted; no resources are touched.
  -h, --help      Show this help.

Examples:
  ./scripts/destroy.sh --dry-run
  ./scripts/destroy.sh
  ./scripts/destroy.sh --yes
  ./scripts/destroy.sh --yes --delete-repo

Environment variables:
  PROJECT_ID  GCP project (default: current gcloud project)
  REGION      Artifact Registry region (default: asia-southeast2)
  LOCATION    GKE zone/region (default: asia-southeast2-a)
  CLUSTER     GKE cluster name (default: python-poc-cluster)
  REPO        Artifact Registry repository (default: python-poc)
  NAMESPACE   Kubernetes namespace (default: default)
EOF
}

while (($# > 0)); do
  case "$1" in
    -y|--yes) ASSUME_YES=1 ;;
    --delete-repo) DELETE_REPO=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Opsi tidak dikenal: $1" ;;
  esac
  shift
done

command -v gcloud >/dev/null 2>&1 || die "'gcloud' tidak ditemukan di PATH."

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  die "PROJECT_ID belum diset. Jalankan: export PROJECT_ID=... atau gcloud config set project ..."
fi

echo "Target destroy:"
echo "  Project   : ${PROJECT_ID}"
echo "  Cluster   : ${CLUSTER} (${LOCATION})"
echo "  Namespace : ${NAMESPACE}"
echo "  Workload  : deployment/pod-info, service/pod-info"
echo "  Registry  : ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}"
echo

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[DRY-RUN] Tidak ada resource yang akan diubah."
  echo "[DRY-RUN] 1. kubectl delete deployment/pod-info service/pod-info -n ${NAMESPACE} --ignore-not-found"
  echo "[DRY-RUN] 2. gcloud container clusters delete ${CLUSTER} --location ${LOCATION} --project ${PROJECT_ID} --quiet"
  if [[ "$DELETE_REPO" == "1" ]]; then
    echo "[DRY-RUN] 3. gcloud artifacts repositories delete ${REPO} --location ${REGION} --project ${PROJECT_ID} --quiet"
    echo "[DRY-RUN]    PERINGATAN: semua image remote di GAR tersebut akan terhapus permanen."
    echo "[DRY-RUN]    Folder project lokal TIDAK terhapus."
  else
    echo "[DRY-RUN] 3. Artifact Registry dipertahankan (gunakan --delete-repo untuk menghapusnya)."
  fi
  exit 0
fi

EXPECTED_CONFIRMATION="${PROJECT_ID}/${CLUSTER}"

if [[ "$DELETE_REPO" == "1" ]]; then
  echo "PERINGATAN: repository Docker remote di Artifact Registry '${REPO}' beserta semua image di dalamnya akan dihapus permanen."
  echo "Ini TIDAK menghapus folder project lokal maupun repository Git."
  echo
fi

if [[ "$ASSUME_YES" != "1" ]]; then
  printf "Ketik '%s' untuk konfirmasi: " "$EXPECTED_CONFIRMATION"
  read -r CONFIRMATION
  [[ "$CONFIRMATION" == "$EXPECTED_CONFIRMATION" ]] || die "Dibatalkan: konfirmasi tidak cocok."
  echo
fi

# ---------------------------------------------------------------------------
# 1. Delete workload first so the load balancer is released explicitly.
# ---------------------------------------------------------------------------
CLUSTER_EXISTS=1
if ! DESCRIBE_OUTPUT="$(gcloud container clusters describe "$CLUSTER" \
  --location "$LOCATION" \
  --project "$PROJECT_ID" 2>&1)"; then
  if grep -qiE 'not[ -]?found|NOT_FOUND|404' <<<"$DESCRIBE_OUTPUT"; then
    CLUSTER_EXISTS=0
    log "Cluster '${CLUSTER}' tidak ditemukan di ${LOCATION}; skip penghapusan workload."
  else
    printf '%s\n' "$DESCRIBE_OUTPUT" >&2
    die "Gagal memeriksa cluster. Perbaiki akses/project lalu jalankan ulang."
  fi
fi

if [[ "$CLUSTER_EXISTS" == "1" ]]; then
  log "Mengambil kredensial cluster..."
  if gcloud container clusters get-credentials "$CLUSTER" \
    --location "$LOCATION" \
    --project "$PROJECT_ID"; then

    if command -v kubectl >/dev/null 2>&1; then
      log "Menghapus Deployment dan Service (ini melepas load balancer)..."
      if ! kubectl delete deployment/pod-info service/pod-info \
        --namespace "$NAMESPACE" \
        --ignore-not-found \
        --wait=true \
        --timeout=180s; then
        echo "WARN: gagal menghapus workload. Cluster tetap akan dihapus." >&2
      fi
    else
      echo "WARN: kubectl tidak ditemukan; workload akan terhapus bersama cluster." >&2
    fi
  else
    echo "WARN: gagal mengambil kredensial; workload akan terhapus bersama cluster." >&2
  fi

  # -------------------------------------------------------------------------
  # 2. Delete the cluster (nodes + load balancer).
  # -------------------------------------------------------------------------
  log "Menghapus cluster GKE '${CLUSTER}' (bisa memakan beberapa menit)..."
  gcloud container clusters delete "$CLUSTER" \
    --location "$LOCATION" \
    --project "$PROJECT_ID" \
    --quiet
  log "Cluster '${CLUSTER}' dihapus."
else
  log "Tidak ada cluster yang perlu dihapus."
fi

# ---------------------------------------------------------------------------
# 3. Optional: delete Artifact Registry repository and all images.
# ---------------------------------------------------------------------------
if [[ "$DELETE_REPO" == "1" ]]; then
  log "Menghapus Artifact Registry repository '${REPO}'..."
  if gcloud artifacts repositories describe "$REPO" \
    --location "$REGION" \
    --project "$PROJECT_ID" >/dev/null 2>&1; then
    gcloud artifacts repositories delete "$REPO" \
      --location "$REGION" \
      --project "$PROJECT_ID" \
      --quiet
    log "Repository '${REPO}' dihapus."
  else
    log "Repository '${REPO}' tidak ditemukan; skip."
  fi
else
  log "Artifact Registry '${REPO}' dipertahankan."
  echo "     Hapus juga dengan: ./scripts/destroy.sh --delete-repo"
fi

echo
echo "Selesai. Periksa kembali resource berikut jika perlu:"
echo "  gcloud container clusters list --project ${PROJECT_ID}"
echo "  gcloud artifacts repositories list --location ${REGION} --project ${PROJECT_ID}"
