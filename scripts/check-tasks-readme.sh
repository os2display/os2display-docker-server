#!/usr/bin/env bash
#
# Assert the README's "All tasks" reference block lists every task that
# `task --list` exposes, and vice versa. Run from `task dev:lint:tasks`
# (and the matching CI workflow). Set membership only — section labels,
# descriptions, and ordering are human-curated and not checked.
#
# Why: the README block drifted (B22's `dev:teardown` was missing). A
# CI gate catches that mechanically; the README still gets to keep its
# sectioning + curated descriptions.

set -euo pipefail

# Tasks the Taskfile exposes. `task --list` skips `internal: true` helpers.
# Lines look like:
#   * env:init:                Bootstrap .env.symfony from the API image
#   * cache:clear:             Clear the application cache  (aliases: cc)
# Take the first whitespace-separated token after `* `, then strip the
# trailing `:`. Splitting on the first colon would mangle namespaced names
# (`cache:clear` → `cache`).
#
# `default` is the meta-help task — what `task` (no args) runs. It's
# documented separately in the README ("`task --list` shows…"); we don't
# expect it in the per-section all-tasks table. The filter is folded into
# the awk pass (not a downstream `grep -v`) so an empty parse doesn't
# pipefail-cascade into a silent script exit.
# `NO_COLOR=1` (de-facto standard, https://no-color.org/) disables Task's
# ANSI escapes. CI runners — at least GitHub Actions — appear to set
# something that flips Task into colored-output mode even when stdout
# isn't a TTY, which broke the `^\* ` parse before this fix.
if ! LIST_RAW=$(NO_COLOR=1 task --list 2>&1); then
  echo "Error: 'task --list' failed. Output:" >&2
  printf '%s\n' "$LIST_RAW" | sed 's/^/  /' >&2
  exit 1
fi
LIST_TASKS=$(printf '%s\n' "$LIST_RAW" \
  | awk '/^\* / { sub(/^\* /, ""); sub(/[[:space:]]+.*$/, ""); sub(/:$/, ""); if ($0 != "default") print }' \
  | sort -u)
if [ -z "$LIST_TASKS" ]; then
  echo "Error: parsed no task names from 'task --list' output. Raw output:" >&2
  printf '%s\n' "$LIST_RAW" | head -30 | sed 's/^/  /' >&2
  exit 1
fi

# Tasks the README all-tasks block lists. Format inside the ```text fence:
#   <section>           (no leading whitespace)
#     install              <description>
#     env:init             ...
# Indented lines that start with a task-shaped name are the entries; the
# unindented lines are section labels (skip).
README_TASKS=$(awk '
  /^### All tasks/        { in_block = 1; next }
  in_block && /^```text/  { in_text = 1; next }
  in_text && /^```/       { in_text = 0; in_block = 0; next }
  in_text && /^  [a-zA-Z][a-zA-Z0-9:_-]*[[:space:]]/ {
    name = $1
    print name
  }
' README.md | sort -u)

# Diff. Print useful messages and exit non-zero on any mismatch.
missing_in_readme=$(comm -23 <(printf '%s\n' "$LIST_TASKS") <(printf '%s\n' "$README_TASKS"))
extra_in_readme=$(comm -13 <(printf '%s\n' "$LIST_TASKS") <(printf '%s\n' "$README_TASKS"))

fail=0
if [ -n "$missing_in_readme" ]; then
  echo "::error::Tasks in Taskfile.yml but missing from README's 'All tasks' block:" >&2
  printf '%s\n' "$missing_in_readme" | sed 's/^/  /' >&2
  fail=1
fi
if [ -n "$extra_in_readme" ]; then
  echo "::error::Tasks in README's 'All tasks' block but missing from Taskfile.yml (or marked internal):" >&2
  printf '%s\n' "$extra_in_readme" | sed 's/^/  /' >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "Fix: edit the 'All tasks' block in README.md to match the canonical set." >&2
  echo "       The block is human-curated (section labels, descriptions, alias notes)" >&2
  echo "       — only the SET of task names needs to match." >&2
  exit 1
fi

echo "task --list and README 'All tasks' block agree (${LIST_TASKS:+$(echo "$LIST_TASKS" | wc -l | tr -d ' ')} tasks)."
