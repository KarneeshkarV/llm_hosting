#!/usr/bin/env bash
# modules/04_write_stack.sh — Step 4: Write all stack config files

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

: "${MODEL:=Qwen/Qwen2.5-1.5B-Instruct}"
: "${MODEL_NAME:=qwen}"
: "${VLLM_IMAGE:=vllm/vllm-openai:v0.8.5}"
: "${MAX_MODEL_LEN:=2048}"
: "${GPU_MEM_UTIL:=0.82}"
: "${MAX_NUM_SEQS:=4}"
: "${INSTALL_DIR:=$HOME/llm-starter}"
: "${SKIP_GPU:=0}"
: "${HF_TOKEN:=}"

write_stack() {
  info "Creating project directory at $INSTALL_DIR..."
  mkdir -p "$INSTALL_DIR"/{prometheus,scripts,hf-cache}
  mkdir -p "$INSTALL_DIR"/grafana/provisioning/{datasources,dashboards}
  cd "$INSTALL_DIR"

  if [[ "$SKIP_GPU" == "1" ]]; then
    GPU_SECTION=""
    VLLM_DEVICE="--device cpu"
  else
    GPU_SECTION='    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]'
    VLLM_DEVICE=""
  fi

  # ── docker-compose.yml ──────────────────────────────────────────────────────
  cat > docker-compose.yml << EOF
version: "3.9"

services:

  vllm:
    image: ${VLLM_IMAGE}
${GPU_SECTION}
    ipc: host
    shm_size: "4g"
    ports:
      - "8000:8000"
    volumes:
      - ./hf-cache:/root/.cache/huggingface
    env_file: .env
    restart: unless-stopped
    command: >
      --model ${MODEL}
      --served-model-name ${MODEL_NAME}
      --dtype bfloat16
      --max-model-len ${MAX_MODEL_LEN}
      --gpu-memory-utilization ${GPU_MEM_UTIL}
      --max-num-seqs ${MAX_NUM_SEQS}
      --enable-prefix-caching
      ${VLLM_DEVICE}
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8000/health"]
      interval: 30s
      retries: 8
      start_period: 240s

  gpu-exporter:
    image: utkuozdemir/nvidia_gpu_exporter:1.2.1
${GPU_SECTION}
    ports:
      - "9835:9835"
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:v3.4.1
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/alerts.yml:/etc/prometheus/alerts.yml:ro
      - prom-data:/prometheus
    ports:
      - "9090:9090"
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.retention.time=7d"
    restart: unless-stopped

  grafana:
    image: grafana/grafana:12.0.1
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: admin
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    ports:
      - "3000:3000"
    depends_on:
      - prometheus
    restart: unless-stopped

volumes:
  prom-data:
  grafana-data:
EOF

  # ── prometheus/prometheus.yml ───────────────────────────────────────────────
  cat > prometheus/prometheus.yml << 'EOF'
global:
  scrape_interval: 5s
  evaluation_interval: 5s

rule_files:
  - /etc/prometheus/alerts.yml

scrape_configs:
  - job_name: vllm
    static_configs:
      - targets: ["vllm:8000"]
    metrics_path: /metrics
  - job_name: gpu
    static_configs:
      - targets: ["gpu-exporter:9835"]
EOF

  # ── prometheus/alerts.yml ──────────────────────────────────────────────────
  cat > prometheus/alerts.yml << 'EOF'
groups:
  - name: vllm
    rules:
      - alert: KVCacheHigh
        expr: vllm:gpu_cache_usage_perc > 0.90
        for: 2m
        labels: { severity: warning }
        annotations: { summary: "KV cache above 90%" }

      - alert: RequestsQueuing
        expr: vllm:num_requests_waiting > 0
        for: 3m
        labels: { severity: warning }
        annotations: { summary: "Requests queuing — server saturated" }

      - alert: HighErrorRate
        expr: >
          rate(vllm:request_success_total{finished_reason="error"}[5m])
          / rate(vllm:request_success_total[5m]) > 0.01
        for: 2m
        labels: { severity: critical }
        annotations: { summary: "Error rate above 1%" }

  - name: gpu
    rules:
      - alert: GPUTempHigh
        expr: nvidia_smi_temperature_gpu > 85
        for: 1m
        labels: { severity: warning }
        annotations: { summary: "GPU above 85C" }

      - alert: GPUMemoryNearFull
        expr: nvidia_smi_memory_used_bytes / nvidia_smi_memory_total_bytes > 0.92
        for: 2m
        labels: { severity: warning }
        annotations: { summary: "VRAM above 92%" }
EOF

  # ── grafana/provisioning/datasources/prometheus.yml ────────────────────────
  cat > grafana/provisioning/datasources/prometheus.yml << 'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
EOF

  # ── grafana/provisioning/dashboards/dashboards.yml ─────────────────────────
  cat > grafana/provisioning/dashboards/dashboards.yml << 'EOF'
apiVersion: 1
providers:
  - name: default
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /etc/grafana/provisioning/dashboards
EOF

  # ── .env ────────────────────────────────────────────────────────────────────
  cat > .env << EOF
HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}
EOF

  # ── scripts/smoke_test.py ───────────────────────────────────────────────────
  cat > scripts/smoke_test.py << PYEOF
