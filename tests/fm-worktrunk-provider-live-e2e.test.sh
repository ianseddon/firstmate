#!/usr/bin/env bash
# Default-on live guard for the worktrunk worktree provider.
#
# Firstmate drives the REAL `wt` binary for its worktrunk provider
# (bin/fm-spawn.sh acquisition, bin/fm-teardown.sh release), so the exact flags,
# the `--format json` result shape, the non-interactive hook-approval refusal,
# and the existing-branch refusal are vendor facts no fake can prove. This guard
# runs the provider's own commands against the installed wt in an isolated temp
# git repository with an isolated worktrunk config, then fails naming the wt
# version when any of them changes.
#
# It submits no prompt and touches nothing outside its temp root: HOME,
# WORKTRUNK_CONFIG_PATH (whose directory also holds approvals.toml), and the
# worktree-path template all point into it, so ~/.config/worktrunk and the
# operator's worktree directory are never written. The shared live gate runs it
# by default wherever wt, git, and jq exist and skips explicitly when wt is
# absent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_WORKTRUNK_PROVIDER_LIVE_E2E wt git jq

WT_VERSION=$(wt --version 2>&1 | head -n 1)
fail_wt() { fail "worktrunk provider guard ($WT_VERSION): $1"; }

TMP_ROOT=$(fm_test_tmproot fm-worktrunk-provider-live)
export HOME="$TMP_ROOT/home"
export WORKTRUNK_CONFIG_PATH="$TMP_ROOT/worktrunk/config.toml"
export GIT_CONFIG_GLOBAL="$TMP_ROOT/gitconfig" GIT_CONFIG_NOSYSTEM=1
unset WORKTRUNK_WORKTREE_PATH WORKTRUNK_PROJECT_CONFIG_PATH
mkdir -p "$HOME" "$(dirname "$WORKTRUNK_CONFIG_PATH")"
printf 'worktree-path = "%s/wts/{{ repo }}/{{ branch | sanitize }}"\n' "$TMP_ROOT" > "$WORKTRUNK_CONFIG_PATH"
git config --global user.email live@example.invalid
git config --global user.name 'Worktrunk Live Guard'
git config --global init.defaultBranch main

ORIGIN="$TMP_ROOT/origin.git"
PROJ="$TMP_ROOT/project"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$PROJ" 2>/dev/null
printf 'base\n' > "$PROJ/README.md"
mkdir -p "$PROJ/.config"
printf 'pre-start = "echo started > pre-start.txt"\n' > "$PROJ/.config/wt.toml"
printf 'pre-start.txt\n' > "$PROJ/.gitignore"
git -C "$PROJ" add -A
git -C "$PROJ" commit -qm initial
git -C "$PROJ" push -q origin main
git -C "$PROJ" fetch -q origin

wt_q() { wt -C "$PROJ" "$@" </dev/null; }

# 1. Unapproved project hooks: the preflight state, and the switch itself refusing
#    without a terminal before creating anything.
state=$(wt_q config approvals list --format json | jq -r '.state') \
  || fail_wt "wt config approvals list --format json failed"
[ "$state" = approval_required ] || fail_wt "unapproved hooks reported state '$state', not approval_required"
if wt_q switch --create fm/live-unapproved --base origin/main --no-cd --format json >/dev/null 2>&1; then
  fail_wt "wt switch ran unapproved project hooks with no terminal instead of refusing"
fi
! git -C "$PROJ" show-ref --verify --quiet refs/heads/fm/live-unapproved \
  || fail_wt "a refused unapproved switch still created its branch"
pass "unapproved project hooks refuse a non-interactive wt switch before anything is created"

# 2. Approve as the captain would, then create through the provider's exact command.
wt_q config approvals add --yes >/dev/null 2>&1 || fail_wt "wt config approvals add --yes failed"
[ "$(wt_q config approvals list --format json | jq -r '.state')" = approved ] \
  || fail_wt "approved hooks did not report state approved"
out=$(wt_q switch --create feat/live-ship --base origin/main --no-cd --format json 2>/dev/null) \
  || fail_wt "wt switch --create --base origin/main --no-cd --format json failed"
action=$(printf '%s\n' "$out" | jq -r '.action') || fail_wt "switch output is not JSON: $out"
path=$(printf '%s\n' "$out" | jq -r '.path')
[ "$action" = created ] || fail_wt "switch reported action '$action', not created: $out"
[ "$path" = "$TMP_ROOT/wts/project/feat-live-ship" ] || fail_wt "switch reported path '$path', not the sanitized template path"
[ "$(git -C "$path" branch --show-current)" = feat/live-ship ] || fail_wt "the created worktree is not on feat/live-ship"
[ "$(git -C "$path" rev-parse HEAD)" = "$(git -C "$PROJ" rev-parse origin/main)" ] \
  || fail_wt "the created worktree did not start at origin/main"
[ -f "$path/pre-start.txt" ] || fail_wt "the approved pre-start hook did not run"
[ -z "$(git -C "$path" status --porcelain)" ] || fail_wt "the created worktree is not clean"
pass "wt switch --create reports the created worktree path as JSON on its branch at origin/main"

# 3. An existing branch is refused by --create rather than adopted.
if wt_q switch --create feat/live-ship --base origin/main --no-cd --format json >/dev/null 2>&1; then
  fail_wt "wt switch --create adopted an existing branch instead of refusing"
fi
pass "wt switch --create refuses a branch that already exists"

# 4. Teardown's removal: detach and delete the branch first, then remove the
#    dirty worktree in the foreground, keeping the (already deleted) branch.
printf 'scratch\n' > "$path/untracked.txt"
git -C "$path" checkout -q --detach
git -C "$PROJ" branch -q -D feat/live-ship
wt_q remove --foreground --force --no-delete-branch "$path" >/dev/null 2>&1 \
  || fail_wt "wt remove --foreground --force --no-delete-branch <path> failed"
[ ! -e "$path" ] || fail_wt "foreground removal returned before the worktree was gone"
! git -C "$PROJ" worktree list --porcelain | grep -Fqx "worktree $path" \
  || fail_wt "the removed worktree is still registered with git"
pass "wt remove --foreground --force --no-delete-branch removes a dirty detached worktree"

# 5. Spawn abort cleanup: remove a fresh worktree together with its branch.
out=$(wt_q switch --create scout/live-scout --base origin/main --no-cd --format json 2>/dev/null) \
  || fail_wt "creating the scout worktree failed"
path=$(printf '%s\n' "$out" | jq -r '.path')
wt_q remove --foreground --force --force-delete "$path" >/dev/null 2>&1 \
  || fail_wt "wt remove --foreground --force --force-delete <path> failed"
[ ! -e "$path" ] || fail_wt "abort removal left the worktree"
! git -C "$PROJ" show-ref --verify --quiet refs/heads/scout/live-scout \
  || fail_wt "abort removal left the branch"
pass "wt remove --force-delete removes a fresh worktree and its branch"

[ -f "$TMP_ROOT/worktrunk/approvals.toml" ] && [ ! -e "$HOME/.config/worktrunk" ] \
  || fail_wt "approvals were not kept beside the isolated config file"
echo "# worktrunk provider live guard passed against $WT_VERSION"
