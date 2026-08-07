# A git forge is part of CI, and a forge somebody else runs is still part of CI

**The question this settles.** Does a git forge belong in a repository whose subject is continuous
integration, or is it a neighbouring service that CI happens to talk to?

**The answer.** It belongs here. A forge is CI's *code-hosting half*: it holds the input, it fires
the trigger, and — in every CI server this catalogue describes — it is also the identity provider.
Those are not three integrations that happen to point at the same host. In a Woodpecker-shaped CI
server the OAuth login *is* the repository connection: the same client credential that lets a person
sign in is the one that reads repositories, registers webhooks and reports statuses. There is no
configuration in which they are separable.

The version of this that made the decision obvious: **the same argument applies to a forge we do not
run.** A platform that builds from a remote forge has exactly the same relationship to it — input,
trigger, identity — and the only thing that differs is who operates the machine. If the local forge
belonged in this repository and the remote one did not, then "part of CI" would be a statement about
ownership rather than about the system, which it plainly is not.

## What it changed in the model

The catalogue's `forges` group carries a `hosted` flag and a `delivery` of `reference` for the forge
nobody here operates. A reference declaration **renders no object of any kind** — no Deployment, no
Service, no Application. It is refused if it carries state, a credential, a version, an image, a slot
or manifests, because each of those is a claim about a machine somebody else runs, and the refusal
names which field was set.

What the declaration buys is everything except the objects:

- a runner pool may name it as what it registers against, and the interlock checks that;
- a CI server may authenticate against it with the same four variables it would use for a local
  forge, because that coupling is templated on the forge *kind*, not written per pairing;
- `nixci.notRendered` says out loud what this platform depends on and does not operate.

Refusing to model it would not have made the dependency go away. It would only have made it
invisible — and an invisible dependency on somebody else's uptime is the one that surprises people.

## The line this does not cross

A forge is in this catalogue because of what it does *for CI*. It is not here because it is a
web application people open, and this repository claims no other web application on those grounds.
The placement rule in `lib/systems.nix` is written to make that decidable: does the thing take code
and turn it into an artifact — host it, trigger on it, build it, or serve the result? A wiki that
lives beside the forge is a wiki.

## One consequence worth writing down separately

Because the forge is the thing the CI server depends on, the ordering guard in `modules/cluster.nix`
refuses a CI server placed *below* the forge it authenticates through in the fleet's ordered identity
space. That is not aesthetic: an ordering is read by people, and a subsystem reads correctly only
when the thing that is depended upon comes first. The refusal names both workloads and both numbers,
because nothing here will move either one — a slot is a live identity in every space a fleet maps it
into.
