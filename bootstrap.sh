#!/usr/bin/env bash
set -euo pipefail

# Python bootstrap script for macOS/Homebrew environments.
# Supports two workflows: creating a new project or preparing an existing repo.

SCRIPT_NAME="$(basename "$0")"
MODE=""
PROJECT_NAME=""
REQUESTED_PYTHON=""
INSTALL_HOOK="false"
SELECTED_PYTHON_BIN=""
SELECTED_PYTHON_VERSION=""

HOMEBREW_PY_FORMULAS=()
HOMEBREW_PY_VERSIONS=()
HOMEBREW_PY_BINS=()

usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_NAME} <mode> [options]

Modes:
  new                    Create a brand new Python project in a new directory
  existing               Configure the current cloned/existing repository

Options:
  -n, --name NAME        Project name (new mode only)
  -p, --python VERSION   Python version from Homebrew (example: 3.12)
      --install-hook     Install/update .git/hooks/pre-push to run Ruff checks
  -h, --help             Show this help

Examples:
  ./${SCRIPT_NAME} new
  ./${SCRIPT_NAME} new --name myproj --python 3.12
  ./${SCRIPT_NAME} existing
  ./${SCRIPT_NAME} existing --python 3.12 --install-hook
USAGE
}

log() {
  printf '%s\n' "$*"
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

gather_homebrew_pythons() {
  local formulas
  local formula
  local prefix
  local version
  local bin_path

  HOMEBREW_PY_FORMULAS=()
  HOMEBREW_PY_VERSIONS=()
  HOMEBREW_PY_BINS=()

  formulas="$(brew list --formula 2>/dev/null | grep -E '^python(@[0-9]+\.[0-9]+)?$' || true)"

  if [[ -z "$formulas" ]]; then
    error "No Homebrew Python versions found. Install one first (for example: brew install python@3.12)."
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
    error "Could not resolve any usable Homebrew Python binaries."
  fi
}

select_python_from_homebrew() {
  local i
  local choice

  gather_homebrew_pythons

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
}

venv_python_version() {
  if [[ -x "venv/bin/python" ]]; then
    venv/bin/python -c 'import sys; print("{}.{}".format(sys.version_info[0], sys.version_info[1]))'
  fi
}

write_pyproject_template() {
  local name="$1"
  local version="$2"
  local py_tag

  py_tag="$(python_tag_from_version "$version")"

  cat > pyproject.toml <<PYPROJECT
[project]
name = "${name}"
version = "0.1.0"
description = ""
readme = "README.md"
requires-python = ">=${version}"

[tool.ruff]
line-length = 100
target-version = "${py_tag}"

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "SIM"]
PYPROJECT
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

upsert_pyproject_existing() {
  local version="$1"
  local py_tag
  local inferred_name

  py_tag="$(python_tag_from_version "$version")"

  if [[ ! -f "pyproject.toml" ]]; then
    inferred_name="$(slugify_project_name "$(basename "$(pwd)")")"
    write_pyproject_template "$inferred_name" "$version"
    log "Created pyproject.toml with Ruff configuration."
    return
  fi

  if grep -q '^\[tool\.ruff' pyproject.toml; then
    log "pyproject.toml already contains Ruff configuration."
    return
  fi

  cat >> pyproject.toml <<RUFF_APPEND

[tool.ruff]
line-length = 100
target-version = "${py_tag}"

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "SIM"]
RUFF_APPEND

  log "Added Ruff configuration to existing pyproject.toml."
}

install_pre_push_hook() {
  local hook_path=".git/hooks/pre-push"

  if [[ ! -d ".git" ]]; then
    error "Cannot install hook: current directory is not a Git repository (missing .git)."
  fi

  if [[ -f "$hook_path" ]] && ! grep -q 'bootstrap_sh_ruff_pre_push_hook' "$hook_path"; then
    error "A pre-existing pre-push hook exists at $hook_path. Refusing to overwrite it."
  fi

  cat > "$hook_path" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail

# bootstrap_sh_ruff_pre_push_hook
# pre-push receives remote name as first argument; only enforce on origin pushes.
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

  chmod +x "$hook_path"
  log "Installed Git hook: $hook_path"
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  case "$1" in
    new|existing)
      MODE="$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "First argument must be a mode: 'new' or 'existing'."
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
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "Unknown option: $1"
        ;;
    esac
  done

  if [[ "$MODE" == "existing" && -n "$PROJECT_NAME" ]]; then
    error "--name is only valid with 'new' mode."
  fi
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
  write_pyproject_template "$normalized_name" "$SELECTED_PYTHON_VERSION"

  ensure_venv "$SELECTED_PYTHON_BIN"
  install_python_tools

  if [[ ! -d ".git" ]]; then
    git init >/dev/null
    log "Initialized Git repository."
  fi

  if [[ "$INSTALL_HOOK" == "true" ]]; then
    install_pre_push_hook
  fi

  log ""
  log "Bootstrap complete for new project: $project_dir"
  log "Next steps:"
  log "  cd \"$project_dir\""
  log "  source venv/bin/activate"
  log "  ruff check ."
}

run_existing_mode() {
  local detected_version

  require_cmd git

  if [[ -d "venv" ]]; then
    if [[ -n "$REQUESTED_PYTHON" ]]; then
      log "venv/ already exists; ignoring --python $REQUESTED_PYTHON without recreating the environment."
    fi
  else
    require_cmd brew
    select_python_from_homebrew
    log "Using Python ${SELECTED_PYTHON_VERSION}: ${SELECTED_PYTHON_BIN}"
    ensure_venv "$SELECTED_PYTHON_BIN"
  fi

  install_python_tools

  detected_version="$(venv_python_version || true)"
  if [[ -z "$detected_version" ]]; then
    if [[ -n "$SELECTED_PYTHON_VERSION" ]]; then
      detected_version="$SELECTED_PYTHON_VERSION"
    else
      error "Could not determine Python version for Ruff target-version."
    fi
  fi

  upsert_pyproject_existing "$detected_version"
  update_existing_gitignore

  if [[ "$INSTALL_HOOK" == "true" ]]; then
    install_pre_push_hook
  fi

  log ""
  log "Bootstrap complete for existing repository: $(pwd)"
  log "Next steps:"
  log "  source venv/bin/activate"
  log "  ruff check ."
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
    *)
      error "Unsupported mode: $MODE"
      ;;
  esac
}

main "$@"
