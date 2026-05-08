package github_actions_test

import future.keywords.if
import future.keywords.in
import data.github_actions

# --- Rule 1: third-party action pinned to commit SHA ---

test_deny_third_party_branch_or_tag if {
  inp := {
    "permissions": {"contents": "read"},
    "jobs": {"build": {
      "runs-on": "ubuntu-latest",
      "permissions": {"contents": "read"},
      "steps": [{"uses": "appleboy/ssh-action@v1.0.3"}],
    }},
  }
  deny_set := {m | some m in github_actions.deny with input as inp}
  count(deny_set) > 0
}

test_allow_third_party_pinned_to_sha if {
  inp := {
    "permissions": {"contents": "read"},
    "jobs": {"build": {
      "runs-on": "ubuntu-latest",
      "permissions": {"contents": "read"},
      "steps": [{"uses": "appleboy/ssh-action@a5ac7e51b41094c92402da3b24376905380afc29"}],
    }},
  }
  deny_set := {m | some m in github_actions.deny with input as inp}
  count(deny_set) == 0
}

test_allow_github_owned_action_with_tag if {
  inp := {
    "permissions": {"contents": "read"},
    "jobs": {"build": {
      "runs-on": "ubuntu-latest",
      "permissions": {"contents": "read"},
      "steps": [
        {"uses": "actions/checkout@v4"},
        {"uses": "github/codeql-action/init@v3"},
      ],
    }},
  }
  deny_set := {m | some m in github_actions.deny with input as inp}
  count(deny_set) == 0
}

# --- Rule 2: explicit permissions block required ---

test_deny_missing_permissions if {
  inp := {
    "jobs": {"build": {
      "runs-on": "ubuntu-latest",
      "steps": [{"uses": "actions/checkout@v4"}],
    }},
  }
  deny_set := {m | some m in github_actions.deny with input as inp}
  count(deny_set) > 0
}

test_allow_top_level_permissions if {
  inp := {
    "permissions": {"contents": "read"},
    "jobs": {"build": {
      "runs-on": "ubuntu-latest",
      "steps": [{"uses": "actions/checkout@v4"}],
    }},
  }
  deny_set := {m | some m in github_actions.deny with input as inp}
  count(deny_set) == 0
}

test_allow_job_level_permissions if {
  inp := {
    "jobs": {"build": {
      "runs-on": "ubuntu-latest",
      "permissions": {"contents": "read"},
      "steps": [{"uses": "actions/checkout@v4"}],
    }},
  }
  deny_set := {m | some m in github_actions.deny with input as inp}
  count(deny_set) == 0
}

# --- Rule 3: no PR-injection in run: ---

test_deny_pr_title_in_run if {
  inp := {
    "permissions": {"contents": "read"},
    "jobs": {"build": {
      "runs-on": "ubuntu-latest",
      "permissions": {"contents": "read"},
      "steps": [{"run": "echo ${{ github.event.pull_request.title }}"}],
    }},
  }
  deny_set := {m | some m in github_actions.deny with input as inp}
  count(deny_set) > 0
}

test_deny_pr_body_in_run if {
  inp := {
    "permissions": {"contents": "read"},
    "jobs": {"build": {
      "runs-on": "ubuntu-latest",
      "permissions": {"contents": "read"},
      "steps": [{"run": "echo \"${{ github.event.pull_request.body }}\""}],
    }},
  }
  deny_set := {m | some m in github_actions.deny with input as inp}
  count(deny_set) > 0
}

test_allow_safe_run if {
  inp := {
    "permissions": {"contents": "read"},
    "jobs": {"build": {
      "runs-on": "ubuntu-latest",
      "permissions": {"contents": "read"},
      "steps": [{"run": "echo hello"}],
    }},
  }
  deny_set := {m | some m in github_actions.deny with input as inp}
  count(deny_set) == 0
}
