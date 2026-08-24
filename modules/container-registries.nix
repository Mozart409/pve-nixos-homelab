{...}: {
  # Fleet-wide unqualified-search-registries for podman/buildah. Without this,
  # any oci-containers image referenced by a short name (no registry prefix,
  # e.g. "anchore/anchore-engine:v1.1.0") fails with "short-name ... did not
  # resolve to an alias and no unqualified-search registries are defined in
  # /etc/containers/registries.conf" -- this stalled harbor-anchore-catalog in
  # a start-limit-hit crash loop for hours (2026-08-23/24) and blocked
  # harbor-bootstrap, which depends on the Anchore scanner chain.
  virtualisation.containers.registries.search = ["docker.io" "quay.io"];
}
