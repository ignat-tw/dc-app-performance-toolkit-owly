#!/usr/bin/env bash
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

set -euo pipefail

# =========================
# Config
# =========================
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_IMAGE_RUN="atlassian/dcapt"
DOCKER_IMAGE_REPORTS="atlassian/dcapt"

DEFAULT_PLATFORM="linux/amd64"
DEFAULT_SHM="4g"

APP_DIR="/dc-app-performance-toolkit/app"
REPORTS_DIR="/dc-app-performance-toolkit/app/reports_generation"

# Known config files (local paths relative to repo root)
JIRA_YML="${REPO_ROOT}/app/jira.yml"
CONF_YML="${REPO_ROOT}/app/confluence.yml"

PYTHON_VERSION_DEFAULT="3.13.1"
REQUIREMENTS_TXT="${REPO_ROOT}/requirements.txt"

# =========================
# Helpers
# =========================
die() { echo "ERROR: $*" >&2; exit 1; }

print_cmd() {
  echo ""
  echo ">>> Executing:"
  # print with line breaks for readability
  printf '%s \\\n' "$@" | sed '$ s/ \\$//'
  echo ""
}

ensure_file() {
  local f="$1"
  [[ -f "$f" ]] || die "File not found: $f"
}

ensure_repo_layout() {
  [[ -d "${REPO_ROOT}/app" ]] || die "Expected ${REPO_ROOT}/app to exist. Run from dc-app-performance-toolkit repo root."
}

# =========================
# Help / targets
# =========================
show_help() {
  cat <<EOF
Usage:
  ./run.sh <target> [options]

Targets:
  jira                  Run DCAPT locally using app/jira.yml
  confluence            Run DCAPT locally using app/confluence.yml
  run <file.yml>        Run DCAPT locally using a specific yml (relative or absolute)
  reports perf          Generate performance regression report (uses app/reports_generation/performance_profile.yml)
  reports scale         Generate scalability report (uses app/reports_generation/scale_profile.yml)
  list                  Show available targets and detected config files
  help                  Show this help

  install-pyenv         Install pyenv (macOS via brew) + add shell init snippet
  install-python [ver]  Install Python via pyenv and set repo-local version (.python-version)
  install-deps          Install python deps from requirements.txt
  run-local jira        Run bzt locally against app/jira.yml (no docker)
  run-local confluence  Run bzt locally against app/confluence.yml (no docker)

Options:
  --platform <p>        Docker platform (default: ${DEFAULT_PLATFORM})
  --shm <size>          Docker shm-size (default: ${DEFAULT_SHM})
  --pull                Add --pull=always to docker run
  --visible             Export WEBDRIVER_VISIBLE=True inside container (Selenium Chrome visible)
  --dry-run             Print docker command but do not execute

Examples:
  ./run.sh jira
  ./run.sh confluence --visible
  ./run.sh run app/jira.yml
  ./run.sh reports perf
  ./run.sh reports scale --pull

  ./run.sh install-pyenv
  ./run.sh install-python 3.13.1
  ./run.sh install-deps
  ./run.sh run-local jira

Notes:
  - This script runs the toolkit from the local repo using docker.
  - It does NOT do k8s / terraform. Only the "run toolkit locally" + "generate reports" workflows.
EOF
}

list_targets() {
  ensure_repo_layout
  echo "Available targets:"
  echo "  - jira"
  echo "  - confluence"
  echo "  - run <file.yml>"
  echo "  - reports perf"
  echo "  - reports scale"
  echo ""
  echo "Detected config files:"
  [[ -f "$JIRA_YML" ]] && echo "  - app/jira.yml" || echo "  - app/jira.yml (missing)"
  [[ -f "$CONF_YML" ]] && echo "  - app/confluence.yml" || echo "  - app/confluence.yml (missing)"
  echo ""
  echo "Repo root:"
  echo "  ${REPO_ROOT}"
}

