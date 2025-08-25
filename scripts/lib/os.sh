#!/usr/bin/env bash
set -euo pipefail

OS_NAME="unknown"
OS_FAMILY="unknown" # linux | macos | wsl | unknown
PKG_MGR=""

detect_platform() {
  local unameOut
  unameOut="$(uname -s)"
  case "$unameOut" in
    Linux*) OS_NAME=Linux ;;
    Darwin*) OS_NAME=Darwin ;;
    *) OS_NAME="$unameOut" ;;
  esac

  if [[ "$OS_NAME" == "Darwin" ]]; then
    OS_FAMILY="macos"
    if command -v brew >/dev/null 2>&1; then PKG_MGR="brew"; fi
  elif [[ "$OS_NAME" == "Linux" ]]; then
    if grep -qi microsoft /proc/version 2>/dev/null || grep -qi wsl /proc/version 2>/dev/null; then
      OS_FAMILY="wsl"
    else
      OS_FAMILY="linux"
    fi
    if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt-get";
    elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf";
    elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum";
    elif command -v zypper >/dev/null 2>&1; then PKG_MGR="zypper";
    elif command -v pacman >/dev/null 2>&1; then PKG_MGR="pacman"; fi
  fi
}

try_install_packages() {
  # Usage: try_install_packages pkg1 pkg2 ...
  if [[ -z "${PKG_MGR:-}" ]]; then
    echo "No package manager detected; skipping install of: $*" >&2
    return 1
  fi
  case "$PKG_MGR" in
    brew)
      brew install "$@" || true ;;
    apt-get)
      sudo apt-get update -y || true
      sudo apt-get install -y "$@" || true ;;
    dnf)
      sudo dnf install -y "$@" || true ;;
    yum)
      sudo yum install -y "$@" || true ;;
    zypper)
      sudo zypper install -y "$@" || true ;;
    pacman)
      sudo pacman -Sy --noconfirm "$@" || true ;;
    *)
      echo "Unsupported package manager: $PKG_MGR" >&2
      return 1 ;;
  esac
}

