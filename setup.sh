#!/usr/bin/env bash
# setup.sh — on-prem LLM stack bootstrapper
#
# Usage:
#   bash setup.sh                        # auto-skips completed steps, runs eligible ones in parallel
#   bash setup.sh --from 3              # force re-run from step 3 onwards
#   bash setup.sh --dry-run             # show what would run without executing anything
#   bash setup.sh --from 3 --dry-run    # combine both
#   SKIP_GPU=1 bash setup.sh
#   MODEL=Qwen/Qwen2.5-0.5B-Instruct bash setup.sh
#
# Execution waves (steps in the same wave run in parallel):
#   Wave 1 : Step 1  — system packages   (apt baseline, must be first)
#   Wave 2 : Step 2  — docker            \  no dependency between these two
#            Step 4  — write stack files /
#   Wave 3 : Step 3  — nvidia toolkit    (needs docker from wave 2)
#   Wave 4 : Step 5  — start stack       (needs steps 3 + 4 both done)
#   Wave 5 : Step 6  — verify

# ── Bootstrap: My-dev-setup ───────────────────────────────────────────────────
_DEV_SETUP="/tmp/My-dev-setup"
if [[ ! -d "$_DEV_SETUP/.git" ]]; then
    echo "Cloning My-dev-setup → $_DEV_SETUP ..."
    git clone https://github.com/KarneeshkarV/My-dev-setup/ "$_DEV_SETUP"
fi

# ── Delegate non-flag args to My-dev-setup/run.sh ────────────────────────────
for _a in "$@"; do
    if [[ "$_a" != --* ]]; then
        exec "$_DEV_SETUP/run.sh" "$@"
    fi
done

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

export MODEL="${MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"
export MODEL_NAME="${MODEL_NAME:-qwen}"
export VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:v0.8.5}"
export MAX_MODEL_LEN="${MAX_MODEL_LEN:-2048}"
export GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.82}"
export MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
export INSTALL_DIR="${INSTALL_DIR:-$HOME/llm-starter}"
export SKIP_GPU="${SKIP_GPU:-0}"
export HF_TOKEN="${HF_TOKEN:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES="$SCRIPT_DIR/modules"
source "$MODULES/lib.sh"

# ── Require uv ────────────────────────────────────────────────────────────────
if ! command -v uv &>/dev/null; then
    info "uv not found — installing via My-dev-setup runs/python.sh ..."
    bash "$_DEV_SETUP/runs/python.sh"
    [[ -f "$HOME/.local/bin/env" ]] && source "$HOME/.local/bin/env"
fi
command -v uv &>/dev/null || die "uv is required but could not be installed"
info "uv $(uv --version) — ready"

# ── Parse flags ───────────────────────────────────────────────────────────────

FORCE_FROM=0
DRY_RUN=0
args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  case "${args[$i]}" in
    --from)
      ((i++)) || true
      FORCE_FROM="${args[$i]}"
      info "--from $FORCE_FROM: forcing re-run of steps $FORCE_FROM and above"
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    *)
      warn "Unknown flag: ${args[$i]}"
      ;;
  esac
  ((i++)) || true
done

# ── Per-step completion checks ────────────────────────────────────────────────
# Returns 0 (already done → skip) or 1 (needs to run)

step_done() {
  local n="$1"
  # --from N forces every step >= N to re-run regardless of state
  [[ "$FORCE_FROM" -gt 0 && "$n" -ge "$FORCE_FROM" ]] && return 1
  case "$n" in
    1) command -v curl &>/dev/null && command -v git &>/dev/null && command -v python3 &>/dev/null ;;
    2) command -v docker &>/dev/null ;;
    3) [[ "$SKIP_GPU" == "1" ]] || docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia ;;
    4) [[ -f "$INSTALL_DIR/docker-compose.yml" ]] ;;
    5) docker compose -f "$INSTALL_DIR/docker-compose.yml" ps --status running 2>/dev/null | grep -q "running" ;;
    *) return 1 ;;
  esac
}

# ── Serial runner ─────────────────────────────────────────────────────────────

run_if_needed() {
  local num="$1" label="$2" script="$3"
  if step_done "$num"; then
    info "↩  Step $num ($label) — already done, skipping"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "  ${YELLOW}[DRY-RUN]${NC}  would run: Step $num — $label  ($script)"
    return 0
  fi
  step "$num/6  $label"
  bash "$MODULES/$script"
}

