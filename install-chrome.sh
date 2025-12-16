#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------------------
# Contributed by Teams, Work. Ltd. https://teams-work.co.uk
# Author: Ignat Alexeyenko
#
# BSD 2-Clause License
#
# Copyright (c) 2025, Teams, Work. Ltd.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# ----------------------------------------------------------------------

# ==========================================================
# install-chrome.sh (macOS-friendly, bash 3.2 compatible)
# ==========================================================

# If someone runs it with sh by accident, fail loudly.
if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "ERROR: This script must be run with bash. Try: bash ./install-chrome.sh" >&2
  exit 1
fi

# =========================
# Defaults (override via env)
# =========================
DEFAULT_VERSION="${CHROME_VERSION:-143.0.7499.146}"
DEFAULT_INSTALL_DIR="${CHROME_INSTALL_DIR:-/Applications}"
DEFAULT_BIN_DIR="${CHROME_BIN_DIR:-/usr/local/bin}"
DEFAULT_PLATFORM_OVERRIDE="${CHROME_PLATFORM:-}"      # mac-arm64|mac-x64 (empty = auto)

DEFAULT_INSTALL_BROWSER="${INSTALL_BROWSER:-true}"
DEFAULT_INSTALL_DRIVER="${INSTALL_DRIVER:-true}"
DEFAULT_INSTALL_HEADLESS="${INSTALL_HEADLESS:-false}"

DEFAULT_DRY_RUN="${DRY_RUN:-false}"
DEFAULT_FORCE="${FORCE:-false}"

# =========================
# Helpers
# =========================
die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*" >&2; }
warn() { echo "WARN: $*" >&2; }

print_cmd() {
  echo ""
  echo ">>> Executing:"
  printf '%s \\\n' "$@" | sed '$ s/ \\$//'
  echo ""
}

have() { command -v "$1" >/dev/null 2>&1; }
need_cmd() { have "$1" || die "Missing required command: $1"; }

# lowercase without ${var,,} (bash 3.2 compatible)
lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

# Read with default; -e enables readline editing if available
prompt() {
  local label="$1"
  local default="${2:-}"
  local var=""
  if [[ -t 0 ]]; then
    # -e works in bash 3.2 too (readline editing)
    read -r -e -p "${label} [${default}]: " var || true
  fi
  [[ -z "$var" ]] && echo "$default" || echo "$var"
}

prompt_yesno() {
  local label="$1"
  local default_bool="${2:-false}" # true|false
  local def_char="n"
  [[ "$default_bool" == "true" ]] && def_char="y"

  local ans
  ans="$(prompt "${label} (y/n)" "${def_char}")"
  ans="$(lower "$ans")"

  case "$ans" in
    y|yes) echo "true" ;;
    n|no)  echo "false" ;;
    *)     echo "$default_bool" ;;
  esac
}

detect_platform() {
  local arch
  arch="$(uname -m)"
  if [[ -n "${DEFAULT_PLATFORM_OVERRIDE}" ]]; then
    echo "${DEFAULT_PLATFORM_OVERRIDE}"
    return
  fi
  if [[ "$arch" == "arm64" ]]; then
    echo "mac-arm64"
  else
    echo "mac-x64"
  fi
}

base_url_for() {
  local ver="$1" platform="$2"
  echo "https://storage.googleapis.com/chrome-for-testing-public/${ver}/${platform}"
}

tmpdir_new() {
  mktemp -d
}

# Decide if sudo is needed for a target path (directory or file path)
needs_sudo_for_path() {
  local target="$1"
  local dir="$target"

  # If user passed a file path, take parent dir
  if [[ -e "$target" && ! -d "$target" ]]; then
    dir="$(dirname "$target")"
  fi

  # If dir doesn't exist, check parent
  if [[ ! -d "$dir" ]]; then
    dir="$(dirname "$dir")"
  fi

  [[ -w "$dir" ]] && return 1 || return 0
}

sudo_if_needed() {
  local target="$1"
  if needs_sudo_for_path "$target"; then
    info "No write access to: $target"
    info "Will use sudo for install steps that write there."
    sudo -v >/dev/null
    return 0
  fi
  return 1
}

