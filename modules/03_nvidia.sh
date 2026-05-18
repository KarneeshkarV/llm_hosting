#!/usr/bin/env bash
# modules/03_nvidia.sh — Step 3: Install NVIDIA Container Toolkit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

: "${SKIP_GPU:=0}"

install_nvidia() {
  if [[ "$SKIP_GPU" == "1" ]]; then
    warn "SKIP_GPU=1 — skipping NVIDIA toolkit"
    return
  fi

  if ! command -v nvidia-smi &>/dev/null; then
    die "nvidia-smi not found. Install the NVIDIA driver first, then re-run."
  fi

  if docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi &>/dev/null; then
    ok "NVIDIA Container Toolkit already working"
    return
  fi

  info "Installing NVIDIA Container Toolkit..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

  sudo apt-get update -qq
  sudo apt-get install -y -qq nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker

  info "Verifying GPU is visible to Docker..."
  docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi \
    || die "Docker cannot see the GPU. Check your driver and toolkit install."
  ok "NVIDIA Container Toolkit ready"
}

install_nvidia
