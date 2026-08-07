# examples

Placeholder values that make this repository's checks real, and the shortest readable answer to
"what does a declaration actually look like".

- [`all/values.nix`](all/values.nix) — one complete platform, **on both planes**: a hosted forge
  anchoring the control namespace, a forge somebody else runs that renders nothing at all, a CI
  server above the forge it authenticates through, a cache whose store is mounted read-only, a
  runner controller delivered as whole objects, a warm builder anchoring the execution namespace
  with warm caches and a server address nobody wrote down, an ephemeral runner pool bound back to
  the controller across the planes, and a schedule. `nix flake check` renders it through the real
  app grammar and the real renderer and then asserts the manifests field by field — so a module that
  stops evaluating, or that grows a required value nobody supplies, fails in CI rather than in
  somebody's cluster.

**Nothing in here is real.** Every namespace, node path, Secret name, URL, image reference and slot
number is invented for the check. That is not a disclaimer, it is the design: every one of those is
a fleet fact, and this repository supplies none of them — see the main [README](../README.md).
