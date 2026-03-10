#!/usr/bin/env bash
set -euo pipefail

# Python bootstrap script for macOS/Homebrew environments.
# Supports creating new projects, configuring existing repos, and environment diagnostics.

SCRIPT_NAME="$(basename "$0")"
MODE=""
PROJECT_NAME=""
REQUESTED_PYTHON=""
INSTALL_HOOK="false"
UPGRADE_RUFF_CONFIG="false"
DOCTOR_REQUIRE_REPO="false"
WITH_REPO_GUARD="false"

SELECTED_PYTHON_BIN=""
SELECTED_PYTHON_VERSION=""
USED_PYTHON_VERSION=""
VENV_PATH=""
PRE_PUSH_HOOK_INSTALLED="no"
PYTHON_VERSION_FILE_WRITTEN="no"
RUFF_INSTALLED="no"
REPO_GUARD_STATUS="not requested"
REPO_GUARD_HOOK_INSTALLED="no"

HOMEBREW_PY_FORMULAS=()
HOMEBREW_PY_VERSIONS=()
HOMEBREW_PY_BINS=()

DOCTOR_PASS_COUNT=0
DOCTOR_WARN_COUNT=0
DOCTOR_FAIL_COUNT=0

usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_NAME} <mode> [options]

Modes:
  new                    Create a brand new Python project in a new directory
  existing               Configure the current cloned/existing repository
  doctor                 Diagnose local development environment state

Options:
  -n, --name NAME        Project name (new mode only)
  -p, --python VERSION   Python version from Homebrew (example: 3.12)
      --install-hook     Install/update .git/hooks/pre-push to run Ruff checks
      --with-repo-guard  Enable optional repo-guard integration in new/existing
      --upgrade-ruff-config
                         Safely upgrade existing Ruff settings in pyproject.toml
      --repo             doctor mode only; fail if current directory is not a git repo
  -h, --help             Show this help

Notes:
  - new/existing write a .python-version pin in the project root.
  - existing prefers .python-version when --python is not provided.

Examples:
  ./${SCRIPT_NAME} new --name myproj --python 3.12
  ./${SCRIPT_NAME} existing --install-hook
  ./${SCRIPT_NAME} existing --install-hook --with-repo-guard
  ./${SCRIPT_NAME} existing --upgrade-ruff-config
  ./${SCRIPT_NAME} doctor
  ./${SCRIPT_NAME} doctor --repo
USAGE
}

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

error() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    error "'$cmd' is not installed or not in PATH."
  fi
}

validate_project_name() {
  local name="$1"

  if [[ -z "$name" ]]; then
    error "Project name cannot be empty."
  fi

  if [[ "$name" == *"/"* ]]; then
    error "Project name must not contain '/'."
  fi
}

slugify_project_name() {
  local name="$1"
  printf '%s' "$name" | tr '[:upper:] ' '[:lower:]-'
}

package_name_from_project() {
  local name="$1"
  local package

  package="$(printf '%s' "$name" | tr '[:upper:]- ' '[:lower:]__' | tr -cd '[:alnum:]_')"
  if [[ -z "$package" ]]; then
    package="app"
  fi

  printf '%s' "$package"
}

python_tag_from_version() {
  local version="$1"
  printf 'py%s' "${version/./}"
}

read_python_version_file() {
  if [[ -f ".python-version" ]]; then
    head -n 1 .python-version | tr -d '[:space:]'
  fi
}

write_python_version_file() {
  local version="$1"
  printf '%s\n' "$version" > .python-version
  PYTHON_VERSION_FILE_WRITTEN="yes"
  log "Wrote .python-version: ${version}"
}

