#!/usr/bin/env bash
# modules/06_verify.sh — Step 6: Verify the running stack

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

: "${INSTALL_DIR:=$HOME/llm-starter}"
: "${MODEL_NAME:=qwen}"
: "${SKIP_GPU:=0}"

verify() {
  cd "$INSTALL_DIR"
  local errors=0

  info "Checking container states..."
  docker compose ps

  info "Checking Prometheus targets..."
  sleep 5
  local targets
  targets=$(curl -s "http://localhost:9090/api/v1/targets" 2>/dev/null || echo "{}")
  if echo "$targets" | grep -q '"health":"up"'; then
    ok "At least one Prometheus target is up"
  else
    warn "Prometheus targets not yet up — model may still be loading"
    ((errors++)) || true
  fi

  if [[ "$SKIP_GPU" != "1" ]]; then
    info "Checking GPU metrics..."
    if curl -s "http://localhost:9835/metrics" | grep -q "nvidia_smi_temperature_gpu"; then
      ok "GPU metrics flowing"
    else
      warn "GPU metrics not found — check: docker compose logs gpu-exporter"
      ((errors++)) || true
    fi
  fi

  info "Waiting for vLLM health endpoint (up to 3 min)..."
  local i=0
  until curl -fsS "http://localhost:8000/health" &>/dev/null; do
    sleep 10; ((i++))
    [[ $i -gt 18 ]] && { warn "vLLM not ready yet — still loading model"; break; }
  done

  if curl -s "http://localhost:8000/v1/models" | grep -q "${MODEL_NAME}"; then
    ok "vLLM API is up and serving model '${MODEL_NAME}'"
  else
    warn "vLLM API not ready yet — run smoke_test.py once the model finishes loading"
    ((errors++)) || true
  fi

  echo ""
  if [[ $errors -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}✓ Stack is fully up${NC}"
  else
    echo -e "${YELLOW}${BOLD}⚠ Stack started with warnings — some services still loading${NC}"
  fi

  echo ""
  echo -e "${BOLD}Next steps:${NC}"
  echo "  Watch model load:  docker compose logs -f vllm"
  echo "  Smoke test:        pip install openai && python3 $INSTALL_DIR/scripts/smoke_test.py"
  echo "  Chat:              python3 $INSTALL_DIR/scripts/chat.py"
  echo "  Grafana:           http://localhost:3000  (admin/admin)"
  echo "    → Import dashboard 14574 (GPU) and 23991 (vLLM)"
  echo "  Prometheus:        http://localhost:9090"
}

verify
