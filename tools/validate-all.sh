#!/usr/bin/env bash
# Statically validates every Terraform stack without Azure credentials/subscription.
#   fmt -check  →  init -backend=false  →  validate  →  terraform test (mock provider)
#   (modules/naming has no provider, so only terraform test is really needed there)
# When run without arguments it also checks the shell scripts in scripts/ (bash -n, plus ShellCheck if installed).
#
# Usage:
#   tools/validate-all.sh              # all stacks + shell scripts
#   tools/validate-all.sh 05-aks       # a single stack
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}/terraform"

export CHECKPOINT_DISABLE=1
export TF_IN_AUTOMATION=1

if [ "$#" -gt 0 ]; then
  stacks=("$@")
else
  stacks=()
  for d in [0-9][0-9]-*/; do
    stacks+=("${d%/}")
  done
fi

terraform version | head -1

echo
echo "== modules/naming (fmt, validate, test)"
terraform -chdir=modules/naming fmt -check -diff
terraform -chdir=modules/naming init -backend=false -input=false -no-color >/dev/null
terraform -chdir=modules/naming validate -no-color
terraform -chdir=modules/naming test -no-color

for stack in "${stacks[@]}"; do
  echo
  echo "== ${stack}"
  terraform -chdir="${stack}" fmt -check -diff
  terraform -chdir="${stack}" init -backend=false -input=false -no-color >/dev/null
  terraform -chdir="${stack}" validate -no-color
  # Validates the plan logic (variable validation, count/for_each, conditionals) with the mock provider, without Azure.
  terraform -chdir="${stack}" test -no-color
done

if [ "$#" -eq 0 ]; then
  echo
  echo "== scripts (bash -n, shellcheck)"
  scripts=("${ROOT}"/scripts/*.sh "${ROOT}"/scripts/lib/*.sh "${ROOT}"/scripts/verify/*.sh)
  for f in "${scripts[@]}"; do bash -n "$f"; done
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "${scripts[@]}"
    echo "OK (${#scripts[@]} scripts)"
  else
    echo "shellcheck is not installed, so only the syntax check (bash -n) ran (brew install shellcheck)."
  fi
fi

echo
echo "All checks passed."