add_python_candidate() {
  local version="$1"
  local bin_path="$2"
  local formula="$3"
  local i

  for ((i = 0; i < ${#HOMEBREW_PY_VERSIONS[@]}; i++)); do
    if [[ "${HOMEBREW_PY_VERSIONS[$i]}" == "$version" ]]; then
      return
    fi
  done

  HOMEBREW_PY_VERSIONS+=("$version")
  HOMEBREW_PY_BINS+=("$bin_path")
  HOMEBREW_PY_FORMULAS+=("$formula")
}

# Populate Homebrew Python candidates.
# strict mode: exits on failure; nofail mode: returns non-zero without exiting.
gather_homebrew_pythons() {
  local mode="${1:-strict}"
  local formulas
  local formula
  local prefix
  local version
  local bin_path

  HOMEBREW_PY_FORMULAS=()
  HOMEBREW_PY_VERSIONS=()
  HOMEBREW_PY_BINS=()

  if ! command -v brew >/dev/null 2>&1; then
    if [[ "$mode" == "strict" ]]; then
      error "'brew' is not installed or not in PATH."
    fi
    return 1
  fi

  formulas="$(brew list --formula 2>/dev/null | grep -E '^python(@[0-9]+\.[0-9]+)?$' || true)"
  if [[ -z "$formulas" ]]; then
    if [[ "$mode" == "strict" ]]; then
      error "No Homebrew Python versions found. Install one first (for example: brew install python@3.12)."
    fi
    return 1
  fi

  while IFS= read -r formula; do
    [[ -z "$formula" ]] && continue

    prefix="$(brew --prefix "$formula" 2>/dev/null || true)"
    [[ -z "$prefix" ]] && continue

    if [[ "$formula" == "python" ]]; then
      bin_path="$prefix/bin/python3"
      if [[ -x "$bin_path" ]]; then
        version="$($bin_path -c 'import sys; print("{}.{}".format(sys.version_info[0], sys.version_info[1]))' 2>/dev/null || true)"
        if [[ -n "$version" ]]; then
          add_python_candidate "$version" "$bin_path" "$formula"
        fi
      fi
    else
      version="${formula#python@}"
      bin_path="$prefix/bin/python${version}"
      if [[ ! -x "$bin_path" ]]; then
        bin_path="$prefix/bin/python3"
      fi

      if [[ -x "$bin_path" ]]; then
        add_python_candidate "$version" "$bin_path" "$formula"
      fi
    fi
  done <<< "$formulas"

  if [[ ${#HOMEBREW_PY_VERSIONS[@]} -eq 0 ]]; then
    if [[ "$mode" == "strict" ]]; then
      error "Could not resolve any usable Homebrew Python binaries."
    fi
    return 1
  fi

  return 0
}

homebrew_has_python_version() {
  local version="$1"
  local i

  if ! gather_homebrew_pythons "nofail"; then
    return 1
  fi

  for ((i = 0; i < ${#HOMEBREW_PY_VERSIONS[@]}; i++)); do
    if [[ "${HOMEBREW_PY_VERSIONS[$i]}" == "$version" ]]; then
      return 0
    fi
  done

  return 1
}

select_python_from_homebrew() {
  local i
  local choice

  gather_homebrew_pythons "strict"

  if [[ -n "$REQUESTED_PYTHON" ]]; then
    for ((i = 0; i < ${#HOMEBREW_PY_VERSIONS[@]}; i++)); do
      if [[ "${HOMEBREW_PY_VERSIONS[$i]}" == "$REQUESTED_PYTHON" ]]; then
        SELECTED_PYTHON_VERSION="${HOMEBREW_PY_VERSIONS[$i]}"
        SELECTED_PYTHON_BIN="${HOMEBREW_PY_BINS[$i]}"
        return
      fi
    done

    log "Available Homebrew Python versions:"
    for ((i = 0; i < ${#HOMEBREW_PY_VERSIONS[@]}; i++)); do
      log "  - ${HOMEBREW_PY_VERSIONS[$i]} (${HOMEBREW_PY_FORMULAS[$i]})"
    done
    error "Requested Python version '$REQUESTED_PYTHON' is not installed via Homebrew."
  fi

  log "Available Homebrew Python versions:"
  for ((i = 0; i < ${#HOMEBREW_PY_VERSIONS[@]}; i++)); do
    log "  [$((i + 1))] ${HOMEBREW_PY_VERSIONS[$i]} (${HOMEBREW_PY_FORMULAS[$i]})"
  done

  read -r -p "Choose Python by number: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    error "Invalid selection '$choice'."
  fi

  if ((choice < 1 || choice > ${#HOMEBREW_PY_VERSIONS[@]})); then
    error "Selection out of range."
  fi

  SELECTED_PYTHON_VERSION="${HOMEBREW_PY_VERSIONS[$((choice - 1))]}"
  SELECTED_PYTHON_BIN="${HOMEBREW_PY_BINS[$((choice - 1))]}"
}

ensure_venv() {
  local python_bin="$1"

  if [[ -d "venv" ]]; then
    log "Virtual environment already exists at venv/."
    return
  fi

  log "Creating virtual environment in venv/ using ${python_bin}..."
  "$python_bin" -m venv venv
}

install_python_tools() {
  if [[ ! -x "venv/bin/python" ]]; then
    error "venv/bin/python is missing. Virtual environment setup failed."
  fi

  log "Upgrading pip..."
  venv/bin/python -m pip install --upgrade pip

  log "Installing Ruff..."
  venv/bin/python -m pip install --upgrade ruff
  RUFF_INSTALLED="yes"
}

venv_python_version() {
  if [[ -x "venv/bin/python" ]]; then
    venv/bin/python -c 'import sys; print("{}.{}".format(sys.version_info[0], sys.version_info[1]))'
  fi
}

create_new_pyproject_template() {
  local project_name="$1"
  local version="$2"
  local py_tag

  py_tag="$(python_tag_from_version "$version")"

  cat > pyproject.toml <<PYPROJECT
[project]
name = "${project_name}"
version = "0.1.0"
description = ""
readme = "README.md"
requires-python = ">=${version}"

[tool.ruff]
line-length = 100
target-version = "${py_tag}"

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "SIM"]

[tool.ruff.format]
quote-style = "double"
indent-style = "space"
PYPROJECT
}

create_ruff_only_pyproject_template() {
  local version="$1"
  local py_tag

  py_tag="$(python_tag_from_version "$version")"

  cat > pyproject.toml <<PYPROJECT
[tool.ruff]
line-length = 100
target-version = "${py_tag}"

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "SIM"]

[tool.ruff.format]
quote-style = "double"
indent-style = "space"
PYPROJECT
}

toml_section_exists() {
  local section="$1"

  awk -v section="$section" '
    function header_name(line, t) {
      t = line
      sub(/^[[:space:]]*\[/, "", t)
      sub(/\][[:space:]]*$/, "", t)
      return t
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      if (header_name($0) == section) {
        found = 1
        exit 0
      }
    }
    END { exit(found ? 0 : 1) }
  ' pyproject.toml
}

toml_key_exists() {
  local section="$1"
  local key="$2"

  awk -v section="$section" -v key="$key" '
    function header_name(line, t) {
      t = line
      sub(/^[[:space:]]*\[/, "", t)
      sub(/\][[:space:]]*$/, "", t)
      return t
    }
    {
      if ($0 ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
        in_section = (header_name($0) == section)
        next
      }
      pattern = "^[[:space:]]*" key "[[:space:]]*="
      if (in_section && $0 ~ pattern) {
        found = 1
        exit 0
      }
    }
    END { exit(found ? 0 : 1) }
  ' pyproject.toml
}

# Upsert a key inside an existing TOML section without touching unrelated content.
toml_upsert_key() {
  local section="$1"
  local key="$2"
  local value="$3"
  local replace_existing="${4:-false}"
  local tmp_file

  tmp_file="$(mktemp)"

  awk -v section="$section" -v key="$key" -v value="$value" -v replace_existing="$replace_existing" '
    function header_name(line, t) {
      t = line
      sub(/^[[:space:]]*\[/, "", t)
      sub(/\][[:space:]]*$/, "", t)
      return t
    }
    BEGIN {
      in_section = 0
      key_seen = 0
    }
    {
      if ($0 ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
        if (in_section && !key_seen) {
          print key " = " value
          key_seen = 1
        }

        in_section = (header_name($0) == section)
        if (in_section) {
          key_seen = 0
        }

        print $0
        next
      }

      if (in_section) {
        pattern = "^[[:space:]]*" key "[[:space:]]*="
        if ($0 ~ pattern) {
          if (replace_existing == "true") {
            print key " = " value
          } else {
            print $0
          }
          key_seen = 1
          next
        }
      }

      print $0
    }
    END {
      if (in_section && !key_seen) {
        print key " = " value
      }
    }
  ' pyproject.toml > "$tmp_file"

  mv "$tmp_file" pyproject.toml
}

append_ruff_block() {
  local py_tag="$1"
  cat >> pyproject.toml <<RUFF

[tool.ruff]
line-length = 100
target-version = "${py_tag}"
RUFF
}

append_ruff_lint_block() {
  cat >> pyproject.toml <<'LINT'

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "SIM"]
LINT
}

append_ruff_format_block() {
  cat >> pyproject.toml <<'FORMAT'

[tool.ruff.format]
quote-style = "double"
indent-style = "space"
FORMAT
}

ensure_ruff_config() {
  local version="$1"
  local mode_context="$2"
  local project_name="${3:-}"
  local py_tag
  local changed="false"

  py_tag="$(python_tag_from_version "$version")"

  if [[ ! -f "pyproject.toml" ]]; then
    if [[ "$mode_context" == "new" ]]; then
      create_new_pyproject_template "$project_name" "$version"
    else
      create_ruff_only_pyproject_template "$version"
    fi
    log "Created pyproject.toml with Ruff configuration."
    return
  fi

  if ! toml_section_exists "tool.ruff"; then
    append_ruff_block "$py_tag"
    append_ruff_lint_block
    append_ruff_format_block
    log "Added Ruff sections to existing pyproject.toml."
    return
  fi

  if [[ "$UPGRADE_RUFF_CONFIG" == "true" ]]; then
    toml_upsert_key "tool.ruff" "line-length" "100" "true"
    toml_upsert_key "tool.ruff" "target-version" "\"${py_tag}\"" "true"

    if ! toml_section_exists "tool.ruff.lint"; then
      append_ruff_lint_block
    fi
    toml_upsert_key "tool.ruff.lint" "select" "[\"E\", \"F\", \"I\", \"UP\", \"B\", \"SIM\"]" "true"

    if ! toml_section_exists "tool.ruff.format"; then
      append_ruff_format_block
    fi
    toml_upsert_key "tool.ruff.format" "quote-style" "\"double\"" "true"
    toml_upsert_key "tool.ruff.format" "indent-style" "\"space\"" "true"

    log "Applied Ruff config upgrade in pyproject.toml."
    return
  fi

  if ! toml_key_exists "tool.ruff" "line-length"; then
    toml_upsert_key "tool.ruff" "line-length" "100" "false"
    changed="true"
  fi

  if ! toml_key_exists "tool.ruff" "target-version"; then
    toml_upsert_key "tool.ruff" "target-version" "\"${py_tag}\"" "false"
    changed="true"
  fi

  if ! toml_section_exists "tool.ruff.lint"; then
    append_ruff_lint_block
    changed="true"
  elif ! toml_key_exists "tool.ruff.lint" "select"; then
    toml_upsert_key "tool.ruff.lint" "select" "[\"E\", \"F\", \"I\", \"UP\", \"B\", \"SIM\"]" "false"
    changed="true"
  fi

  if ! toml_section_exists "tool.ruff.format"; then
    append_ruff_format_block
    changed="true"
  else
    if ! toml_key_exists "tool.ruff.format" "quote-style"; then
      toml_upsert_key "tool.ruff.format" "quote-style" "\"double\"" "false"
      changed="true"
    fi

    if ! toml_key_exists "tool.ruff.format" "indent-style"; then
      toml_upsert_key "tool.ruff.format" "indent-style" "\"space\"" "false"
      changed="true"
    fi
  fi

  if [[ "$changed" == "true" ]]; then
    log "Patched missing Ruff settings in pyproject.toml."
  else
    warn "Ruff configuration already exists; leaving existing values unchanged. Use --upgrade-ruff-config to align defaults."
  fi
}

ensure_line_in_file() {
  local file_path="$1"
  local line="$2"

  touch "$file_path"
  if ! grep -qxF "$line" "$file_path" 2>/dev/null; then
    printf '%s\n' "$line" >> "$file_path"
  fi
}

create_new_gitignore() {
  cat > .gitignore <<'GITIGNORE'
# Python bytecode and caches
__pycache__/
*.py[cod]
.pytest_cache/
.ruff_cache/

# Virtual environment
venv/

# Packaging artifacts
build/
dist/
*.egg-info/

# Environment files
.env
.env.*

# macOS
.DS_Store
GITIGNORE
}

update_existing_gitignore() {
  local file_path=".gitignore"

  ensure_line_in_file "$file_path" "__pycache__/"
  ensure_line_in_file "$file_path" "*.py[cod]"
  ensure_line_in_file "$file_path" ".pytest_cache/"
  ensure_line_in_file "$file_path" ".ruff_cache/"
  ensure_line_in_file "$file_path" "venv/"
  ensure_line_in_file "$file_path" "build/"
  ensure_line_in_file "$file_path" "dist/"
  ensure_line_in_file "$file_path" "*.egg-info/"
  ensure_line_in_file "$file_path" ".env"
  ensure_line_in_file "$file_path" ".env.*"
  ensure_line_in_file "$file_path" ".DS_Store"
}

create_new_readme() {
  local name="$1"

  cat > README.md <<README
# ${name}

Python project bootstrapped with \`bootstrap.sh\`.

## Quick start

\`\`\`bash
source venv/bin/activate
ruff check .
\`\`\`
README
}

create_new_main() {
  local name="$1"

  cat > main.py <<MAIN
def main() -> None:
    print("Hello from ${name}")


if __name__ == "__main__":
    main()
MAIN
}

resolve_repo_guard_command_path() {
  if [[ -x "$HOME/bin/repo-guard" ]]; then
    printf '%s\n' "$HOME/bin/repo-guard"
    return 0
  fi

  command -v repo-guard 2>/dev/null || return 1
}

configure_repo_guard_integration() {
  local repo_guard_cmd

  if [[ "$WITH_REPO_GUARD" != "true" ]]; then
    return
  fi

  if repo_guard_cmd="$(resolve_repo_guard_command_path)" && "$repo_guard_cmd" --help >/dev/null 2>&1; then
    REPO_GUARD_STATUS="available on PATH"
    log "repo-guard detected: ${repo_guard_cmd}"
    log "Optional next step: run 'repo-guard init' in this repository."
  else
    REPO_GUARD_STATUS="requested but unavailable"
    warn "--with-repo-guard was requested, but a working 'repo-guard' command was not found on PATH."
    warn "Install/fix repo-guard, then run: repo-guard init"
  fi
}

install_pre_push_hook() {
  local hook_path=".git/hooks/pre-push"

  if [[ ! -d ".git" ]]; then
    error "Cannot install hook: current directory is not a Git repository (missing .git)."
  fi

  if [[ -f "$hook_path" ]] && ! grep -q 'bootstrap_sh_ruff_pre_push_hook' "$hook_path"; then
    error "A pre-existing pre-push hook exists at $hook_path. Refusing to overwrite it."
  fi

  if [[ "$WITH_REPO_GUARD" == "true" ]]; then
    local repo_guard_cmd
    if ! repo_guard_cmd="$(resolve_repo_guard_command_path)" || ! "$repo_guard_cmd" --help >/dev/null 2>&1; then
      warn "Installing pre-push hook with repo-guard checks, but repo-guard is not currently runnable."
      warn "Pushes will fail until repo-guard is installed/fixed on PATH."
    fi

    cat > "$hook_path" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail

# bootstrap_sh_ruff_pre_push_hook
if [[ "${1:-}" != "origin" ]]; then
  exit 0
fi

if [[ -x "venv/bin/ruff" ]]; then
  echo "pre-push: running Ruff checks..."
  venv/bin/ruff check .
else
  echo "pre-push: venv/bin/ruff was not found."
  echo "pre-push: run ./bootstrap.sh existing to create venv and install Ruff."
  exit 1
fi

repo_guard_cmd=""
if [[ -x "$HOME/bin/repo-guard" ]]; then
  repo_guard_cmd="$HOME/bin/repo-guard"
elif command -v repo-guard >/dev/null 2>&1; then
  repo_guard_cmd="$(command -v repo-guard)"
fi

if [[ -n "$repo_guard_cmd" ]] && "$repo_guard_cmd" --help >/dev/null 2>&1; then
  echo "pre-push: running repo-guard checks..."
  "$repo_guard_cmd" check
elif [[ -n "$repo_guard_cmd" ]]; then
  echo "pre-push: repo-guard command exists but is not runnable: ${repo_guard_cmd}"
else
  echo "pre-push: repo-guard integration is enabled, but repo-guard is unavailable."
  echo "pre-push: install repo-guard on PATH (for example ~/bin/repo-guard) to continue."
  exit 1
fi
HOOK
    REPO_GUARD_HOOK_INSTALLED="yes"
    if [[ "$REPO_GUARD_STATUS" == "available on PATH" ]]; then
      REPO_GUARD_STATUS="available on PATH (hook enabled)"
    fi
  else
    cat > "$hook_path" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail

# bootstrap_sh_ruff_pre_push_hook
if [[ "${1:-}" != "origin" ]]; then
  exit 0
fi

if [[ -x "venv/bin/ruff" ]]; then
  echo "pre-push: running Ruff checks..."
  venv/bin/ruff check .
else
  echo "pre-push: venv/bin/ruff was not found."
  echo "pre-push: run ./bootstrap.sh existing to create venv and install Ruff."
  exit 1
fi
HOOK
  fi

  chmod +x "$hook_path"
  PRE_PUSH_HOOK_INSTALLED="yes"
  log "Installed Git hook: $hook_path"
}

print_mode_summary() {
  log ""
  log "Bootstrap completed successfully."
  log "Mode run: ${MODE}"
  log "Python version selected: ${USED_PYTHON_VERSION}"
  log ".python-version written: ${PYTHON_VERSION_FILE_WRITTEN}"
  log "Ruff installed: ${RUFF_INSTALLED}"
  log "Pre-push hook installed: ${PRE_PUSH_HOOK_INSTALLED}"
  log "repo-guard: ${REPO_GUARD_STATUS}"
  log "repo-guard hook checks enabled: ${REPO_GUARD_HOOK_INSTALLED}"
  log "Virtual environment: ${VENV_PATH}"
}

handle_activation_message() {
  if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # script was sourced
    if [[ -f "venv/bin/activate" ]]; then
      # shellcheck disable=SC1091
      source venv/bin/activate
      log "Virtual environment activated in current shell: venv"
    else
      warn "Virtual environment activation script not found at venv/bin/activate."
    fi
  else
    # script was executed
    log "To activate the virtual environment, run:"
    log "  source venv/bin/activate"
  fi
}

doctor_pass() {
  DOCTOR_PASS_COUNT=$((DOCTOR_PASS_COUNT + 1))
  log "PASS: $1"
}

doctor_warn() {
  DOCTOR_WARN_COUNT=$((DOCTOR_WARN_COUNT + 1))
  log "WARN: $1"
}

doctor_fail() {
  DOCTOR_FAIL_COUNT=$((DOCTOR_FAIL_COUNT + 1))
  log "FAIL: $1"
}

run_doctor_mode() {
  local cwd
  local doctor_dir
  local repo_root=""
  local pinned_version=""
  local brew_ok="false"
  local git_ok="false"
  local in_repo="false"

  cwd="$(pwd)"
  doctor_dir="$cwd"

  DOCTOR_PASS_COUNT=0
  DOCTOR_WARN_COUNT=0
  DOCTOR_FAIL_COUNT=0

  log "Running doctor in: $cwd"

  if command -v brew >/dev/null 2>&1; then
    brew_ok="true"
    doctor_pass "Homebrew is installed."
  else
    doctor_fail "Homebrew is not installed or not in PATH."
  fi

  if command -v git >/dev/null 2>&1; then
    git_ok="true"
    doctor_pass "Git is installed."
  else
    doctor_fail "Git is not installed or not in PATH."
  fi

  if [[ "$git_ok" == "true" ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    in_repo="true"
    repo_root="$(git rev-parse --show-toplevel)"
    doctor_pass "Current directory is inside a Git repository."
    log "INFO: Repo root: ${repo_root}"
    doctor_dir="$repo_root"
  else
    if [[ "$DOCTOR_REQUIRE_REPO" == "true" ]]; then
      doctor_fail "Not inside a Git repository (required by --repo)."
    else
      doctor_warn "Not inside a Git repository."
    fi
  fi

  if [[ "$brew_ok" == "true" ]]; then
    if gather_homebrew_pythons "nofail"; then
      doctor_pass "Homebrew Python interpreters found: ${HOMEBREW_PY_VERSIONS[*]}"
    else
      doctor_fail "No usable Python interpreters found from Homebrew."
    fi
  fi

  if [[ -d "$doctor_dir/venv" ]]; then
    doctor_pass "venv/ exists (${doctor_dir}/venv)."
  else
    doctor_fail "venv/ is missing at ${doctor_dir}/venv."
  fi

  if [[ -x "$doctor_dir/venv/bin/python" ]]; then
    doctor_pass "venv/bin/python exists."
  else
    doctor_fail "venv/bin/python is missing."
  fi

  if [[ -x "$doctor_dir/venv/bin/ruff" ]]; then
    doctor_pass "venv/bin/ruff exists."
  else
    doctor_fail "venv/bin/ruff is missing."
  fi

  if [[ "$in_repo" == "true" ]]; then
    if [[ -f "$repo_root/.git/hooks/pre-push" ]]; then
      if [[ -x "$repo_root/.git/hooks/pre-push" ]]; then
        doctor_pass ".git/hooks/pre-push exists and is executable."
      else
        doctor_warn ".git/hooks/pre-push exists but is not executable."
      fi
    else
      doctor_warn ".git/hooks/pre-push is not installed."
    fi
  else
    doctor_warn "Skipping hook check because no Git repo is active."
  fi

  if [[ -f "$doctor_dir/pyproject.toml" ]]; then
    doctor_pass "pyproject.toml exists."
    if grep -q '^\[tool\.ruff\]' "$doctor_dir/pyproject.toml"; then
      doctor_pass "pyproject.toml contains Ruff configuration."
    else
      doctor_warn "pyproject.toml does not contain [tool.ruff]."
    fi
  else
    doctor_fail "pyproject.toml is missing."
  fi

  if [[ -f "$doctor_dir/.python-version" ]]; then
    pinned_version="$(head -n 1 "$doctor_dir/.python-version" | tr -d '[:space:]')"
    doctor_pass ".python-version exists."
    log "INFO: .python-version => ${pinned_version:-<empty>}"
  else
    doctor_warn ".python-version is missing."
  fi

  log ""
  log "Doctor summary: PASS=${DOCTOR_PASS_COUNT} WARN=${DOCTOR_WARN_COUNT} FAIL=${DOCTOR_FAIL_COUNT}"

  if ((DOCTOR_FAIL_COUNT > 0)); then
    log "Doctor result: environment is not healthy enough for development."
    return 1
  fi

  log "Doctor result: environment looks healthy for development."
  return 0
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  case "$1" in
    new|existing|doctor)
      MODE="$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "First argument must be a mode: 'new', 'existing', or 'doctor'."
      ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--name)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then
          error "--name requires a value."
        fi
        PROJECT_NAME="$2"
        shift 2
        ;;
      -p|--python)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then
          error "--python requires a value like 3.12."
        fi
        REQUESTED_PYTHON="$2"
        shift 2
        ;;
      --install-hook)
        INSTALL_HOOK="true"
        shift
        ;;
      --with-repo-guard)
        WITH_REPO_GUARD="true"
        shift
        ;;
      --upgrade-ruff-config)
        UPGRADE_RUFF_CONFIG="true"
        shift
        ;;
      --repo)
        DOCTOR_REQUIRE_REPO="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "Unknown option: $1"
        ;;
    esac
  done

  case "$MODE" in
    new)
      if [[ "$DOCTOR_REQUIRE_REPO" == "true" ]]; then
        error "--repo is only valid with doctor mode."
      fi
      ;;
    existing)
      if [[ -n "$PROJECT_NAME" ]]; then
        error "--name is only valid with 'new' mode."
      fi
      if [[ "$DOCTOR_REQUIRE_REPO" == "true" ]]; then
        error "--repo is only valid with doctor mode."
      fi
      ;;
    doctor)
      if [[ -n "$PROJECT_NAME" ]]; then
        error "--name is not valid with doctor mode."
      fi
      if [[ -n "$REQUESTED_PYTHON" ]]; then
        error "--python is not valid with doctor mode."
      fi
      if [[ "$INSTALL_HOOK" == "true" ]]; then
        error "--install-hook is not supported in doctor mode."
      fi
      if [[ "$UPGRADE_RUFF_CONFIG" == "true" ]]; then
        error "--upgrade-ruff-config is not supported in doctor mode."
      fi
      if [[ "$WITH_REPO_GUARD" == "true" ]]; then
        error "--with-repo-guard is not supported in doctor mode."
      fi
      ;;
    *)
      error "Unsupported mode: $MODE"
      ;;
  esac
}

run_new_mode() {
  local project_dir
  local package_name
  local normalized_name

  require_cmd brew
  require_cmd git

  if [[ -z "$PROJECT_NAME" ]]; then
    read -r -p "Project name: " PROJECT_NAME
  fi

  validate_project_name "$PROJECT_NAME"

  project_dir="$(pwd)/$PROJECT_NAME"
  if [[ -e "$project_dir" ]]; then
    error "Path already exists: $project_dir"
  fi

  select_python_from_homebrew
  USED_PYTHON_VERSION="$SELECTED_PYTHON_VERSION"

  log "Using Python ${SELECTED_PYTHON_VERSION}: ${SELECTED_PYTHON_BIN}"

  mkdir -p "$project_dir"
  cd "$project_dir"

  normalized_name="$(slugify_project_name "$PROJECT_NAME")"
  package_name="$(package_name_from_project "$PROJECT_NAME")"

  mkdir -p "src/${package_name}" "tests"
  touch "src/${package_name}/__init__.py"

  create_new_main "$PROJECT_NAME"
  create_new_readme "$PROJECT_NAME"
  create_new_gitignore
  ensure_ruff_config "$USED_PYTHON_VERSION" "new" "$normalized_name"

  ensure_venv "$SELECTED_PYTHON_BIN"
  install_python_tools

  write_python_version_file "$USED_PYTHON_VERSION"
  VENV_PATH="$(pwd)/venv"

  if [[ ! -d ".git" ]]; then
    git init >/dev/null
    log "Initialized Git repository."
  fi

  configure_repo_guard_integration

  if [[ "$INSTALL_HOOK" == "true" ]]; then
    install_pre_push_hook
  fi
}

run_existing_mode() {
  local pinned_version
  local detected_version

  require_cmd git

  if [[ -d "venv" ]]; then
    if [[ -n "$REQUESTED_PYTHON" ]]; then
      warn "venv/ already exists; ignoring --python ${REQUESTED_PYTHON} without recreating the environment."
    fi

    detected_version="$(venv_python_version || true)"
    if [[ -z "$detected_version" ]]; then
      error "venv/ exists but Python version could not be detected from venv/bin/python."
    fi
    USED_PYTHON_VERSION="$detected_version"
  else
    require_cmd brew

    if [[ -z "$REQUESTED_PYTHON" && -f ".python-version" ]]; then
      pinned_version="$(read_python_version_file)"
      if [[ -n "$pinned_version" ]]; then
        if homebrew_has_python_version "$pinned_version"; then
          REQUESTED_PYTHON="$pinned_version"
          log "Using pinned Python version from .python-version: ${pinned_version}"
        else
          warn "Pinned Python version '${pinned_version}' from .python-version is not installed via Homebrew."
          warn "Falling back to interactive Python selection."
        fi
      fi
    fi

    select_python_from_homebrew
    USED_PYTHON_VERSION="$SELECTED_PYTHON_VERSION"
    log "Using Python ${SELECTED_PYTHON_VERSION}: ${SELECTED_PYTHON_BIN}"
    ensure_venv "$SELECTED_PYTHON_BIN"
  fi

  install_python_tools

  # Keep the pin aligned with the environment version used.
  write_python_version_file "$USED_PYTHON_VERSION"

  ensure_ruff_config "$USED_PYTHON_VERSION" "existing"
  update_existing_gitignore

  VENV_PATH="$(pwd)/venv"
  configure_repo_guard_integration

  if [[ "$INSTALL_HOOK" == "true" ]]; then
    install_pre_push_hook
  fi
}

main() {
  parse_args "$@"

  case "$MODE" in
    new)
      run_new_mode
      ;;
    existing)
      run_existing_mode
      ;;
    doctor)
      run_doctor_mode
      ;;
    *)
      error "Unsupported mode: $MODE"
      ;;
  esac
}

main "$@"

if [[ "$MODE" == "new" || "$MODE" == "existing" ]]; then
  print_mode_summary
  handle_activation_message
fi
