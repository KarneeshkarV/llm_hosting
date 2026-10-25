# Observability & Tooling Notes

A reference doc covering every tool discussed for this stack — what each one does, why it matters, and where it fits.

---

## What we're building

Three layers on top of a self-hosted vLLM GPU server:

1. **GPU layer** — vLLM inference server, NVIDIA GPU management
2. **Agent / backend layer** — AI agents + API that calls vLLM
3. **Frontend layer** — product UI for end users

All self-hosted, on-prem.

---

## Current stack (already in `setup.sh`)

| Service | Port | Role |
|---|---|---|
| vLLM | 8000 | Serves the LLM via OpenAI-compatible API |
| nvidia-gpu-exporter | 9835 | Reads `nvidia-smi`, exposes GPU metrics |
| Prometheus | 9090 | Scrapes metrics every 5s, stores time-series data |
| Grafana | 3000 | Queries Prometheus, renders dashboards |

---

## Prometheus

**What it is:** A time-series database that periodically polls (scrapes) HTTP endpoints for metrics.

**How it works here:**
- Every 5s it calls `http://vllm:8000/metrics` and `http://gpu-exporter:9835/metrics`
- Both return plain-text key-value metrics (Prometheus exposition format)
- Prometheus stores every reading with a timestamp

**Query language:** PromQL — e.g. `rate(vllm:request_success_total[5m])` = requests/sec over 5 min

**Alerts (`prometheus/alerts.yml`):** PromQL expressions that fire when a condition holds for a set duration:
```yaml
- alert: KVCacheHigh
  expr: vllm:gpu_cache_usage_perc > 0.90
  for: 2m   # must be true continuously for 2 min
```

**Answers:** Is my GPU healthy? Is vLLM fast? What is p99 latency?

---

## Grafana

**What it is:** A dashboard UI. It does not collect anything — it queries data sources and draws graphs.

**How it works here:**
- Auto-provisioned via files in `grafana/provisioning/` (no manual UI setup needed)
- `datasources/prometheus.yml` points it at `http://prometheus:9090`
- `dashboards/` — any `.json` file dropped here is auto-loaded as a dashboard

**Answers:** Visual view of everything Prometheus collected.

---

## Loki (not yet added)

**What it is:** Grafana's log aggregation system. "Prometheus for logs."

**How it works:**
- Promtail runs on each host, reads Docker container logs, ships them to Loki
- Loki stores log lines with labels (container name, service, stream)
- Query language: LogQL — e.g. `{container="vllm"} |= "error"`

**Why useful here:** See vLLM errors, startup issues, and agent logs directly in Grafana — in the same time window as your metrics.

---

## Tempo (not yet added)

**What it is:** Grafana's distributed tracing backend. Receives OpenTelemetry (OTLP) spans.

**How it works:**
- vLLM is started with `--otlp-traces-endpoint http://tempo:4318/v1/traces`
- Each request becomes a trace with child spans (tokenize → schedule → generate)
- Grafana renders a waterfall view per trace

**Why useful here:** Drill into slow individual requests. See exactly how long each phase of inference took.

---

## LGTM stack

Loki + Grafana + Tempo + Mimir (or Prometheus) — Grafana's full self-hosted observability suite. The killer feature is **correlation**:

- Spike on a Prometheus graph → jump to the **trace** in Tempo → click trace ID → see the **log line** in Loki

All three datasources cross-link via time range and trace ID.

---

## Profiling

Different from metrics/logs/traces — used at dev time to find *why* something is slow.

| Tool | Layer | Use case |
|---|---|---|
| `py-spy` | Python process | Attach to running vLLM, see hot functions, zero overhead |
| `nsys` (Nsight Systems) | GPU kernels | See exactly which CUDA kernels run during inference |
| `nvtop` | GPU utilization | Live GPU monitoring, like `htop` for NVIDIA GPUs |

These are dev-time tools, not Docker services. Run them against a live vLLM process when debugging performance.

---

## Langfuse (not yet added)

**What it is:** LLM application observability. Operates at the prompt/product layer, not the infrastructure layer.

**Compared to Prometheus/Grafana:**

| | Prometheus + Grafana | Langfuse |
|---|---|---|
| Focus | Server health, GPU, latency | Prompts, completions, costs, evals |
| Who uses it | Infra/platform team | ML/product team |
| What you see | Request rate, VRAM %, p99 | What the model said, token cost, agent steps |
| Input | `/metrics` endpoint | SDK wrapping your LLM calls |

**Why essential for agents:**
- Full trace of every agent run — tools called, in what order, how long each step took
- Actual prompt + completion text for every LLM call
- Token costs per run
- Scores/evals — attach human or automated feedback to any trace
- Session grouping — all calls from one user session linked together

**Self-hostable:** Runs as Docker services (Postgres + Next.js). Slots into this stack cleanly.

---

## Frontend observability (not yet added)

| Tool | Role | Self-hosted? |
|---|---|---|
| **Sentry** | JS error tracking, performance, session replay | Yes |
| **PostHog** | Product analytics, funnels, feature flags, session replay | Yes |

Sentry answers: *Are users hitting errors?*
PostHog answers: *What are users doing? Where do they drop off?*

---

## Full picture

```
┌─────────────────────────────────────────────────┐
│  Frontend                                       │
│  ← Sentry (errors)  ← PostHog (analytics)      │
└────────────────┬────────────────────────────────┘
                 │ API calls
┌────────────────▼────────────────────────────────┐
│  Backend + AI Agents                            │
│  ← OpenTelemetry SDK (traces)                   │
│  ← Langfuse SDK (wraps LLM calls)               │
└────────────────┬────────────────────────────────┘
                 │ OpenAI-compat API (:8000)
┌────────────────▼────────────────────────────────┐
│  vLLM + GPU                                     │
│  ← Prometheus + Grafana (metrics)               │
│  ← Loki (logs)  ← Tempo (traces)               │
└─────────────────────────────────────────────────┘
```

---

## Two-host deployment strategy

The LGTM stack + Langfuse + backend should **not** run on the GPU machine. GPU resources should be dedicated to inference.

**GPU machine** — inference only:
- vLLM
- nvidia-gpu-exporter
- Promtail (ships logs out, tiny footprint)

**Dev PC / backend host** — everything else:
- Prometheus (scrapes GPU machine over network)
- Loki, Tempo, Grafana
- Langfuse
- Backend API
- Frontend

This also scales: one central observability host can watch multiple GPU machines.

**Data flow across hosts:**
- Prometheus **pulls** metrics from `gpu-machine-ip:8000` and `:9835`
- vLLM **pushes** OTLP traces to `dev-pc:4318`
- Promtail on GPU machine **pushes** logs to Loki on dev PC

---

## What to add, in priority order

1. **Langfuse** — highest unique value for agents; nothing else gives prompt-level visibility
2. **Loki** — essential when agents misbehave and you need to read logs
3. **Tempo** — once agent pipelines are complex enough to need waterfall traces
4. **Sentry** — when the frontend ships
5. **PostHog** — when you care about user behaviour patterns
