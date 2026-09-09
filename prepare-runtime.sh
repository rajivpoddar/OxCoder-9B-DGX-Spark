#!/usr/bin/env bash
# Apply exactly the recipe's overlay to its pinned dependency, idempotently.
set -euo pipefail
runtime_dir="${1:?llama.cpp directory required}"
revision="${2:?pinned revision required}"
recipe_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
patch_file="$recipe_dir/patches/prefill-fairness.patch"

if [[ ! -e "$runtime_dir" ]]; then
  git clone https://github.com/ggml-org/llama.cpp.git "$runtime_dir"
fi
git -C "$runtime_dir" rev-parse --is-inside-work-tree >/dev/null
# Never accept unrelated staged or untracked work, even if reverse apply passes.
git -C "$runtime_dir" diff --cached --quiet || { echo 'staged dependency changes; refusing' >&2; exit 1; }
[[ -z "$(git -C "$runtime_dir" ls-files --others --exclude-standard)" ]] || {
  echo 'untracked dependency files; refusing' >&2; exit 1;
}
if ! git -C "$runtime_dir" diff --quiet; then
  [[ "$(git -C "$runtime_dir" rev-parse HEAD)" == "$revision" ]] &&
    cmp -s <(git -C "$runtime_dir" diff --binary --full-index HEAD) "$patch_file" || {
      echo 'dependency differs from the exact pinned recipe overlay; refusing' >&2; exit 1;
    }
  echo 'Pinned fairness overlay already present'
  exit 0
fi
if [[ "$(git -C "$runtime_dir" rev-parse HEAD)" != "$revision" ]]; then
  git -C "$runtime_dir" fetch --quiet origin "$revision"
  git -C "$runtime_dir" checkout --quiet --detach "$revision"
fi
git -C "$runtime_dir" apply --check "$patch_file"
git -C "$runtime_dir" apply "$patch_file"
cmp -s <(git -C "$runtime_dir" diff --binary --full-index HEAD) "$patch_file"
echo 'Applied pinned fairness overlay'
