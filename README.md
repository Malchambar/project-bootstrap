# Python Bootstrap

`bootstrap.sh` is a Bash tool for setting up Python development environments on macOS.

It supports two workflows:
1. Creating a brand-new Python project (`new`)
2. Configuring an already-cloned repository (`existing`)

## Requirements

- macOS
- Homebrew installed
- Python installed via Homebrew (for example `python@3.12`)
- Bash shell
- Git installed

## Installation

From the repository directory (`~/dev/python-bootstrap`):

```bash
chmod +x bootstrap.sh
```

## Make It Globally Accessible

Create a symlink so you can run `bootstrap` from anywhere:

```bash
ln -s ~/dev/python-bootstrap/bootstrap.sh ~/bin/bootstrap
```

If `~/bin` is not on your `PATH`, add it.

For `~/.zshrc`:

```bash
export PATH="$HOME/bin:$PATH"
```

For `~/.bashrc`:

```bash
export PATH="$HOME/bin:$PATH"
```

Then reload your shell config (for example `source ~/.zshrc`).

## Usage

```bash
bootstrap <mode> [options]
```

Modes:
- `new`: Create a new project directory and initialize it
- `existing`: Configure the current repository in place

Python version selection:
- Pass explicitly with `--python 3.12`
- If omitted, the script shows Homebrew-installed versions and prompts you to choose

## Example Commands

```bash
bootstrap new --name myproj --python 3.12
bootstrap new --name myproj --install-hook
bootstrap existing
bootstrap existing --python 3.12 --install-hook
```

## `new` Mode

Creates a new project directory under your current directory and initializes a starter Python project.

Typical outputs include:
- `venv/` virtual environment
- `pyproject.toml` with Ruff configuration
- `.gitignore`
- `README.md`
- `main.py`
- `src/<package_name>/__init__.py`
- `tests/`
- Git repository initialization

Example structure:

```text
myproj/
├── .git/
├── .gitignore
├── README.md
├── main.py
├── pyproject.toml
├── src/
│   └── myproj/
│       └── __init__.py
├── tests/
└── venv/
```

## `existing` Mode

Configures the current already-cloned repository without creating a new top-level directory.

What it does:
- Creates `venv/` if missing
- Upgrades `pip`
- Installs/upgrades Ruff
- Creates or updates `pyproject.toml` (adds Ruff config if missing)
- Creates or updates `.gitignore` with common Python dev ignores
- Optionally installs a local Git pre-push hook (`--install-hook`)

## Optional Pre-Push Hook (Ruff)

When `--install-hook` is used, the script installs `.git/hooks/pre-push`.

Behavior:
- Runs Ruff checks before push to `origin`
- Executes `venv/bin/ruff check .` when available
- If `venv/bin/ruff` is missing, prints a clear message and exits non-zero to block the push

## Troubleshooting

- `brew: command not found`
  - Install Homebrew and restart your shell.

- `No Homebrew Python versions found`
  - Install one, for example:
    ```bash
    brew install python@3.12
    ```

- `bootstrap: command not found`
  - Confirm symlink exists: `ls -l ~/bin/bootstrap`
  - Ensure `~/bin` is on `PATH`.

- Permission denied when running `bootstrap`
  - Run `chmod +x ~/dev/python-bootstrap/bootstrap.sh`.

- Existing pre-push hook not installed
  - If `.git/hooks/pre-push` already exists and was not created by this tool, the script avoids overwriting it.

- Python version option seems ignored in `existing`
  - If `venv/` already exists, the script keeps it and does not recreate it with a different interpreter.
