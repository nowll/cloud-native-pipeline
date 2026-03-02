#!/usr/bin/env bash
# monitor-canary.sh — Poll Prometheus for error rate and p99 latency
# Usage: ./scripts/monitor-canary.sh --namespace=app-staging --release=app-canary --duration=600 --error-threshold=1 --latency-p99=500

set -euo pipefail

# Defaults
NAMESPACE=""
RELEASE=""
DURATION=600
ERROR_THRESHOLD=1     # percent
LATENCY_P99=500       # milliseconds
POLL_INTERVAL=15
PROMETHEUS_URL="${PROMETHEUS_URL:-http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090}"

# Parse args
for arg in "$@"; do
  case $arg in
    --namespace=*)  NAMESPACE="${arg#*=}" ;;
    --release=*)    RELEASE="${arg#*=}" ;;
    --duration=*)   DURATION="${arg#*=}" ;;
    --error-threshold=*) ERROR_THRESHOLD="${arg#*=}" ;;
    --latency-p99=*)    LATENCY_P99="${arg#*=}" ;;
  esac
done

[[ -z "$NAMESPACE" ]] && { echo "❌ --namespace is required"; exit 1; }
[[ -z "$RELEASE" ]]   && { echo "❌ --release is required"; exit 1; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Canary Monitor"
echo "  Release:    $RELEASE"
echo "  Namespace:  $NAMESPACE"
echo "  Duration:   ${DURATION}s"
echo "  Error SLO:  <${ERROR_THRESHOLD}%"
echo "  P99 SLO:    <${LATENCY_P99}ms"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

query_prometheus() {
  local query="$1"
  curl -sG \
    --data-urlencode "query=${query}" \
    "${PROMETHEUS_URL}/api/v1/query" \
    | jq -r '.data.result[0].value[1] // "0"'
}

START=$(date +%s)
ITERATIONS=0
FAILURES=0
MAX_FAILURES=3

while true; do
  NOW=$(date +%s)
  ELAPSED=$(( NOW - START ))

  if (( ELAPSED >= DURATION )); then
    echo ""
    echo "✅ Canary passed monitoring window (${DURATION}s)"
    break
  fi

  REMAINING=$(( DURATION - ELAPSED ))
  ITERATIONS=$(( ITERATIONS + 1 ))

  # Error rate query
  ERROR_RATE=$(query_prometheus \
    "sum(rate(http_requests_total{namespace=\"${NAMESPACE}\",pod=~\"${RELEASE}-.*\",code=~\"5..\"}[2m])) / sum(rate(http_requests_total{namespace=\"${NAMESPACE}\",pod=~\"${RELEASE}-.*\"}[2m])) * 100")

  # P99 latency query
  LATENCY=$(query_prometheus \
    "histogram_quantile(0.99, sum(rate(http_request_duration_milliseconds_bucket{namespace=\"${NAMESPACE}\",pod=~\"${RELEASE}-.*\"}[2m])) by (le))")

  ERROR_RATE_ROUNDED=$(printf "%.2f" "${ERROR_RATE}")
  LATENCY_ROUNDED=$(printf "%.0f" "${LATENCY}")

  # Check error rate
  ERROR_OK="✅"
  if (( $(echo "$ERROR_RATE > $ERROR_THRESHOLD" | bc -l) )); then
    ERROR_OK="❌"
    FAILURES=$(( FAILURES + 1 ))
  fi

  # Check latency
  LATENCY_OK="✅"
  if (( LATENCY_ROUNDED > LATENCY_P99 )); then
    LATENCY_OK="❌"
    FAILURES=$(( FAILURES + 1 ))
  fi

  printf "[%3ds remaining] Error: %s %s%% | P99: %s %sms | Failures: %d/%d\n" \
    "$REMAINING" "$ERROR_OK" "$ERROR_RATE_ROUNDED" \
    "$LATENCY_OK" "$LATENCY_ROUNDED" \
    "$FAILURES" "$MAX_FAILURES"

  if (( FAILURES >= MAX_FAILURES )); then
    echo ""
    echo "❌ CANARY FAILED: ${FAILURES} consecutive SLO violations"
    echo "   Error rate: ${ERROR_RATE_ROUNDED}% (threshold: ${ERROR_THRESHOLD}%)"
    echo "   P99 latency: ${LATENCY_ROUNDED}ms (threshold: ${LATENCY_P99}ms)"
    echo ""
    echo "⏪ Triggering rollback..."
    exit 1
  fi

  sleep "$POLL_INTERVAL"
done
