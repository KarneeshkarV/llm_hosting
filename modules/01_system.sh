#!/usr/bin/env bash
# modules/01_system.sh — Step 1: Install system packages

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

install_system() {
  info "Updating apt and installing base packages..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    curl wget git ca-certificates gnupg lsb-release \
    python3 python3-pip apt-transport-https software-properties-common
  ok "System packages ready"
}

install_system
