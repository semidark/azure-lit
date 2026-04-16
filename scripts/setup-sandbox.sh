#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/setup-sandbox-symlinks.sh [--source-root <path>] [--force]

Creates symlinks in ./infra to shared files from the main worktree:
  - .env
  - terraform.tfstate
  - terraform.tfstate.backup (if present in source)
  - .terraform (if present in source; avoids re-downloading providers)

Behavior:
  - Runs only inside an OpenCode sandbox worktree path
    (/.local/share/opencode/worktree/)
  - Auto-detects the source root via `git worktree list`
  - Fails if destination exists as a regular file/directory unless --force is set

Options:
  --source-root <path>  Explicit source repo root (defaults to auto-detect)
  --force               Replace existing destination entries
  -h, --help            Show this help text
EOF
}

SOURCE_ROOT=""
FORCE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-root)
      SOURCE_ROOT="${2:-}"
      if [[ -z "$SOURCE_ROOT" ]]; then
        echo "Error: --source-root requires a value." >&2
        exit 1
      fi
      shift 2
      ;;
    --force)
      FORCE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: Unknown option '$1'." >&2
      usage
      exit 1
      ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  echo "Error: Not inside a git repository." >&2
  exit 1
fi

if [[ "$REPO_ROOT" != *"/.local/share/opencode/worktree/"* ]]; then
  echo "Not in an OpenCode sandbox worktree. Skipping symlink setup."
  exit 0
fi

if [[ -z "$SOURCE_ROOT" ]]; then
  MAIN_CANDIDATE=""
  FALLBACK_CANDIDATE=""

  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        candidate="${line#worktree }"
        if [[ "$candidate" == "$REPO_ROOT" ]]; then
          continue
        fi

        if [[ "$candidate" != *"/.local/share/opencode/worktree/"* ]]; then
          MAIN_CANDIDATE="$candidate"
          break
        fi

        if [[ -z "$FALLBACK_CANDIDATE" ]]; then
          FALLBACK_CANDIDATE="$candidate"
        fi
        ;;
    esac
  done < <(git -C "$REPO_ROOT" worktree list --porcelain)

  SOURCE_ROOT="$MAIN_CANDIDATE"
  if [[ -z "$SOURCE_ROOT" ]]; then
    SOURCE_ROOT="$FALLBACK_CANDIDATE"
  fi
fi

if [[ -z "$SOURCE_ROOT" ]]; then
  echo "Error: Could not auto-detect source worktree. Use --source-root <path>." >&2
  exit 1
fi

SOURCE_INFRA="$SOURCE_ROOT/infra"
DEST_INFRA="$REPO_ROOT/infra"

if [[ ! -d "$SOURCE_INFRA" ]]; then
  echo "Error: Source infra directory not found: $SOURCE_INFRA" >&2
  exit 1
fi

if [[ ! -d "$DEST_INFRA" ]]; then
  echo "Error: Destination infra directory not found: $DEST_INFRA" >&2
  exit 1
fi

link_file() {
  local src="$1"
  local dst="$2"
  local required="$3"

  if [[ ! -e "$src" ]]; then
    if [[ "$required" == "true" ]]; then
      echo "Error: Required source file missing: $src" >&2
      exit 1
    fi

    echo "Skipping optional file (not found): $src"
    return
  fi

  if [[ -L "$dst" ]]; then
    current_target="$(readlink "$dst")"
    if [[ "$current_target" == "$src" ]]; then
      echo "OK: $dst already points to $src"
      return
    fi

    if [[ "$FORCE" == "true" ]]; then
      ln -sfn "$src" "$dst"
      echo "Updated symlink: $dst -> $src"
      return
    fi

    echo "Error: $dst already exists as a symlink to $current_target (use --force to replace)." >&2
    exit 1
  fi

  if [[ -e "$dst" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      rm -rf "$dst"
      ln -s "$src" "$dst"
      echo "Replaced existing path: $dst -> $src"
      return
    fi

    echo "Error: $dst exists and is not a symlink (use --force to replace)." >&2
    exit 1
  fi

  ln -s "$src" "$dst"
  echo "Created symlink: $dst -> $src"
}

link_file "$SOURCE_INFRA/.env" "$DEST_INFRA/.env" "true"
link_file "$SOURCE_INFRA/terraform.tfstate" "$DEST_INFRA/terraform.tfstate" "true"
link_file "$SOURCE_INFRA/terraform.tfstate.backup" "$DEST_INFRA/terraform.tfstate.backup" "false"
link_file "$SOURCE_INFRA/.terraform" "$DEST_INFRA/.terraform" "false"

echo "Sandbox symlink setup complete."

if command -v direnv >/dev/null 2>&1; then
  echo "Authorizing direnv for this sandbox..."
  if direnv allow; then
    echo "direnv authorized. The .envrc will now load environment variables from the symlinked .env file."
  else
    echo "Warning: direnv allow failed. You may need to run 'direnv allow' manually."
  fi
else
  echo "Warning: direnv is not installed. To load environment variables automatically, either:"
  echo "  1. Install direnv and run: eval \"\$(direnv hook zsh)\" && direnv allow"
  echo "  2. Or export variables manually: export \$(grep -v '^#' infra/.env | grep -v '^$' | xargs)"
fi