# ── Parallel runner ───────────────────────────────────────────────────────────
# Accepts "num:label:script" tokens. Skips done steps; runs the rest in parallel.
# Each parallel step's output is prefixed with [step-N] so lines don't blur together.

run_parallel() {
  local to_run=()

  for spec in "$@"; do
    local num label script
    IFS=: read -r num label script <<< "$spec"
    if step_done "$num"; then
      info "↩  Step $num ($label) — already done, skipping"
    else
      to_run+=("$spec")
    fi
  done

  [[ ${#to_run[@]} -eq 0 ]] && return 0

  # Only one step left — no benefit to parallel overhead
  if [[ ${#to_run[@]} -eq 1 ]]; then
    local num label script
    IFS=: read -r num label script <<< "${to_run[0]}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo -e "  ${YELLOW}[DRY-RUN]${NC}  would run: Step $num — $label  ($script)"
      return 0
    fi
    step "$num/6  $label"
    bash "$MODULES/$script"
    return
  fi

  # Dry-run: list all steps that would run in parallel
  if [[ "$DRY_RUN" -eq 1 ]]; then
    local spec num label script
    for spec in "${to_run[@]}"; do
      IFS=: read -r num label script <<< "$spec"
      echo -e "  ${YELLOW}[DRY-RUN]${NC}  would run: Step $num — $label  ($script)  [in parallel]"
    done
    return 0
  fi

  # Two or more — launch each in its own subshell, prefix output, track exit codes
  local pids=() exit_files=() labels=()

  for spec in "${to_run[@]}"; do
    local num label script ef
    IFS=: read -r num label script <<< "$spec"
    ef=$(mktemp /tmp/llm-step-XXXXXX.exit)
    step "$num/6  $label  [parallel ▶]"
    (
      set +e
      bash "$MODULES/$script" 2>&1 | sed -u "s/^/  [step-$num] /"
      echo "${PIPESTATUS[0]}" > "$ef"
    ) &
    pids+=($!)
    exit_files+=("$ef")
    labels+=("Step $num: $label")
  done

  local running_list="${labels[*]}"
  info "Waiting for parallel wave: ${running_list// /, } ..."

  local i=0 failed=0
  for pid in "${pids[@]}"; do
    wait "$pid" || true
    local code; code=$(cat "${exit_files[$i]}" 2>/dev/null || echo 1)
    if [[ "$code" -eq 0 ]]; then
      ok "${labels[$i]} — done"
    else
      warn "${labels[$i]} — FAILED (exit $code)"
      ((failed++)) || true
    fi
    rm -f "${exit_files[$i]}"
    ((i++)) || true
  done

  [[ $failed -eq 0 ]] || die "$failed step(s) failed in parallel wave — see output above"
}

# ── Banner ────────────────────────────────────────────────────────────────────

echo -e "${BOLD}${BLUE}"
echo "╔══════════════════════════════════════════╗"
echo "║   LLM Stack Setup                        ║"
printf "║   Model : %-31s║\n" "$MODEL_NAME"
printf "║   GPU   : %-31s║\n" "$([ "$SKIP_GPU" == "1" ] && echo "skipped (CPU mode)" || echo "enabled")"
printf "║   Dir   : %-31s║\n" "$INSTALL_DIR"
printf "║   Mode  : %-31s║\n" "$([ "$DRY_RUN" -eq 1 ] && echo "DRY-RUN (no changes)" || echo "auto-resume + parallel waves")"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ── Execution plan ────────────────────────────────────────────────────────────

# Wave 1 — apt must finish before anything else touches the package manager
run_if_needed 1 "System packages" "01_system.sh"

# Wave 2 — docker install and file writing share no resources; run in parallel
run_parallel \
  "2:Docker:02_docker.sh" \
  "4:Write stack files:04_write_stack.sh"

# Wave 3 — nvidia toolkit: needs docker daemon running (wave 2 must finish first)
run_if_needed 3 "NVIDIA toolkit" "03_nvidia.sh"

# Wave 4 — start the stack: needs nvidia wired (step 3) and files written (step 4)
run_if_needed 5 "Start stack" "05_start_stack.sh"

# Wave 5 — verify everything is healthy
run_if_needed 6 "Verify" "06_verify.sh"
