#!/usr/bin/env bash
# setup.sh — on-prem LLM stack bootstrapper (main entrypoint)
#
# Usage:
#   bash setup.sh                        # auto-detects resume point
#   bash setup.sh --from 3              # force start from step 3
#   SKIP_GPU=1 bash setup.sh            # VPS with no GPU
#   MODEL=Qwen/Qwen2.5-0.5B-Instruct bash setup.sh

set -euo pipefail

# ── Config (override with env vars) ──────────────────────────────────────────

export MODEL="${MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"
export MODEL_NAME="${MODEL_NAME:-qwen}"
export VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:v0.8.5}"
export MAX_MODEL_LEN="${MAX_MODEL_LEN:-2048}"
export GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.82}"
export MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
export INSTALL_DIR="${INSTALL_DIR:-$HOME/llm-starter}"
export SKIP_GPU="${SKIP_GPU:-0}"
export HF_TOKEN="${HF_TOKEN:-}"

# ── Resolve script directory ──────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES="$SCRIPT_DIR/modules"

source "$MODULES/lib.sh"

# ── Auto-detect resume point ──────────────────────────────────────────────────

detect_from_step() {
  # Step 1: base packages present?
  command -v curl &>/dev/null && command -v git &>/dev/null && command -v python3 &>/dev/null \
    || { echo 1; return; }

  # Step 2: docker installed?
  command -v docker &>/dev/null \
    || { echo 2; return; }

  # Step 3: nvidia runtime wired into docker? (fast check — no image pull)
  if [[ "$SKIP_GPU" != "1" ]]; then
    docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia \
      || { echo 3; return; }
  fi

  # Step 4: stack files written?
  [[ -f "$INSTALL_DIR/docker-compose.yml" ]] \
    || { echo 4; return; }

  # Step 5: containers running?
  docker compose -f "$INSTALL_DIR/docker-compose.yml" ps --status running 2>/dev/null \
    | grep -q "running" \
    || { echo 5; return; }

  # Step 6: always re-verify if everything else is done
  echo 6
}

# ── Parse --from N (overrides auto-detect) ────────────────────────────────────

if [[ "${1:-}" == "--from" && -n "${2:-}" ]]; then
  FROM_STEP="$2"
  info "Resuming from step $FROM_STEP (manual override)"
else
  FROM_STEP="$(detect_from_step)"
  info "Auto-detected resume point: step $FROM_STEP"
fi

# ── Banner ────────────────────────────────────────────────────────────────────

echo -e "${BOLD}${BLUE}"
echo "╔══════════════════════════════════════════╗"
echo "║   LLM Stack Setup                        ║"
printf "║   Model : %-31s║\n" "$MODEL_NAME"
printf "║   GPU   : %-31s║\n" "$([ "$SKIP_GPU" == "1" ] && echo "skipped (CPU mode)" || echo "enabled")"
printf "║   Dir   : %-31s║\n" "$INSTALL_DIR"
printf "║   Resuming from step %-20s║\n" "$FROM_STEP"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ── Run steps ─────────────────────────────────────────────────────────────────

run_step() {
  local num="$1" label="$2" script="$3"
  if [[ "$num" -ge "$FROM_STEP" ]]; then
    step "$num/6  $label"
    bash "$MODULES/$script"
  else
    info "Skipping step $num ($label) — already done"
  fi
}

run_step 1 "System packages"   "01_system.sh"
run_step 2 "Docker"            "02_docker.sh"
run_step 3 "NVIDIA toolkit"    "03_nvidia.sh"
run_step 4 "Writing files"     "04_write_stack.sh"
run_step 5 "Starting stack"    "05_start_stack.sh"
run_step 6 "Verifying"         "06_verify.sh"
