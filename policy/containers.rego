package containers

import future.keywords.if
import future.keywords.in
import future.keywords.contains

allowed_publishers := {"caddy"}

deny contains msg if {
  some name, svc in input.services
  svc.ports
  count(svc.ports) > 0
  not name in allowed_publishers
  msg := sprintf("service '%s' must not publish ports to host (only caddy is allowed)", [name])
}

deny contains msg if {
  some name, svc in input.services
  not svc.cap_drop
  msg := sprintf("service '%s' missing cap_drop", [name])
}

deny contains msg if {
  some name, svc in input.services
  svc.privileged == true
  msg := sprintf("service '%s' is privileged (forbidden)", [name])
}
