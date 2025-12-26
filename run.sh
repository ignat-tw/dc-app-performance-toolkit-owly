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

JIRA_YML="${REPO_ROOT}/app/jira.yml"
CONF_YML="${REPO_ROOT}/app/confluence.yml"

# Local python setup
VENV_DIR="${REPO_ROOT}/.venv"
DEPS_MARKER="${VENV_DIR}/.deps-installed"
PYTHON_VERSION_DEFAULT="3.13.1"
REQUIREMENTS_TXT="${REPO_ROOT}/requirements.txt"

# =========================
# Helpers
# =========================
die() { echo "ERROR: $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

print_cmd() {
  echo ""
  echo ">>> Executing:"
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

# -------------------------
# pyenv bootstrap (script-local)
# -------------------------
pyenv_bootstrap() {
  # Make pyenv visible even if shell init wasn't loaded
  export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
  export PATH="$PYENV_ROOT/bin:$PATH"

  if have_cmd pyenv; then
    # IMPORTANT: init sets PATH so "python" becomes pyenv shim
    eval "$(pyenv init -)"
    echo "INFO: pyenv OK: $(pyenv --version)"
    if [[ -f "${REPO_ROOT}/.python-version" ]]; then
      echo "INFO: repo python version: $(cat "${REPO_ROOT}/.python-version")"
    else
      echo "INFO: repo python version file missing: ${REPO_ROOT}/.python-version"
    fi
  else
    echo "INFO: pyenv NOT found in PATH"
  fi
}

# -------------------------
# venv bootstrap
# -------------------------
venv_activate() {
  if [[ ! -d "${VENV_DIR}" ]]; then
    echo "INFO: venv missing: ${VENV_DIR}"
    echo "INFO: Run: ./run.sh venv-create"
    return 1
  fi

  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"
  echo "INFO: venv activated: ${VENV_DIR}"
  echo "INFO: python: $(python -V 2>&1)"
  echo "INFO: pip: $(python -m pip -V 2>&1 || true)"
  return 0
}

local_preflight() {
  ensure_repo_layout
  pyenv_bootstrap

  if ! have_cmd python; then
    echo "INFO: python NOT found"
    echo "INFO: Run: ./run.sh install-python ${PYTHON_VERSION_DEFAULT}"
    return 1
  fi

  venv_activate || return 1

  if [[ ! -f "${DEPS_MARKER}" ]]; then
    echo "INFO: deps marker missing: ${DEPS_MARKER}"
    echo "INFO: Run: ./run.sh install-deps"
    return 1
  fi

  # quick sanity
  if ! python -m bzt -h >/dev/null 2>&1; then
    echo "INFO: bzt not runnable in venv"
    echo "INFO: Run: ./run.sh install-deps"
    return 1
  fi

  return 0
}

# =========================
# Help / targets
# =========================
show_help() {
  cat <<EOF
Usage:
  ./run.sh <target> [options]

Docker targets:
  jira                  Run DCAPT in docker using app/jira.yml
  confluence            Run DCAPT in docker using app/confluence.yml
  run <file.yml>        Run DCAPT in docker using a specific yml
  reports perf          Generate performance regression report
  reports scale         Generate scalability report
  list                  Show available targets and detected config files

Local (no docker) targets:
  install-pyenv         Install pyenv (macOS via brew) + add zsh init snippet
  install-python [ver]  Install Python via pyenv + set repo-local version (.python-version)
  venv-create           Create repo-local venv at ${VENV_DIR}
  install-deps          Install deps into venv from ${REQUIREMENTS_TXT} and write deps marker
  run-local jira        Run locally: python -m bzt app/jira.yml (auto pyenv+venv if ready)
  run-local confluence  Run locally: python -m bzt app/confluence.yml (auto pyenv+venv if ready)
  status                Print pyenv/python/venv/deps status

Options (docker only):
  --platform <p>        Docker platform (default: ${DEFAULT_PLATFORM})
  --shm <size>          Docker shm-size (default: ${DEFAULT_SHM})
  --pull                Add --pull=always to docker run
  --visible             Export WEBDRIVER_VISIBLE=True inside container
  --dry-run             Print docker command but do not execute

Examples:
  ./run.sh status
  ./run.sh install-python 3.13.1
  ./run.sh venv-create
  ./run.sh install-deps
  ./run.sh run-local jira

  ./run.sh jira
  ./run.sh confluence --visible
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
  echo "  - install-pyenv / install-python / venv-create / install-deps / run-local / status"
  echo ""
  echo "Detected config files:"
  [[ -f "$JIRA_YML" ]] && echo "  - app/jira.yml" || echo "  - app/jira.yml (missing)"
  [[ -f "$CONF_YML" ]] && echo "  - app/confluence.yml" || echo "  - app/confluence.yml (missing)"
  [[ -f "$REQUIREMENTS_TXT" ]] && echo "  - requirements.txt" || echo "  - requirements.txt (missing)"
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

  cmd+=(
    -v "${REPO_ROOT}:/dc-app-performance-toolkit"
    -w "${APP_DIR}"
  )

  if [[ "$webdriver_visible" == "true" ]]; then
    cmd+=( -e WEBDRIVER_VISIBLE=True )
  fi

  cmd+=( "${DOCKER_IMAGE_RUN}" "$(basename "$yml_path")" )

  local yml_dir
  yml_dir="$(cd "$(dirname "$yml_path")" && pwd)"
  local app_local_dir="${REPO_ROOT}/app"

  if [[ "$yml_dir" != "$app_local_dir" ]]; then
    echo "INFO: YML is not in app/. Copying into app/ for this run..."
    local tmp_name="_tmp_$(basename "$yml_path")"
    cp -f "$yml_path" "${REPO_ROOT}/app/${tmp_name}"
    cmd[-1]="${tmp_name}"
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
# Local install targets
# =========================
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

  echo "INFO: done. Restart terminal or run: source ~/.zshrc"
}

install_python_with_pyenv() {
  local pyver="${1:-$PYTHON_VERSION_DEFAULT}"

  pyenv_bootstrap
  have_cmd pyenv || die "pyenv not installed. Run: ./run.sh install-pyenv"

  echo "==> Installing Python ${pyver} (if missing)..."
  pyenv install -s "${pyver}"

  echo "==> Setting repo-local python to ${pyver} (.python-version)"
  (cd "${REPO_ROOT}" && pyenv local "${pyver}")

  pyenv rehash
  pyenv_bootstrap

  have_cmd python || die "python still not visible after pyenv init. Restart terminal or run: source ~/.zshrc"
  echo "INFO: python now: $(python -V 2>&1)"
}

venv_create() {
  ensure_repo_layout
  pyenv_bootstrap

  have_cmd python || die "python not found. Run: ./run.sh install-python ${PYTHON_VERSION_DEFAULT}"

  if [[ -d "${VENV_DIR}" ]]; then
    echo "INFO: venv already exists: ${VENV_DIR}"
    return 0
  fi

  echo "==> Creating venv: ${VENV_DIR}"
  python -m venv "${VENV_DIR}"
  echo "INFO: venv created."
  echo "INFO: Next: ./run.sh install-deps"
}

install_deps() {
  ensure_repo_layout
  ensure_file "${REQUIREMENTS_TXT}"
  pyenv_bootstrap

  if [[ ! -d "${VENV_DIR}" ]]; then
    echo "INFO: venv missing: ${VENV_DIR}"
    echo "INFO: Run: ./run.sh venv-create"
    exit 1
  fi

  venv_activate

  echo "==> Upgrading pip tooling..."
  python -m pip install --upgrade pip setuptools wheel

  echo "==> Installing deps from ${REQUIREMENTS_TXT} ..."
  python -m pip install -r "${REQUIREMENTS_TXT}"

  echo "==> Writing deps marker: ${DEPS_MARKER}"
  date > "${DEPS_MARKER}"

  echo "INFO: deps installed. bzt version:"
  python -m bzt --version || true
}

status() {
  ensure_repo_layout
  echo "== Status =="
  pyenv_bootstrap

  if have_cmd python; then
    echo "INFO: python: $(python -V 2>&1)"
    echo "INFO: python path: $(command -v python)"
  else
    echo "INFO: python: NOT FOUND"
  fi

  if [[ -d "${VENV_DIR}" ]]; then
    echo "INFO: venv: present (${VENV_DIR})"
  else
    echo "INFO: venv: missing (${VENV_DIR})"
  fi

  if [[ -f "${DEPS_MARKER}" ]]; then
    echo "INFO: deps marker: present ($(cat "${DEPS_MARKER}" 2>/dev/null || true))"
  else
    echo "INFO: deps marker: missing (${DEPS_MARKER})"
  fi
}

run_bzt_local() {
  local yml="$1"
  ensure_file "$yml"

  if ! local_preflight; then
    echo "ERROR: local environment not ready. Fix via targets above (status/install-python/venv-create/install-deps)."
    exit 1
  fi

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
  help|-h|--help) show_help ;;
  list) list_targets ;;

  jira) run_dcapt_yml "${JIRA_YML}" "${platform}" "${shm}" "${pull_flag}" "${webdriver_visible}" "${dry_run}" ;;
  confluence) run_dcapt_yml "${CONF_YML}" "${platform}" "${shm}" "${pull_flag}" "${webdriver_visible}" "${dry_run}" ;;
  run)
    [[ "${1:-}" != "" ]] || die "Usage: ./run.sh run <file.yml>"
    yml_arg="$1"
    if [[ "$yml_arg" != /* ]]; then yml_arg="${REPO_ROOT}/${yml_arg}"; fi
    run_dcapt_yml "${yml_arg}" "${platform}" "${shm}" "${pull_flag}" "${webdriver_visible}" "${dry_run}"
    ;;
  reports)
    mode="${1:-}"
    [[ "$mode" == "perf" || "$mode" == "scale" ]] || die "Usage: ./run.sh reports perf|scale"
    run_reports "$mode" "${platform}" "${pull_flag}" "${dry_run}"
    ;;

  install-pyenv) install_pyenv_macos ;;
  install-python) install_python_with_pyenv "${1:-$PYTHON_VERSION_DEFAULT}" ;;
  venv-create) venv_create ;;
  install-deps) install_deps ;;
  run-local)
    sub="${1:-jira}"
    case "$sub" in
      jira) run_bzt_local "${JIRA_YML}" ;;
      confluence) run_bzt_local "${CONF_YML}" ;;
      *) die "Usage: ./run.sh run-local jira|confluence" ;;
    esac
    ;;
  status) status ;;

  *) die "Unknown target: $target (run './run.sh help')" ;;
esac