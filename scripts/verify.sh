#!/usr/bin/env bash
# Prove that the GCP Load Balancer reaches more than one pod.
#
# Usage:
#   ./scripts/verify.sh                    # auto-detect Service External IP
#   ./scripts/verify.sh http://1.2.3.4     # test an explicit URL
#   COUNT=50 ./scripts/verify.sh           # send more requests
set -Eeuo pipefail

COUNT="${COUNT:-30}"
URL="${1:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

for tool in curl awk sort uniq wc; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' tidak ditemukan di PATH."
done

if [[ -z "$URL" ]]; then
  command -v kubectl >/dev/null 2>&1 || die "kubectl tidak ditemukan; berikan URL sebagai argumen."
  ADDRESS="$(kubectl get service pod-info -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$ADDRESS" ]] || die "External IP belum ada. Tunggu sebentar lalu coba lagi."
  URL="http://${ADDRESS}"
fi

[[ "$URL" =~ ^https?:// ]] || URL="http://${URL}"
URL="${URL%/}"

PODS_FILE="$(mktemp)"
HEADERS_FILE="$(mktemp)"
trap 'rm -f "$PODS_FILE" "$HEADERS_FILE"' EXIT

echo "Target  : ${URL}/"
echo "Requests: ${COUNT}"
echo
printf '%-4s %-32s %-16s %s\n' "#" "POD" "POD IP" "NODE"
printf '%-4s %-32s %-16s %s\n' "---" "--------------------------------" "----------------" "----------------"

for ((i=1; i<=COUNT; i++)); do
  if ! curl -fsS --max-time 10 -D "$HEADERS_FILE" -o /dev/null "${URL}/"; then
    die "Request #${i} gagal. Cek External IP, firewall, dan health check Service."
  fi

  pod="$(awk -F': ' 'tolower($1)=="x-pod-name" {print $2}' "$HEADERS_FILE" | tr -d '\r')"
  pod_ip="$(awk -F': ' 'tolower($1)=="x-pod-ip" {print $2}' "$HEADERS_FILE" | tr -d '\r')"
  node="$(awk -F': ' 'tolower($1)=="x-node-name" {print $2}' "$HEADERS_FILE" | tr -d '\r')"

  [[ -n "$pod" ]] || die "Header X-Pod-Name tidak ditemukan pada response #${i}."
  printf '%-4s %-32s %-16s %s\n' "$i" "$pod" "$pod_ip" "$node"
  printf '%s\n' "$pod" >> "$PODS_FILE"
  sleep 0.2
done

echo
echo "Distribusi request per Pod:"
sort "$PODS_FILE" | uniq -c | sort -rn

UNIQUE_PODS="$(sort -u "$PODS_FILE" | wc -l | tr -d ' ')"
echo
if [[ "$UNIQUE_PODS" -ge 2 ]]; then
  echo "PASS: ${COUNT} request mencapai ${UNIQUE_PODS} Pod berbeda."
else
  echo "FAIL: semua request hanya mencapai ${UNIQUE_PODS} Pod." >&2
  echo "Pastikan kedua Pod Ready dan Service memiliki dua endpoint:" >&2
  echo "  kubectl get pods -l app.kubernetes.io/name=pod-info -o wide" >&2
  echo "  kubectl get endpoints pod-info" >&2
  exit 1
fi

if command -v kubectl >/dev/null 2>&1 && kubectl get deployment pod-info >/dev/null 2>&1; then
  echo
  echo "Pemeriksaan Pod dan Node:"
  kubectl get pods -l app.kubernetes.io/name=pod-info \
    -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,POD_IP:.status.podIP,READY:.status.containerStatuses[0].ready'
  echo
  echo "Jumlah Node unik yang menjalankan Pod:"
  kubectl get pods -l app.kubernetes.io/name=pod-info \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l
fi