# =========================
# Installers
# =========================
install_browser() {
  local ver="$1" platform="$2" install_dir="$3" dry_run="$4" force="$5"
  local base url zip tmp

  base="$(base_url_for "$ver" "$platform")"
  url="${base}/chrome-${platform}.zip"
  zip="/tmp/chrome-${ver}-${platform}.zip"
  tmp="$(tmpdir_new)"

  info "Chrome for Testing: version=${ver}, platform=${platform}"
  info "Download: ${url}"

  if [[ "$dry_run" == "true" ]]; then
    print_cmd curl -L -o "$zip" "$url"
    print_cmd unzip -q "$zip" -d "$tmp"
    print_cmd mv "\"$tmp/chrome-${platform}/Google Chrome for Testing.app\"" "\"$install_dir/\""
    return
  fi

  curl -L -o "$zip" "$url"
  unzip -q "$zip" -d "$tmp"

  local app_src="$tmp/chrome-${platform}/Google Chrome for Testing.app"
  local app_dst="$install_dir/Google Chrome for Testing.app"
  [[ -d "$app_src" ]] || die "Unzip succeeded but app not found at: $app_src"

  local use_sudo="false"
  if sudo_if_needed "$install_dir"; then use_sudo="true"; fi

  if [[ -e "$app_dst" ]]; then
    if [[ "$force" == "true" ]]; then
      info "Removing existing: $app_dst"
      if [[ "$use_sudo" == "true" ]]; then sudo rm -rf "$app_dst"; else rm -rf "$app_dst"; fi
    else
      warn "Already exists: $app_dst (use --force to overwrite)"
      return
    fi
  fi

  info "Installing to: $app_dst"
  if [[ "$use_sudo" == "true" ]]; then
    sudo mv "$app_src" "$install_dir/"
  else
    mv "$app_src" "$install_dir/"
  fi
  info "Done: $app_dst"
}

install_chromedriver() {
  local ver="$1" platform="$2" bin_dir="$3" dry_run="$4" force="$5"
  local base url zip tmp

  base="$(base_url_for "$ver" "$platform")"
  url="${base}/chromedriver-${platform}.zip"
  zip="/tmp/chromedriver-${ver}-${platform}.zip"
  tmp="$(tmpdir_new)"

  info "ChromeDriver: version=${ver}, platform=${platform}"
  info "Download: ${url}"

  if [[ "$dry_run" == "true" ]]; then
    print_cmd curl -L -o "$zip" "$url"
    print_cmd unzip -q "$zip" -d "$tmp"
    print_cmd mkdir -p "\"$bin_dir\""
    print_cmd mv "\"$tmp/chromedriver-${platform}/chromedriver\"" "\"$bin_dir/chromedriver\""
    print_cmd chmod +x "\"$bin_dir/chromedriver\""
    return
  fi

  curl -L -o "$zip" "$url"
  unzip -q "$zip" -d "$tmp"

  local driver_src="$tmp/chromedriver-${platform}/chromedriver"
  [[ -f "$driver_src" ]] || die "Driver binary not found at: $driver_src"

  local use_sudo="false"
  if sudo_if_needed "$bin_dir"; then use_sudo="true"; fi

  if [[ "$use_sudo" == "true" ]]; then
    sudo mkdir -p "$bin_dir"
  else
    mkdir -p "$bin_dir"
  fi

  local dst="$bin_dir/chromedriver"
  if [[ -e "$dst" && "$force" != "true" ]]; then
    warn "Already exists: $dst (use --force to overwrite)"
    return
  fi

  if [[ "$use_sudo" == "true" ]]; then
    sudo mv "$driver_src" "$dst"
    sudo chmod +x "$dst"
  else
    mv "$driver_src" "$dst"
    chmod +x "$dst"
  fi
  info "Done: $dst"
}