# =========================
# Docker runners
# =========================
run_dcapt_yml() {
  local yml_path="$1"
  local platform="$2"
  local shm="$3"
  local pull_flag="$4"
  local webdriver_visible="$5"
  local dry_run="$6"

  ensure_repo_layout
  ensure_file "$yml_path"

  local -a cmd=(
    docker run --rm --init
    --platform="${platform}"
    --shm-size="${shm}"
  )

  if [[ "$pull_flag" == "true" ]]; then
    cmd+=( --pull=always )
  fi

  # Mount repo into container
  cmd+=(
    -v "${REPO_ROOT}:/dc-app-performance-toolkit"
    -w "${APP_DIR}"
  )

  if [[ "$webdriver_visible" == "true" ]]; then
    cmd+=( -e WEBDRIVER_VISIBLE=True )
  fi

  # image + arg
  cmd+=( "${DOCKER_IMAGE_RUN}" "$(basename "$yml_path")" )

  # DCAPT expects the yml in /dc-app-performance-toolkit/app when invoked like "dcapt jira.yml"
  # If user passed a yml that is not under app/, we copy it into app/ temporarily.
  local yml_dir
  yml_dir="$(cd "$(dirname "$yml_path")" && pwd)"
  local app_local_dir="${REPO_ROOT}/app"

  if [[ "$yml_dir" != "$app_local_dir" ]]; then
    echo "INFO: YML is not in app/. Copying into app/ for this run..."
    local tmp_name="_tmp_$(basename "$yml_path")"
    cp -f "$yml_path" "${REPO_ROOT}/app/${tmp_name}"
    # update command to use tmp file name
    cmd[-1]="${tmp_name}"
    yml_path="${REPO_ROOT}/app/${tmp_name}"
  fi

  print_cmd "${cmd[@]}"

  if [[ "$dry_run" == "true" ]]; then
    echo "DRY RUN: not executing."
  else
    "${cmd[@]}"
  fi
}

run_reports() {
  local mode="$1"           # perf | scale
  local platform="$2"
  local pull_flag="$3"
  local dry_run="$4"

  ensure_repo_layout

  local profile_yml=""
  if [[ "$mode" == "perf" ]]; then
    profile_yml="performance_profile.yml"
    ensure_file "${REPO_ROOT}/app/reports_generation/${profile_yml}"
  elif [[ "$mode" == "scale" ]]; then
    profile_yml="scale_profile.yml"
    ensure_file "${REPO_ROOT}/app/reports_generation/${profile_yml}"
  else
    die "Unknown reports mode: $mode (expected perf|scale)"
  fi

  local -a cmd=(
    docker run --rm --init
    --platform="${platform}"
  )

  if [[ "$pull_flag" == "true" ]]; then
    cmd+=( --pull=always )
  fi

  cmd+=(
    -v "${REPO_ROOT}:/dc-app-performance-toolkit"
    --workdir="${REPORTS_DIR}"
    --entrypoint="python"
    -it
    "${DOCKER_IMAGE_REPORTS}"
    csv_chart_generator.py "${profile_yml}"
  )

  print_cmd "${cmd[@]}"

  if [[ "$dry_run" == "true" ]]; then
    echo "DRY RUN: not executing."
  else
    "${cmd[@]}"
  fi
}

# =========================

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_pyenv_init_hint() {
  cat <<'EOF'
INFO: If pyenv is installed but 'python' is still not found, add to ~/.zshrc:

  export PYENV_ROOT="$HOME/.pyenv"
  command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"
  eval "$(pyenv init -)"

Then run:
  source ~/.zshrc
EOF
}

install_pyenv_macos() {
  if have_cmd pyenv; then
    echo "INFO: pyenv already installed: $(pyenv --version)"
    return 0
  fi
  if ! have_cmd brew; then
    die "Homebrew not found. Install brew first: https://brew.sh"
  fi

  echo "==> Installing pyenv via brew..."
  brew update
  brew install pyenv

  echo "==> Adding pyenv init to ~/.zshrc (if missing)..."
  local zshrc="${HOME}/.zshrc"
  grep -q 'eval "$(pyenv init -)"' "$zshrc" 2>/dev/null || cat >>"$zshrc" <<'EOF'

# pyenv
export PYENV_ROOT="$HOME/.pyenv"
command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
EOF

  ensure_pyenv_init_hint
}

