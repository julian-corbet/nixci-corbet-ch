# experiments

Throwaway trials: spikes, one-off scripts, things tried and abandoned or not yet worth writing up.
Nothing here is guaranteed to work, be maintained, or survive the next cleanup pass — except the
file below.

- `verify-upstream-coordinates.sh` — every upstream coordinate in
  [`../lib/systems.nix`](../lib/systems.nix) checked against the registry or chart repository it
  names: container image repositories through the registry API, `oci://` charts the same way, and
  classic chart repositories through their `index.yaml`. `--tags N` additionally lists what upstream
  is shipping right now, which is the question this repository deliberately cannot answer from its
  own data — it pins no versions anywhere. Reads the coordinates out of the catalogue rather than a
  second hand-kept list.

  **It has already earned its place.** The first run disproved a claim that had been written into
  the catalogue by hand: that one project published no image at a coordinate worth recording. It
  publishes one, with about a hundred and seventy tags — and every one of them is a commit hash,
  with no `latest` and no release-shaped tag anywhere. Both halves went into that entry, and the
  second half is the more useful one: a consumer who assumed a semantic version there would have got
  a pull error at the far end of a sync.

## Why this lives here and not in `checks/`

`checks/` is `nix flake check`-wired and evaluates offline. It can prove how a declaration
RESOLVES — and it does, exhaustively, including the plane separation, the credential split and the
manifests that actually come out. What it cannot prove is that a registry still serves a repository
today, or that a chart repository has not been renamed. Those are facts about the world: they change
without this repository changing, and asserting them at eval time would need either network access
from a pure evaluation or a snapshot that silently goes stale.

So the split is deliberate and matches what every sibling repository does with its own name
verification: eval-time checks for anything internal and deterministic, a hand-run script for
anything that depends on what upstream is shipping this week.

## What is deliberately NOT verified here

**Nothing about the client catalogue.** [`../lib/clients.nix`](../lib/clients.nix) is empty on
purpose — this repository claims no host package — so there is no name to check against Arch, the
AUR or nixpkgs. The day an entry lands, the sibling repositories already carry the verification
contract to copy: four independent sources per name, a forced nixpkgs attribute rather than an
existence check, and a cross-check of the command surface.

**Nothing about versions.** The catalogue names repositories and coordinates and no versions at all,
because which version a workload runs is a value supplied by whoever declares it. Checking that a
repository exists proves nothing about the tag somebody actually deploys — which is exactly why
`--tags` prints them instead of asserting one.

If something in here turns out to matter in a different way, distil the actual finding into
[`../studies/`](../studies/README.md) and let the experiment stay disposable (or delete it).

See the main [README](../README.md) for the project itself.
