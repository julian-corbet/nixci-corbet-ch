# The execution plane renders no Service, and that had to stop being a rule

**Finding.** Every runner in a CI platform dials *out*. Not one of them needs an inbound address,
and the plane they live in is the one where code somebody pushed executes — so an inbound address
there is a reachable surface in front of an arbitrary program. Saying so in a README is not worth
much: the way it gets crossed is not a decision, it is one line added to a declaration during an
afternoon of debugging, by somebody who wanted to curl a health endpoint.

So the boundary is enforced at three levels, each of which is enough on its own, and the point of
having three is that widening the surface requires *editing this repository* rather than writing a
declaration.

## 1. The option does not exist

An execution-plane workload's submodule is built from `sharedOptions` alone. The control-plane kinds
get `sharedOptions // reachableOptions`, and `reachableOptions` is where `exposure` and `slot` live.

```
nixci.runners.<name>.exposure = "public";
→ The option `nixci.runners.<name>.exposure' does not exist.
```

That is not a guard firing. There is nothing there to fire. The same is true of `namespace`, which
exists on *neither* plane — a workload's namespace is its plane's namespace, and its plane is read
from the catalogue — so a runner cannot be moved next to the CI server by editing one line, because
there is no line.

`checks/cluster-eval.nix` asserts these as unknown options rather than as refusals, in a set called
`structurallyImpossible`. If somebody adds the option back, that check fails.

## 2. The catalogue entry has no ports

The app grammar this repository renders through emits a Service **only for an app that declares
ports** — a portless workload (a worker, a cron-shaped process) gets a Deployment and nothing else.
So the second lock is in `lib/systems.nix`: every execution-plane entry declares `ports = { }`, and
`checks/clients-eval.nix` asserts that property over the whole catalogue rather than over the
entries that happen to exist today.

This is the lock that survives a mistake in the module. Even if `mkGrammarApp` were changed to pass
an exposure class through, there would still be no port for a Service to target.

## 3. The rendered bytes are read back

`checks/cluster-render.nix` walks every rendered manifest, finds every `Service`, and asserts that
its namespace is the control plane's. Then it does it from the other side: it looks for any Service
in the execution namespace and fails if it finds one.

A claim about a boundary is worth exactly as much as the test that reads the output and finds
nothing there.

## What this cost, and what it bought

**It cost the ability to probe a runner over HTTP**, and that is a real loss worth naming rather
than glossing: a readiness probe on a runner would have to be an exec probe, which this grammar does
not express. The honest answer is that a runner's health is whether its server considers it
connected, which is a fact the server holds and not one a probe can ask the runner for.

**It bought a plane whose attack surface is a list you can read**: `nixci.executionPlane` names every
workload where untrusted code runs, and nothing in that list can be reached from anywhere. A
boundary nobody measures becomes the architecture; this one is countable, in two directions, at
eval time and after rendering.