install_python_with_pyenv() {
  local pyver="${1:-$PYTHON_VERSION_DEFAULT}"
  have_cmd pyenv || die "pyenv is not installed. Run: ./run.sh install-pyenv"

  echo "==> Installing Python ${pyver} (if missing)..."
  pyenv install -s "${pyver}"

  echo "==> Setting repo-local python to ${pyver}"
  (cd "${REPO_ROOT}" && pyenv local "${pyver}")

  pyenv rehash

  echo "==> Verifying python..."
  python -V || {
    echo "WARN: 'python' not found in current shell (pyenv not initialized)."
    ensure_pyenv_init_hint
    exit 1
  }
}

install_python_deps() {
  local pyver="${1:-$PYTHON_VERSION_DEFAULT}"
  [[ -f "${REQUIREMENTS_TXT}" ]] || die "Missing ${REQUIREMENTS_TXT}"

  if ! have_cmd python; then
    echo "INFO: python not found. Trying to set up via pyenv..."
    install_python_with_pyenv "${pyver}"
  fi

  echo "==> Upgrading pip tooling..."
  python -m pip install --upgrade pip setuptools wheel

  echo "==> Installing deps from ${REQUIREMENTS_TXT} ..."
  python -m pip install -r "${REQUIREMENTS_TXT}"

  echo "==> Sanity checks:"
  python -c "import sys; print('python:', sys.version)"
  python -m bzt -h >/dev/null 2>&1 && echo "bzt: OK" || echo "bzt: NOT FOUND"
}

run_bzt_local() {
  local yml="${1:-${JIRA_YML}}"
  ensure_file "$yml"

  have_cmd python || die "python not found. Run: ./run.sh install-python"
  echo "==> Running locally: python -m bzt $(basename "$yml")"
  (cd "${REPO_ROOT}/app" && python -m bzt "$(basename "$yml")")
}

# =========================
# Arg parsing
# =========================
target="${1:-help}"
shift || true

platform="${DEFAULT_PLATFORM}"
shm="${DEFAULT_SHM}"
pull_flag="false"
webdriver_visible="false"
dry_run="false"

# parse global flags
while [[ "${1:-}" =~ ^-- ]]; do
  case "$1" in
    --platform) platform="${2:-}"; shift 2 ;;
    --shm) shm="${2:-}"; shift 2 ;;
    --pull) pull_flag="true"; shift ;;
    --visible) webdriver_visible="true"; shift ;;
    --dry-run) dry_run="true"; shift ;;
    --help|-h) show_help; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

# =========================
# Dispatch
# =========================
case "$target" in
  help|-h|--help)
    show_help
    ;;
  list)
    list_targets
    ;;
  jira)
    run_dcapt_yml "${JIRA_YML}" "${platform}" "${shm}" "${pull_flag}" "${webdriver_visible}" "${dry_run}"
    ;;
  confluence)
    run_dcapt_yml "${CONF_YML}" "${platform}" "${shm}" "${pull_flag}" "${webdriver_visible}" "${dry_run}"
    ;;
  run)
    [[ "${1:-}" != "" ]] || die "Usage: ./run.sh run <file.yml>"
    # allow relative paths from repo root
    yml_arg="$1"
    if [[ "$yml_arg" != /* ]]; then
      yml_arg="${REPO_ROOT}/${yml_arg}"
    fi
    run_dcapt_yml "${yml_arg}" "${platform}" "${shm}" "${pull_flag}" "${webdriver_visible}" "${dry_run}"
    ;;
  reports)
    mode="${1:-}"
    [[ "$mode" == "perf" || "$mode" == "scale" ]] || die "Usage: ./run.sh reports perf|scale"
    run_reports "$mode" "${platform}" "${pull_flag}" "${dry_run}"
    ;;
  install-pyenv)
    install_pyenv_macos
    ;;
  install-python)
    pyver="${1:-$PYTHON_VERSION_DEFAULT}"
    install_python_with_pyenv "${pyver}"
    ;;
  install-deps)
    pyver="${1:-$PYTHON_VERSION_DEFAULT}"
    install_python_deps "${pyver}"
    ;;
  run-local)
    sub="${1:-jira}"
    case "$sub" in
      jira) run_bzt_local "${JIRA_YML}" ;;
      confluence) run_bzt_local "${CONF_YML}" ;;
      *) die "Usage: ./run.sh run-local jira|confluence" ;;
    esac
    ;;

  *)
    die "Unknown target: $target (run './run.sh help')"
    ;;
esac