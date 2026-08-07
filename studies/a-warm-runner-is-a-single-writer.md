# A warm runner is a single writer, and `state` is not the same thing as `caches`

**The shape.** A runner whose pipeline steps run as *processes inside its own pod* shares that pod's
filesystem with every step. That is the entire reason the shape exists: a package store that is
already populated, a crate registry that is already downloaded, object files that are already
compiled. A pod-per-step runner starts cold every single time, and for a large build the difference
is not a percentage.

Two consequences follow, and neither is obvious from the outside.

## 1. There can only ever be one of it

Two processes writing one package-manager store corrupt its database. The corruption does not
announce itself: it surfaces days later as an unrelated build failure, in a build that did nothing
wrong.

So a warm runner is the **single writer** of its own store, and this repository makes that
structural rather than advisory:

- there is **no replica option** anywhere in the module, on either plane;
- declaring any state at all makes the app grammar render `strategy: Recreate` instead of a rolling
  update — because a rolling update deliberately runs two pods at once, which is exactly the thing
  that must never happen here;
- the catalogue records `singleWriter` on the entry, and `checks/clients-eval.nix` asserts that
  every `steps = "process"` entry carries it, so the two facts cannot drift apart.

The natural instinct — scale the builder to two for throughput — is the failure. Concurrency belongs
*inside* one runner (how many workflows it accepts at once), which is capacity and therefore a value
the consumer sets through `env`.

## 2. Losing a cache costs time; losing state costs the build

The catalogue distinguishes two kinds of directory, and the difference is not size and not speed:

| | lose it and | backing it is |
|---|---|---|
| `state` | a running build fails, or data is gone | **mandatory** — eval fails if it is unbacked |
| `caches` | the next build is slow | **optional** |

For a warm builder the workspace directory is state — it holds the checkout a running build is
standing in — and the package store, the crate registry, the compiler object cache and the rest are
caches.

**The wiring follows the backing, and that is the part worth writing down.** Each cache entry in the
catalogue carries the environment that points its toolchain at the mount (`CARGO_HOME`, `GOMODCACHE`,
`SCCACHE_DIR`, …), and the module emits that environment **only for the caches actually backed**.

The alternative — emit the variables unconditionally — produces the worst available outcome: the
toolchain writes its cache into the container's own filesystem, reports healthy cache statistics, and
throws all of it away when the pod restarts. It is slower than having no cache at all, because
nothing tells you it is happening. `checks/cluster-render.nix` asserts both halves: a backed cache is
mounted *and* wired, an unbacked one is neither.

## Why the catalogue records this per entry and not once

Which directories a warm runner should keep depends entirely on what toolchain is in its image, and
that mapping has to be verified per entry rather than copied between them. One runner entry in this
catalogue carries a full cache set and its sibling — the project it was forked from — carries none,
because the mapping was checked for the first and not for the second. An entry that copied the
other's mounts across would be asserting a layout nobody checked, which is the failure mode a
catalogue exists to prevent.
