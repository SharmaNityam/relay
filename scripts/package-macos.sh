#!/bin/bash
# Build movable local-release apps containing their own Python runtime and pinned engine.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
./scripts/build-macos.sh
uv python install 3.12
PYTHON_BIN="$(uv python find --managed-python 3.12)"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/relay-package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
uv build --wheel --out-dir "$STAGING/wheels"
uv export --locked --no-dev --no-emit-project --format requirements-txt --output-file "$STAGING/requirements.txt"
uv pip install --python "$PYTHON_BIN" --target "$STAGING/engine" --require-hashes -r "$STAGING/requirements.txt"
uv pip install --python "$PYTHON_BIN" --target "$STAGING/engine" --no-deps "$STAGING"/wheels/*.whl
"$PYTHON_BIN" - "$REPO_ROOT" "$PYTHON_BIN" "$STAGING/engine" <<'PY'
from pathlib import Path
import shutil,sys
root,python,engine=map(Path,sys.argv[1:])
runtime=python.resolve().parent.parent
for name in ('Relay','Repro'):
    resources=root/'dist'/f'{name}.app'/'Contents'/'Resources'
    for folder in ('runtime','engine'):
        target=resources/folder
        if target.exists(): shutil.rmtree(target)
    shutil.copytree(runtime,resources/'runtime',symlinks=True,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
    shutil.copytree(engine,resources/'engine',symlinks=True,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
    (resources/'backend-path.txt').unlink(missing_ok=True)
    shutil.copy2(root/'scripts'/'Dockerfile.repro',resources/'Dockerfile.repro')
    shutil.copy2(root/'LICENSE',resources/'LICENSE')
PY
for name in Relay Repro; do
  codesign --force --deep --sign - "dist/$name.app"
  codesign --verify --deep --strict "dist/$name.app"
done
PACKAGE_ARCH="$(uname -m)"
ditto -c -k --sequesterRsrc --keepParent dist/Relay.app "dist/Relay-macOS-$PACKAGE_ARCH.zip"
ditto -c -k --sequesterRsrc --keepParent dist/Repro.app "dist/Repro-macOS-$PACKAGE_ARCH.zip"
echo 'Portable local-release bundles are in dist/. They are ad-hoc signed, not notarized.'
