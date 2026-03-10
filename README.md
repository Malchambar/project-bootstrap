# Python Bootstrap

`bootstrap.sh` is a Bash tool for macOS/Homebrew that standardizes Python project setup with `venv` and Ruff.

It supports three modes:
- `new`: create a new Python project
- `existing`: configure an already-cloned repo
- `doctor`: check local environment health without changing files

## Requirements

- macOS
- Homebrew
- Python installed via Homebrew (for example `python@3.12`)
- Bash
- Git

## Installation

Using a standard local clone path (for example `~/dev/python-bootstrap`):

```bash
cd ~/dev/python-bootstrap
chmod +x bootstrap.sh
ln -s ~/dev/python-bootstrap/bootstrap.sh ~/bin/bootstrap
```

If your clone path is different, replace `~/dev/python-bootstrap` accordingly.

If needed, add `~/bin` to your `PATH`:

```bash
export PATH="$HOME/bin:$PATH"
```

## Usage

```bash
bootstrap <mode> [options]
```

Key options:
- `--python X.Y` choose Homebrew Python version
- `--install-hook` install local pre-push hook (`new`/`existing`)
- `--with-repo-guard` enable optional `repo-guard` integration (`new`/`existing`)
- `--upgrade-ruff-config` safely align Ruff config (`new`/`existing`)
- `--repo` require Git repo in `doctor` mode

## Example Commands

```bash
bootstrap new --name myproj --python 3.12
bootstrap existing --install-hook
bootstrap existing --install-hook --with-repo-guard
bootstrap doctor
bootstrap existing --python 3.12 --upgrade-ruff-config
```

## `.python-version` Pinning

`new` and `existing` write `.python-version` with the selected Python version (for example `3.12`).

In `existing` mode:
- if `--python` is not provided, `.python-version` is used as the default
- if the pinned version is not installed via Homebrew, the script warns and falls back to interactive selection

Commit `.python-version` to the repository so the preferred Python version follows the project across machines.

## Ruff Config Management

The script ensures this baseline Ruff setup exists in `pyproject.toml`:

```toml
[tool.ruff]
line-length = 100
target-version = "py312"

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "SIM"]

[tool.ruff.format]
quote-style = "double"
indent-style = "space"
```

Behavior is conservative by default:
- missing `pyproject.toml` is created
- missing Ruff sections/keys are added
- existing Ruff config is not blindly overwritten

With `--upgrade-ruff-config`, the script safely updates core Ruff defaults (including `target-version`) while preserving unrelated TOML content.

## Optional Pre-Push Hook

With `--install-hook`, the script installs `.git/hooks/pre-push` that runs:

```bash
venv/bin/ruff check .
```

If `venv/bin/ruff` is missing, push fails with a clear message.

### Optional `repo-guard` Integration

Use `--with-repo-guard` in `new` or `existing` mode to enable optional `repo-guard` support:
- the script checks whether `repo-guard` is available on `PATH`
- if found, it prints next-step guidance (for example `repo-guard init`)
- if not found, it warns but does not fail setup

If `--install-hook` and `--with-repo-guard` are used together, the pre-push hook runs:
- `venv/bin/ruff check .`
- `repo-guard check` when available on `PATH`, otherwise `venv/bin/python -m repo_guard check` when available in the virtualenv

## Sourced vs Executed Behavior

At the end of `new` and `existing`:
- if the script was **sourced**, it auto-activates `venv/bin/activate`
- if it was **executed normally**, it prints:

```bash
source venv/bin/activate
```

## `doctor` Mode

`doctor` performs read-only checks and reports `PASS` / `WARN` / `FAIL`, including:
- Homebrew and Git availability
- Git repo status (and repo root if applicable)
- Homebrew Python interpreters
- `venv/`, `venv/bin/python`, `venv/bin/ruff`
- `.git/hooks/pre-push` status
- `pyproject.toml` and Ruff config presence
- `.python-version` presence/value

`doctor` exits `0` when the environment looks healthy enough for development, and non-zero when important prerequisites are missing.

## Troubleshooting

- `brew: command not found` -> install Homebrew and restart shell.
- No Homebrew Python found -> `brew install python@3.12`.
- `bootstrap: command not found` -> verify `~/bin/bootstrap` symlink and `PATH`.
- Pre-push hook conflict -> existing non-bootstrap hook is not overwritten.
