#!/usr/bin/env bash
# modules/05_start_stack.sh — Step 5: Start the Docker Compose stack

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

: "${INSTALL_DIR:=$HOME/llm-starter}"

start_stack() {
  cd "$INSTALL_DIR"

  info "Starting observability layer (gpu-exporter, prometheus, grafana)..."
  docker compose up -d gpu-exporter prometheus grafana

  info "Waiting 10s for Prometheus to come up..."
  sleep 10

  local prom_health
  prom_health=$(curl -s "http://localhost:9090/-/healthy" 2>/dev/null || echo "")
  [[ "$prom_health" == "Prometheus Server is Healthy." ]] \
    || warn "Prometheus not healthy yet — check: docker compose logs prometheus"

  info "Starting vLLM (model download on first run can take 3–10 min)..."
  docker compose up -d vllm
  ok "Stack started. Run: docker compose logs -f vllm"
}

start_stack