install_headless_shell() {
  local ver="$1" platform="$2" bin_dir="$3" dry_run="$4" force="$5"
  local base url zip tmp

  base="$(base_url_for "$ver" "$platform")"
  url="${base}/chrome-headless-shell-${platform}.zip"
  zip="/tmp/chrome-headless-shell-${ver}-${platform}.zip"
  tmp="$(tmpdir_new)"

  info "chrome-headless-shell: version=${ver}, platform=${platform}"
  info "Download: ${url}"

  if [[ "$dry_run" == "true" ]]; then
    print_cmd curl -L -o "$zip" "$url"
    print_cmd unzip -q "$zip" -d "$tmp"
    print_cmd mkdir -p "\"$bin_dir\""
    print_cmd mv "\"$tmp/chrome-headless-shell-${platform}/chrome-headless-shell\"" "\"$bin_dir/chrome-headless-shell\""
    print_cmd chmod +x "\"$bin_dir/chrome-headless-shell\""
    return
  fi

  curl -L -o "$zip" "$url"
  unzip -q "$zip" -d "$tmp"

  local src="$tmp/chrome-headless-shell-${platform}/chrome-headless-shell"
  [[ -f "$src" ]] || die "Headless shell binary not found at: $src"

  local use_sudo="false"
  if sudo_if_needed "$bin_dir"; then use_sudo="true"; fi

  if [[ "$use_sudo" == "true" ]]; then
    sudo mkdir -p "$bin_dir"
  else
    mkdir -p "$bin_dir"
  fi

  local dst="$bin_dir/chrome-headless-shell"
  if [[ -e "$dst" && "$force" != "true" ]]; then
    warn "Already exists: $dst (use --force to overwrite)"
    return
  fi

  if [[ "$use_sudo" == "true" ]]; then
    sudo mv "$src" "$dst"
    sudo chmod +x "$dst"
  else
    mv "$src" "$dst"
    chmod +x "$dst"
  fi
  info "Done: $dst"
}

show_post_install() {
  local install_dir="$1" bin_dir="$2"
  cat <<EOF

Next steps / sanity checks:

1) Browser:
   "${install_dir}/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" --version

2) ChromeDriver:
   "${bin_dir}/chromedriver" --version

3) Selenium hint (Python):
   options.binary_location = "${install_dir}/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
   service = Service("${bin_dir}/chromedriver")

EOF
}

show_help() {
  cat <<EOF
Usage:
  ./install-chrome.sh [command] [options]

Commands:
  menu                 Interactive mode (default if no args)
  install              Install based on provided options (non-interactive)
  help                 Show help

Options:
  --version <v>         Chrome for Testing version (default: ${DEFAULT_VERSION})
  --platform <p>        mac-arm64|mac-x64 (default: auto-detect)
  --install-dir <dir>   Where to place .app (default: ${DEFAULT_INSTALL_DIR})
  --bin-dir <dir>       Where to place binaries (default: ${DEFAULT_BIN_DIR})

  --browser|--no-browser
  --driver|--no-driver
  --headless|--no-headless

  --dry-run
  --force               Overwrite existing installs
  --no-interactive      Disallow menu if stdin isn't a TTY

Examples:
  ./install-chrome.sh
  ./install-chrome.sh install --version 142.0.7444.134 --browser --driver --force
  ./install-chrome.sh install --version 142.0.7444.134 --no-browser --driver --headless --force

EOF
}

