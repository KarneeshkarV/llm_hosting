#!/usr/bin/env bash
# modules/lib.sh — shared colours and helper functions

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}${BLUE}──── $* ────${NC}"; }
require() { command -v "$1" &>/dev/null || die "'$1' not found — $2"; }
