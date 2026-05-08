package github_actions

import future.keywords.if
import future.keywords.in
import future.keywords.contains

# Owners considered "first-party" by GitHub — allowed to use major-version tags.
github_owned := {"actions", "github"}

# Match a commit SHA: 40 hex characters.
is_sha(ref) if {
  count(ref) == 40
  regex.match("^[0-9a-fA-F]{40}$", ref)
}

# --- Rule 1: third-party `uses:` must be pinned to a commit SHA. ---

deny contains msg if {
  some _, job in input.jobs
  some step in job.steps
  uses := step.uses
  is_string(uses)
  parts := split(uses, "@")
  count(parts) == 2
  ref := parts[1]
  not is_sha(ref)
  owner := split(parts[0], "/")[0]
  not owner in github_owned
  msg := sprintf("step uses '%s' must be pinned to a commit SHA (third-party actions cannot use tags or branches)", [uses])
}

# --- Rule 2: every job needs an explicit permissions block (top-level or job-level). ---

deny contains msg if {
  not input.permissions
  some name, job in input.jobs
  not job.permissions
  msg := sprintf("job '%s' has no permissions block (and no top-level permissions either) — implicit defaults are forbidden", [name])
}

# --- Rule 3: no user-controllable PR fields interpolated into `run:`. ---

forbidden_expressions := {
  "github.event.pull_request.title",
  "github.event.pull_request.body",
  "github.event.pull_request.head.ref",
  "github.event.issue.title",
  "github.event.issue.body",
  "github.event.comment.body",
  "github.event.review.body",
  "github.head_ref",
}

deny contains msg if {
  some _, job in input.jobs
  some step in job.steps
  run := step.run
  is_string(run)
  some expr in forbidden_expressions
  contains(run, expr)
  msg := sprintf("step `run:` interpolates user-controllable field '${{ %s }}' — workflow injection risk; pass via env: instead", [expr])
}