interactive_menu() {
  local version platform install_dir bin_dir
  local install_browser_flag install_driver_flag install_headless_flag
  local dry_run force

  version="$(prompt "Chrome version (Chrome for Testing)" "$DEFAULT_VERSION")"
  platform="$(prompt "Platform (mac-arm64 or mac-x64, empty=auto)" "${DEFAULT_PLATFORM_OVERRIDE:-}")"
  if [[ -z "$platform" ]]; then platform="$(detect_platform)"; fi

  install_dir="$(prompt "Install dir for .app" "$DEFAULT_INSTALL_DIR")"
  bin_dir="$(prompt "Bin dir for chromedriver/headless-shell" "$DEFAULT_BIN_DIR")"

  install_browser_flag="$(prompt_yesno "Install browser (.app)" "$DEFAULT_INSTALL_BROWSER")"
  install_driver_flag="$(prompt_yesno "Install chromedriver" "$DEFAULT_INSTALL_DRIVER")"
  install_headless_flag="$(prompt_yesno "Install chrome-headless-shell (no UI)" "$DEFAULT_INSTALL_HEADLESS")"

  dry_run="$(prompt_yesno "Dry run (print commands only)" "$DEFAULT_DRY_RUN")"
  force="$(prompt_yesno "Force overwrite existing installs" "$DEFAULT_FORCE")"

  echo ""
  echo "======== Summary ========"
  echo "Version:    $version"
  echo "Platform:   $platform"
  echo "InstallDir: $install_dir"
  echo "BinDir:     $bin_dir"
  echo "Browser:    $install_browser_flag"
  echo "Driver:     $install_driver_flag"
  echo "Headless:   $install_headless_flag"
  echo "DryRun:     $dry_run"
  echo "Force:      $force"
  echo "========================="
  echo ""

  local go
  go="$(prompt_yesno "Proceed" "true")"
  [[ "$go" == "true" ]] || { info "Cancelled."; exit 0; }

  do_install "$version" "$platform" "$install_dir" "$bin_dir" \
    "$install_browser_flag" "$install_driver_flag" "$install_headless_flag" \
    "$dry_run" "$force"

  show_post_install "$install_dir" "$bin_dir"
}

do_install() {
  local version="$1" platform="$2" install_dir="$3" bin_dir="$4"
  local install_browser_flag="$5" install_driver_flag="$6" install_headless_flag="$7"
  local dry_run="$8" force="$9"

  need_cmd curl
  need_cmd unzip

  if [[ "$install_browser_flag" == "true" ]]; then
    install_browser "$version" "$platform" "$install_dir" "$dry_run" "$force"
  fi
  if [[ "$install_driver_flag" == "true" ]]; then
    install_chromedriver "$version" "$platform" "$bin_dir" "$dry_run" "$force"
  fi
  if [[ "$install_headless_flag" == "true" ]]; then
    install_headless_shell "$version" "$platform" "$bin_dir" "$dry_run" "$force"
  fi
}

# =========================
# Arg parsing
# =========================
cmd="${1:-menu}"
shift || true

version="$DEFAULT_VERSION"
platform="$(detect_platform)"
install_dir="$DEFAULT_INSTALL_DIR"
bin_dir="$DEFAULT_BIN_DIR"

install_browser_flag="$DEFAULT_INSTALL_BROWSER"
install_driver_flag="$DEFAULT_INSTALL_DRIVER"
install_headless_flag="$DEFAULT_INSTALL_HEADLESS"

dry_run="$DEFAULT_DRY_RUN"
force="$DEFAULT_FORCE"
no_interactive="false"

while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --version) version="${2:-}"; shift 2 ;;
    --platform) platform="${2:-}"; shift 2 ;;
    --install-dir) install_dir="${2:-}"; shift 2 ;;
    --bin-dir) bin_dir="${2:-}"; shift 2 ;;

    --browser) install_browser_flag="true"; shift ;;
    --no-browser) install_browser_flag="false"; shift ;;
    --driver) install_driver_flag="true"; shift ;;
    --no-driver) install_driver_flag="false"; shift ;;
    --headless) install_headless_flag="true"; shift ;;
    --no-headless) install_headless_flag="false"; shift ;;

    --dry-run) dry_run="true"; shift ;;
    --force) force="true"; shift ;;
    --no-interactive) no_interactive="true"; shift ;;

    --help|-h) show_help; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

case "$cmd" in
  help|-h|--help) show_help ;;
  menu)
    if [[ "$no_interactive" == "true" || ! -t 0 ]]; then
      die "Interactive mode needs a TTY. Use: ./install-chrome.sh install ..."
    fi
    interactive_menu
    ;;
  install)
    do_install "$version" "$platform" "$install_dir" "$bin_dir" \
      "$install_browser_flag" "$install_driver_flag" "$install_headless_flag" \
      "$dry_run" "$force"
    show_post_install "$install_dir" "$bin_dir"
    ;;
  *)
    die "Unknown command: $cmd (try './install-chrome.sh help')"
    ;;
esac