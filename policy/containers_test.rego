package containers_test

import future.keywords.if
import future.keywords.in
import data.containers

test_deny_public_postgres_port if {
  inp := {"services": {"postgres": {"ports": ["5432:5432"]}}}
  deny_set := {m | some m in containers.deny with input as inp}
  count(deny_set) > 0
}

test_allow_caddy_publishing_ports if {
  inp := {"services": {
    "caddy": {"ports": ["80:80","443:443"], "cap_drop": ["ALL"], "cap_add": ["NET_BIND_SERVICE"]},
    "postgres": {"cap_drop": ["ALL"]},
  }}
  deny_set := {m | some m in containers.deny with input as inp}
  count(deny_set) == 0
}

test_deny_missing_cap_drop if {
  inp := {"services": {"redis": {}}}
  deny_set := {m | some m in containers.deny with input as inp}
  count(deny_set) > 0
}

test_deny_privileged if {
  inp := {"services": {"foo": {"privileged": true, "cap_drop": ["ALL"]}}}
  deny_set := {m | some m in containers.deny with input as inp}
  count(deny_set) > 0
}