import sys
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8000/v1", api_key="not-needed")
MODEL = "${MODEL_NAME}"

def check_models():
    print("Checking /v1/models ...", end=" ", flush=True)
    names = [m.id for m in client.models.list().data]
    assert MODEL in names, f"Expected '{MODEL}', got: {names}"
    print(f"OK {names}")

def check_completion():
    print("Sending completion ...", end=" ", flush=True)
    resp = client.chat.completions.create(
        model=MODEL,
        messages=[{"role":"user","content":"Reply with exactly the word PONG and nothing else."}],
        max_tokens=10, temperature=0)
    text = resp.choices[0].message.content.strip()
    assert "PONG" in text, f"Unexpected reply: {text!r}"
    print(f"OK got {text!r}")

def check_metrics():
    import urllib.request
    print("Checking /metrics ...", end=" ", flush=True)
    with urllib.request.urlopen("http://localhost:8000/metrics") as r:
        body = r.read().decode()
    keys = ["vllm:num_requests_running","vllm:gpu_cache_usage_perc","vllm:time_to_first_token_seconds"]
    missing = [k for k in keys if k not in body]
    print("WARN missing: " + str(missing) if missing else "OK")

if __name__ == "__main__":
    try:
        check_models(); check_completion(); check_metrics()
        print("\n✓ All checks passed")
    except Exception as e:
        print(f"\n✗ FAILED: {e}"); sys.exit(1)
PYEOF

  # ── scripts/chat.py ─────────────────────────────────────────────────────────
  cat > scripts/chat.py << PYEOF
from openai import OpenAI
client = OpenAI(base_url="http://localhost:8000/v1", api_key="not-needed")
MODEL = "${MODEL_NAME}"
history = []
print(f"Chatting with {MODEL} — 'reset' to clear, 'exit' to quit\n")
while True:
    try:
        user_input = input("You: ").strip()
    except (KeyboardInterrupt, EOFError):
        print("\nBye."); break
    if not user_input: continue
    if user_input.lower() == "exit": break
    if user_input.lower() == "reset":
        history.clear(); print("[cleared]\n"); continue
    history.append({"role":"user","content":user_input})
    stream = client.chat.completions.create(
        model=MODEL, messages=history, max_tokens=512, temperature=0.7, stream=True)
    print("Model: ", end="", flush=True)
    reply = ""
    for chunk in stream:
        delta = chunk.choices[0].delta.content or ""
        print(delta, end="", flush=True); reply += delta
    print()
    history.append({"role":"assistant","content":reply})
PYEOF

  ok "All stack files written to $INSTALL_DIR"
}

write_stack
