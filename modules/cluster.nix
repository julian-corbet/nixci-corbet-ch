#
# nixci's cluster surface: declare what the continuous-integration platform runs, and render it.
#
# ── THIS MODULE DOES NOT IMPLEMENT KUBERNETES, AND THAT IS THE WHOLE DESIGN ─────────────────────
#
# There is a sibling repository whose entire subject is the app grammar -- an app declares WHAT IT
# NEEDS (an image, ports, an exposure class, which existing claims or node paths hold its state,
# which existing Secrets it consumes) and that grammar renders the Argo CD Application, the
# Namespace, the Deployment and the Service. Everything this module can express in those terms is
# expressed in them: it DEFINES INTO `nixk3s.apps` and renders no Kubernetes object of its own.
#
# So this module is a translator, not a renderer. What it adds is the one thing the grammar cannot
# know: what a CI platform IS. Which port a forge listens on and which directory it writes its own
# instance secret into; which two ports a CI server serves and which of them agents dial; that a
# cache serves its store READ-ONLY; that a warm runner is the single writer of its own store; and
# which of two planes each of those belongs to.
#
# IMPORT THE GRAMMAR ALONGSIDE THIS MODULE. `nixk3s.apps` is declared there, not here, and a render
# that composes this module without it fails with "the option `nixk3s.apps' does not exist". That
# is a hard requirement rather than an optional integration, and it is deliberately not softened: a
# version of this module that quietly rendered its own Deployments when the grammar was absent
# would be the second implementation this repository exists to not have.
#
# ── THE CONTROL/EXECUTION AXIS IS THE STRUCTURE OF THIS FILE ───────────────────────────────────
#
# One question decides everything here: DOES REPO CODE RUN IN THIS WORKLOAD?
#
#   CONTROL PLANE    the forge, the CI server, the cache, a runner controller, a schedule. They
#                    hold the platform's credentials -- the forge's OAuth client secret, the
#                    server's admin token, the shared agent secret in full.
#   EXECUTION PLANE  every runner, and the warm builder. Pipeline steps run here, as processes in
#                    the pod or as pods it creates. This is where untrusted code executes.
#
# THE SEPARATION IS STRUCTURAL RATHER THAN ADVISORY, and it is worth listing exactly how, because
# "we documented the boundary" is how every boundary is eventually crossed:
#
#   1. A WORKLOAD'S PLANE IS NOT DECLARABLE. It is read from the catalogue entry, because which
#      plane a piece of software belongs in is a property of the software.
#   2. THERE IS NO `namespace` OPTION ANYWHERE. A workload's namespace is its PLANE's namespace,
#      and the two namespaces are two defaultless platform options that must differ. So a runner
#      cannot be moved next to the server by editing one line -- there is no line.
#   3. AN EXECUTION-PLANE WORKLOAD HAS NO `exposure` AND NO `slot` OPTION AT ALL. Writing either
#      is "the option does not exist", not a warning. And every execution-plane catalogue entry
#      declares zero ports, which is what makes the grammar render NO SERVICE for it: nothing in
#      this repository can give a workload that runs repo code an inbound address.
#   4. A SECRET NAME MAY NOT APPEAR ON BOTH PLANES. That is the load-bearing invariant of the whole
#      repository and it fails eval, naming the Secret and both workloads. The control plane's
#      credential set is a superset of the execution plane's by content and DISJOINT from it by
#      object: the server and the runner share one secret VALUE and never one Secret.
#   5. THE ONLY THING THAT CROSSES IS AN OUTBOUND DIAL, and this module COMPUTES it. A runner's
#      server address is built from the server it serves and the control namespace -- so nobody
#      writes a cross-plane address by hand, and the direction is fixed by construction.
#
# ── THE TWO THINGS THE GRAMMAR CANNOT EXPRESS ──────────────────────────────────────────────────
#
#   1. A CHART DELIVERY. A runner controller ships as its vendor's Helm chart -- custom resource
#      definitions, RBAC, webhooks and a Deployment, versioned together by people who are not us.
#      The grammar renders a Deployment from an image, which is not that.
#   2. A SCHEDULE. `nixci.jobs` is work that fires on a timer. The grammar renders a Deployment for
#      every app, unconditionally, so it cannot express a workload that is not a running process.
#
# Both land on `applications.<name>` -- the RENDERER's own term, one level below the grammar --
# with their object text taken as a value (`manifests`). `nixci.renderedDirectly` lists every
# workload that took that route, so the untyped side of the platform is COUNTABLE.
#
# SERVER-SIDE APPLY IS NOT OPTIONAL ON THOSE, and the reason is a hard limit rather than a
# preference: a controller's custom resource definitions are large enough that a client-side apply
# overruns the 262144-byte annotation Kubernetes keeps the last-applied state in, and the apply
# simply fails. Server-side diff comes with it, because comparing a client-side reconstruction of a
# large resource against what the API server holds produces permanent phantom drift.
#
# ── AND ONE THING THAT RENDERS NOTHING AT ALL ──────────────────────────────────────────────────
#
# A forge somebody else runs. `delivery = "reference"` produces no object of any kind, and the
# declaration exists to be checked against: a runner may name it, a server may authenticate against
# it, and the platform's report can say the dependency is there. A model that could only name what
# it deploys would not make the remote forge go away -- it would only make it invisible.
#
# ONE NAMESPACE. Everything declared here lives under `nixci`, like every repo in this family.
{ config, lib, ... }:
let
  cfg = config.nixci;
  platform = cfg.platform;

  catalogue = import ../lib/systems.nix { };

  enabledOf = attrs: lib.filterAttrs (_: w: w.enable) attrs;

  forges = enabledOf cfg.forges;
  servers = enabledOf cfg.servers;
  caches = enabledOf cfg.caches;
  controllers = enabledOf cfg.controllers;
  runners = enabledOf cfg.runners;
  jobs = enabledOf cfg.jobs;

  # A schedule is not a piece of software, so it has no catalogue entry. It gets a synthetic one so
  # that every rule below is written once against a uniform shape rather than twice with an "unless
  # it is a job" clause -- the kind of clause that is how a guard eventually misses a case.
  jobEntry = {
    plane = "control";
    delivery = "chart";
    image = null;
    chart = null;
    ports = { };
    primaryPort = null;
    state = { };
    caches = { };
    env = { };
    args = [ ];
    readiness = null;
    credentials = { };
  };

  # Every declared workload, tagged with its kind and its catalogue entry, in one list. Almost every
  # guard here is about the platform AS A WHOLE -- a Secret named from both planes, two workloads on
  # one slot, two workloads creating one namespace -- so they are written against this rather than
  # against six separate tables.
  allWorkloads =
    lib.mapAttrsToList (name: w: { inherit name w; kind = "forge"; entry = catalogue.forges.${w.forge}; }) forges
    ++ lib.mapAttrsToList (name: w: { inherit name w; kind = "server"; entry = catalogue.servers.${w.server}; }) servers
    ++ lib.mapAttrsToList (name: w: { inherit name w; kind = "cache"; entry = catalogue.caches.${w.cache}; }) caches
    ++ lib.mapAttrsToList (name: w: { inherit name w; kind = "controller"; entry = catalogue.controllers.${w.controller}; }) controllers
    ++ lib.mapAttrsToList (name: w: { inherit name w; kind = "runner"; entry = catalogue.runners.${w.runner}; }) runners
    ++ lib.mapAttrsToList (name: w: { inherit name w; kind = "job"; entry = jobEntry; }) jobs;

  workloadsOfKind = k: lib.filter (x: x.kind == k) allWorkloads;

  ## ---------------------------------------------------------------------
  ## The planes
  ## ---------------------------------------------------------------------

  planeOf = x: x.entry.plane;
  onControl = lib.filter (x: planeOf x == "control") allWorkloads;
  onExecution = lib.filter (x: planeOf x == "execution") allWorkloads;

  # THE ONE PLACE A NAMESPACE COMES FROM. There is no per-workload option, and there will not be
  # one: the plane a workload belongs to decides where it lands, and the plane is the catalogue's.
  namespaceOf = x:
    if planeOf x == "control" then platform.controlNamespace else platform.executionNamespace;

  ## ---------------------------------------------------------------------
  ## Which of the three routes each workload takes
  ## ---------------------------------------------------------------------

  deliveryOf = x: x.entry.delivery;

  byGrammar = lib.filter (x: deliveryOf x == "image") allWorkloads;

  # A chart-delivered workload with nothing to deliver renders no Application at all. That is the
  # correct shape when its chart is deployed by something else in the same cluster -- the
  # declaration still buys every interlock -- and it warns, so the absence is never silent.
  directly = lib.filter (x: deliveryOf x == "chart" && x.w.manifests != [ ]) allWorkloads;

  notRendered = lib.filter (x: deliveryOf x == "reference") allWorkloads;

  ## ---------------------------------------------------------------------
  ## Translation into the app grammar
  ## ---------------------------------------------------------------------

  # Total on purpose. A declaration that names neither an image nor a version is refused below, and a
  # helper that threw on it would take the evaluation down before the refusal could say so. The
  # repository half is never null for an image delivery -- ../checks/clients-eval.nix asserts that
  # over the whole catalogue -- so `toString` here is for the version half alone.
  imageOf = x:
    if x.w.image != null then x.w.image
    else "${toString x.entry.image}:${toString x.w.version}";

  portsOf = x: lib.mapAttrs (_: number: { inherit number; }) x.entry.ports;

  # The knowledge/value split, in one function: WHERE inside the container each directory lands and
  # whether the software may write it come from the catalogue; WHAT BACKS IT comes from the
  # declaration, and neither side can supply the other's half. State and caches merge into one
  # volume set here because Kubernetes has one concept; they are two concepts in the catalogue
  # because backing one is mandatory and backing the other is not.
  #
  # Both halves are filtered to the keys the catalogue actually holds, so a key that is not the
  # catalogue's mounts nothing instead of throwing out of a helper -- the assertion below is what
  # reports it, and a raw "attribute missing" from in here would arrive first and say less.
  knownState = x: lib.filterAttrs (k: _: x.entry.state ? ${k}) x.w.state;
  knownCaches = x: lib.filterAttrs (k: _: x.entry.caches ? ${k}) x.w.caches;

  stateOf = x:
    lib.mapAttrs
      (key: backing: {
        inherit (x.entry.state.${key}) mountPath readOnly;
        inherit (backing) claim hostPath hostPathType;
      })
      (knownState x)
    // lib.mapAttrs
      (key: backing: {
        inherit (x.entry.caches.${key}) mountPath;
        readOnly = false;
        inherit (backing) claim hostPath hostPathType;
      })
      (knownCaches x);

  # The wiring that points a toolchain at a cache, emitted ONLY for the caches actually backed. A
  # variable naming a directory nothing mounted is worse than no variable: the toolchain writes into
  # the container's own filesystem and reports a hit rate that means nothing.
  cacheEnvOf = x:
    lib.foldl' (acc: key: acc // x.entry.caches.${key}.env) { } (lib.attrNames (knownCaches x));

  ## ---------------------------------------------------------------------
  ## The forge coupling: four variables, and only one of them is a value
  ## ---------------------------------------------------------------------

  # Kept TOTAL rather than assuming the named forge is declared. An assertion below refuses that
  # case, and an assertion's message is forced whether or not it holds -- so a helper that threw on
  # the broken input would take the evaluation down instead of reporting it.
  forgeKeyOf = w:
    if (w ? forge) && w.forge != null && (cfg.forges ? ${w.forge})
    then catalogue.forges.${cfg.forges.${w.forge}.forge}.key
    else "UNDECLARED";

  withForge = w: template:
    builtins.replaceStrings [ "{FORGE}" ] [ (lib.toUpper (forgeKeyOf w)) ] template;

  forgeEnvOf = x:
    lib.optionalAttrs (x.kind == "server")
      ({ ${withForge x.w x.entry.forgeEnableEnv} = "true"; }
        // lib.optionalAttrs (x.w.forgeUrl != null) {
        ${withForge x.w x.entry.forgeUrlEnv} = x.w.forgeUrl;
      });

  ## ---------------------------------------------------------------------
  ## The one thing that crosses the planes, and it crosses outbound
  ## ---------------------------------------------------------------------

  # A runner dials its server's agent endpoint. The address is DERIVED -- from the server workload's
  # own name, from the control plane's namespace, from the cluster domain, and from the port the
  # server's catalogue entry says agents dial. Nothing about it is a value anybody supplies, which
  # is exactly why it cannot be pointed the wrong way.
  serverAddressOf = x:
    let
      w = x.w;
      target = w.serves;
      serverEntry = catalogue.servers.${servers.${target}.server};
    in
    lib.optionalAttrs
      (x.kind == "runner"
        && x.entry.serverAddressEnv != null
        && target != null
        && (servers ? ${target}))
      {
        ${x.entry.serverAddressEnv} =
          "${target}.${platform.controlNamespace}.svc.${platform.clusterDomain}"
          + ":${toString serverEntry.ports.${serverEntry.agentPort}}";
      };

  ## ---------------------------------------------------------------------
  ## Credentials: a role is what a credential IS, a Secret is where it lives
  ## ---------------------------------------------------------------------

  # Only the roles the software reads from its ENVIRONMENT are rendered. A chart-delivered
  # workload's credential is consumed by NAME through its own values, so it is published rather
  # than injected -- see `nixci.chartCredentials`.
  envRolesOf = x:
    lib.filterAttrs
      (role: _: (x.entry.credentials.${role} or null) != null
        && x.entry.credentials.${role}.env != null)
      x.w.credentials;

  secretsOf = x:
    lib.mapAttrs
      (role: d: {
        secret = d.secret;
        env.${withForge x.w x.entry.credentials.${role}.env} = d.key;
      })
      (envRolesOf x)
    // lib.listToAttrs
      (map (s: lib.nameValuePair s { secret = s; envFrom = true; }) x.w.envFromSecrets);

  # Every Secret NAME a workload references, by either route. What the plane guard is written
  # against, and what makes the credential split countable rather than a claim.
  secretNamesOf = x:
    lib.unique (lib.mapAttrsToList (_: d: d.secret) x.w.credentials ++ x.w.envFromSecrets);

  secretNamesOfPlane = plane:
    lib.unique (lib.concatMap secretNamesOf (lib.filter (x: planeOf x == plane) allWorkloads));

  ## ---------------------------------------------------------------------
  ## Probes and addressing
  ## ---------------------------------------------------------------------

  probesOf = x:
    lib.optionalAttrs (x.entry.readiness != null) {
      readiness = { port = x.entry.primaryPort; } // x.entry.readiness;
    };

  # Handed to the band model only when the consumer says it is part of the render: `origin` and
  # `slot` are ITS terms, and defining them into a render that does not declare them is an eval
  # error rather than a graceful no-op. An execution-plane workload has no slot option at all, so it
  # is stamped with the origin and no number -- which is what a workload with no Service should be.
  addressingOf = x:
    lib.optionalAttrs (platform.origin != null) {
      origin = platform.origin;
      slot = x.w.slot or null;
    };

  mkGrammarApp = x:
    {
      namespace = namespaceOf x;
      inherit (x.w) createNamespace project;
      exposure = exposureOf x;
      image = imageOf x;
      ports = portsOf x;
      state = stateOf x;
      secrets = secretsOf x;
      env = x.entry.env // cacheEnvOf x // forgeEnvOf x // serverAddressOf x // x.w.env;
      args = x.entry.args ++ x.w.args;
      probes = probesOf x;
    }
    // addressingOf x;

  mkDirectApp = x: {
    namespace = namespaceOf x;
    inherit (x.w) project;
    # Never here: the Namespace this renderer creates carries no protection against being read as
    # no-longer-desired, and a CI namespace holds the forge's repositories. Asserted below.
    createNamespace = false;
    yamls = x.w.manifests;
    syncPolicy.syncOptions.serverSideApply = true;
    compareOptions.serverSideDiff = true;
  };

  ## ---------------------------------------------------------------------
  ## Derived facts the guards are written against
  ## ---------------------------------------------------------------------

  slotOf = x: x.w.slot or null;
  exposureOf = x: x.w.exposure or "internal";
  showSlot = x: if slotOf x == null then "(none)" else toString (slotOf x);

  slotClaims = lib.filter (x: slotOf x != null) allWorkloads;
  claimantsOf = slot: map (x: x.name) (lib.filter (x: slotOf x == slot) slotClaims);
  duplicatedSlots =
    lib.filter (slot: lib.length (claimantsOf slot) > 1)
      (lib.unique (map slotOf slotClaims));

  creatorsOf = ns:
    map (x: x.name) (lib.filter (x: x.w.createNamespace && namespaceOf x == ns) allWorkloads);
  createdNamespaces =
    lib.unique (map namespaceOf (lib.filter (x: x.w.createNamespace) allWorkloads));

  # THE PLANE GUARD's raw material: which workloads on each plane name a given Secret.
  namersOf = plane: secret:
    map (x: x.name)
      (lib.filter (x: planeOf x == plane && lib.elem secret (secretNamesOf x)) allWorkloads);
  crossPlaneSecrets =
    lib.filter (s: namersOf "control" s != [ ] && namersOf "execution" s != [ ])
      (lib.unique (lib.concatMap secretNamesOf allWorkloads));

  ## ---------------------------------------------------------------------
  ## Assertions
  ##
  ## Every message is a TOTAL function of the declaration: an assertion's message is forced whether
  ## or not the assertion holds, so a message that only works in the failing case takes the whole
  ## evaluation down instead of reporting anything.
  ## ---------------------------------------------------------------------

  listNames = names: lib.concatMapStringsSep ", " (n: "`${n}`") names;

  # What a `reference` declaration set that a reference may not have. Computed as a list so the
  # refusal can name the fields instead of saying that something, somewhere, is wrong.
  referenceViolations = w:
    lib.optional (w.manifests != [ ]) "manifests"
    ++ lib.optional (w.state != { }) "state"
    ++ lib.optional (w.caches != { }) "caches"
    ++ lib.optional (w.credentials != { }) "credentials"
    ++ lib.optional (w.envFromSecrets != [ ]) "envFromSecrets"
    ++ lib.optional (w.env != { }) "env"
    ++ lib.optional (w.args != [ ]) "args"
    ++ lib.optional (w.image != null) "image"
    ++ lib.optional (w.version != null) "version"
    ++ lib.optional w.createNamespace "createNamespace"
    ++ lib.optional ((w.slot or null) != null) "slot";

  deliveryAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [
        {
          assertion = deliveryOf x != "image" || w.version != null || w.image != null;
          message =
            "nixci: `${name}` is delivered as a container image, and names neither a `version` nor a whole "
            + "`image` reference. The catalogue holds the image REPOSITORY and never a tag, because which "
            + "version this workload runs is a value: name one, or set `image` to a whole reference to pin "
            + "it by digest.";
        }
        {
          assertion = deliveryOf x != "chart" || w.version == null;
          message =
            "nixci: `${name}` is delivered as its vendor's chart, and names a `version`. The chart's own "
            + "version lives inside the objects you deliver in `manifests`, pinned by whoever rendered them "
            + "-- a second copy out here would be a pin nothing keeps honest, and the two would drift "
            + "silently apart. Remove it.";
        }
        {
          assertion = deliveryOf x != "chart" || w.image == null;
          message =
            "nixci: `${name}` is delivered as a chart and names an `image`. Nothing here renders a container "
            + "for it, so the reference would reach no object at all. The images a chart runs are named "
            + "inside the chart's own values.";
        }
        {
          assertion = deliveryOf x != "image" || w.manifests == [ ];
          message =
            "nixci: `${name}` is rendered in full by the app grammar, so `manifests` here would be a second, "
            + "untyped copy of objects that are already being rendered. For one extra object beside it, use "
            + "the grammar's own escape hatch (`nixk3s.apps.${name}.raw`), which is scanned, warned about "
            + "and counted.";
        }
        {
          assertion = deliveryOf x != "reference" || referenceViolations w == [ ];
          message =
            "nixci: `${name}` names a forge this platform does not run, so it renders no object of any kind "
            + "-- and it sets " + listNames (referenceViolations w) + ". Every one of those is a claim about "
            + "a machine somebody else operates. What the declaration is FOR is the interlocks: a runner may "
            + "name it, a server may authenticate against it, and the platform's report says the dependency "
            + "is there. The credential a runner registers with belongs to the RUNNER, in the execution "
            + "plane, and the OAuth client a server uses belongs to the SERVER, in the control plane.";
        }
      ])
    allWorkloads;

  storageAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [
        {
          assertion = lib.attrNames w.state == lib.attrNames entry.state;
          message =
            "nixci: `${name}` must back every directory this software cannot lose, and backs "
            + (if w.state == { } then "none" else listNames (lib.attrNames w.state))
            + ". It writes: "
            + (if entry.state == { } then "nothing"
            else
              lib.concatStringsSep ", "
                (lib.mapAttrsToList (k: s: "`${k}` at ${s.mountPath}") entry.state))
            + ". An unbacked one is not an error at runtime -- the workload starts, uses the container's "
            + "own filesystem, and loses it at the next restart. For a forge that means every session and "
            + "every token it ever issued; for a CI server it means every build record and every stored "
            + "secret.";
        }
        {
          assertion = lib.all (k: entry.caches ? ${k}) (lib.attrNames w.caches);
          message =
            "nixci: `${name}` backs " + listNames (lib.attrNames w.caches) + " under `caches`, and this "
            + "software has "
            + (if entry.caches == { } then "no reconstructible caches at all"
            else "these: " + listNames (lib.attrNames entry.caches))
            + ". A cache key that is not the catalogue's mounts a volume nothing reads and wires no "
            + "environment, which looks like a warm build and is a cold one.";
        }
        {
          assertion = lib.all
            (backing: (backing.claim == null) != (backing.hostPath == null))
            (lib.attrValues w.state ++ lib.attrValues w.caches);
          message =
            "nixci: `${name}` backs a directory with neither or both of `claim` and `hostPath`. Storage "
            + "needs exactly one backing: an existing claim by name, or a path on the node.";
        }
      ])
    allWorkloads;

  credentialAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w entry;
        known = lib.attrNames entry.credentials;
        unknown = lib.filter (r: !(entry.credentials ? ${r})) (lib.attrNames w.credentials);
        missing = lib.attrNames
          (lib.filterAttrs (r: c: c.required && !(w.credentials ? ${r})) entry.credentials);
      in
      [
        {
          assertion = unknown == [ ];
          message =
            "nixci: `${name}` names credential role(s) " + listNames unknown + " that this software does "
            + "not read. It reads "
            + (if known == [ ] then "none at all" else listNames known)
            + ". A role nothing reads renders a reference into a variable no process looks at, which is "
            + "worse than being refused because it looks provisioned.";
        }
        {
          assertion = missing == [ ];
          message =
            "nixci: `${name}` is missing required credential role(s) " + listNames missing + ". Name the "
            + "existing Secret and the key inside it -- never the value; everything this module renders is "
            + "committed to git.";
        }
      ])
    allWorkloads;

  serverAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [
        {
          assertion = cfg.forges ? ${w.forge};
          message =
            "nixci: CI server `${name}` authenticates against forge `${toString w.forge}`, which is not "
            + "declared in `nixci.forges`. The server would render an OAuth configuration pointing at "
            + "nothing: it comes up, serves its login page, and every sign-in fails at the redirect. "
            + "Declare the forge -- and if somebody else runs it, declare it as the reference it is.";
        }
        {
          assertion = !(cfg.forges ? ${w.forge}) || lib.elem (forgeKeyOf w) entry.forges;
          message =
            "nixci: CI server `${name}` authenticates against forge `${toString w.forge}` (kind "
            + "`${forgeKeyOf w}`), and this server speaks to " + listNames entry.forges + ". The forge "
            + "coupling is four variables named for the forge kind, so an unsupported one does not "
            + "degrade -- it renders variables the server never reads.";
        }
        {
          assertion =
            !(cfg.forges ? ${w.forge})
            || !(catalogue.forges.${cfg.forges.${w.forge}.forge}.hosted)
            || w.forgeUrl != null;
          message =
            "nixci: CI server `${name}` authenticates against a SELF-HOSTED forge and names no `forgeUrl`. "
            + "There is no default anybody could know: a hosted forge's URL is a fleet fact. It is the "
            + "address a browser is redirected to for the OAuth handshake, so it is the forge's public one "
            + "rather than its in-cluster name.";
        }
      ])
    (workloadsOfKind "server");

  runnerAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [
        {
          assertion = entry.dials != "server" || (servers ? ${toString w.serves});
          message =
            "nixci: runner `${name}` dials a CI server and `serves` names `${toString w.serves}`, which is "
            + "not a declared, enabled server. Nothing else can supply that address: this module DERIVES it "
            + "from the server's own name and the control plane's namespace, precisely so that a cross-plane "
            + "address is never written by hand.";
        }
        {
          assertion = entry.dials != "forge" || (forges ? ${toString w.serves});
          message =
            "nixci: runner `${name}` registers against a forge and `serves` names `${toString w.serves}`, "
            + "which is not declared in `nixci.forges`. Declare it -- including when somebody else runs it, "
            + "which is what the reference delivery is for.";
        }
        {
          assertion = entry.dials != "external" || w.serves == null;
          message =
            "nixci: runner `${name}` talks to a control plane outside this model -- a vendor's service on "
            + "the internet -- and `serves` names `${toString w.serves}`. There is nothing here for it to "
            + "point at, and a reference that resolves to nothing reads as a wiring that exists. Leave it "
            + "null; the absence is the accurate statement.";
        }
        {
          # THE CONTROLLER INTERLOCK. Without it the failure is the worst kind available: every object
          # applies cleanly, the delivery tool reports the whole platform healthy, and no runner ever
          # registers -- because nothing is watching the resource that describes the pool.
          assertion = entry.controller == null || (controllers ? ${toString w.controller});
          message =
            "nixci: runner `${name}` is a pool reconciled by a `${toString entry.controller}` controller, "
            + "and `controller` names `${toString w.controller}`, which is not declared in "
            + "`nixci.controllers`. The pool's objects would apply, report healthy, and produce no runner "
            + "at all. Declare the controller -- it belongs in the CONTROL plane, and this module binds the "
            + "two together for you.";
        }
        {
          assertion =
            entry.controller == null
            || !(controllers ? ${toString w.controller})
            || lib.elem w.runner catalogue.controllers.${controllers.${w.controller}.controller}.manages;
          message =
            "nixci: runner `${name}` names controller `${toString w.controller}`, which does not reconcile "
            + "`${w.runner}` pools. A controller watches the resources of its own runner system and ignores "
            + "everything else, so the mismatch is silent at runtime.";
        }
        {
          assertion = entry.controller != null || w.controller == null;
          message =
            "nixci: runner `${name}` names a controller, and this runner system has none -- it connects to "
            + "its control plane itself. Nothing would bind the two, and the name would only make a reader "
            + "believe something reconciles this pool.";
        }
      ])
    (workloadsOfKind "runner");

  jobAssertions = map
    (x: {
      assertion = x.w.manifests != [ ];
      message =
        "nixci: scheduled job `${x.name}` delivers nothing -- `manifests` is empty. A schedule is not a "
        + "running process, so the app grammar has no term for it and its object is taken as a value, "
        + "exactly like a chart's. With none, the declaration renders an Application with nothing in it "
        + "and nothing ever fires.";
    })
    (workloadsOfKind "job");

  # THE ORDERING GUARD. One pair at a time, so the refusal names both workloads and both numbers
  # rather than reporting that something, somewhere, is out of order.
  orderingAssertions = lib.concatMap
    (server: map
      (forge: {
        assertion =
          slotOf forge == null || slotOf server == null || slotOf forge < slotOf server;
        message =
          "nixci: CI server `${server.name}` holds slot ${showSlot server} and the forge it authenticates "
          + "through, `${forge.name}`, holds ${showSlot forge}. A forge takes the position BELOW the server "
          + "that logs in through it: they are one subsystem, and the ordering is read by people, for whom "
          + "a subsystem reads correctly only when the thing that is depended upon comes first. Nothing here "
          + "will move either number for you -- a slot is a live identity in every space a fleet maps it "
          + "into. Move them deliberately.";
      })
      (lib.filter
        (f: f.name == server.w.forge && f.entry.hosted)
        (workloadsOfKind "forge")))
    (workloadsOfKind "server");

  planeAssertions =
    # THE LOAD-BEARING INVARIANT OF THIS REPOSITORY.
    map
      (secret: {
        assertion = false;
        message =
          "nixci: Secret `${secret}` is named by workloads on BOTH planes -- "
          + listNames (namersOf "control" secret) + " in the control plane and "
          + listNames (namersOf "execution" secret) + " in the execution plane. The execution plane runs "
          + "code somebody pushed, and the whole reason it is a separate plane is that it receives a "
          + "NARROWER credential than the control plane holds: a server and the runner it hands work to "
          + "share one secret VALUE and must never share one Secret object. Unseal a second Secret, in the "
          + "execution namespace, carrying only what the runner needs.";
      })
      crossPlaneSecrets
    ++ lib.optional (onControl != [ ] && onExecution != [ ]) {
      assertion = platform.controlNamespace != platform.executionNamespace;
      message =
        "nixci: `nixci.platform.controlNamespace` and `nixci.platform.executionNamespace` are the same "
        + "namespace, and this platform declares workloads on both planes. The separation IS the two "
        + "namespaces: one Secret set unseals into each, and a runner in the control namespace can read "
        + "the forge's OAuth client secret and the server's admin token by mounting them. Give the "
        + "execution plane its own namespace.";
    };

  tierAssertions =
    map
      (slot: {
        assertion = false;
        message =
          "nixci: slot ${toString slot} is claimed by more than one workload: " + listNames (claimantsOf slot)
          + ". A slot is one identity in every address space the fleet maps it into, so two claimants is a "
          + "collision in all of them at once.";
      })
      duplicatedSlots
    ++ map
      (ns: {
        assertion = lib.length (creatorsOf ns) == 1;
        message =
          "nixci: namespace `${ns}` is created by more than one workload: " + listNames (creatorsOf ns)
          + ". Two Applications owning one Namespace fight over it. Let exactly one anchor it, or anchor it "
          + "in the tenancy layer and set `createNamespace = false` on all of them.";
      })
      createdNamespaces
    ++ map
      (x: {
        # Lesson paid for elsewhere and encoded here: a Namespace created by an Application that this
        # module renders one level below the grammar carries none of the grammar's protection against
        # being read as no-longer-desired -- and a CI namespace holds the forge's repositories.
        assertion = !x.w.createNamespace;
        message =
          "nixci: workload `${x.name}` is rendered below the app grammar (it delivers whole objects rather "
          + "than a container), and `createNamespace` here would produce a Namespace with no protection "
          + "against being pruned -- which for a namespace holding a forge takes the repositories with it. "
          + "Let a grammar-rendered workload anchor the namespace, or anchor it in the tenancy layer.";
      })
      (lib.filter (x: deliveryOf x == "chart") allWorkloads);

  ## ---------------------------------------------------------------------
  ## Warnings
  ## ---------------------------------------------------------------------

  warnings =
    map
      (x: {
        when = x.w.manifests == [ ];
        message =
          "nixci: `${x.name}` is delivered as a chart and delivers nothing here -- `manifests` is empty, so "
          + "no object is rendered for it. That is correct when its chart is deployed by something else in "
          + "the same cluster, and the declaration still buys the interlocks (a runner pool now knows its "
          + "controller is present, and the credential split is still checked). If it was meant to be "
          + "delivered from here, it is not.";
      })
      (lib.filter (x: deliveryOf x == "chart" && x.kind != "job") allWorkloads)
    ++ map
      (x: {
        when = exposureOf x != "internal";
        message =
          "nixci: workload `${x.name}` declares exposure `${exposureOf x}`, which is a term of "
          + "the app grammar -- and this workload is rendered below the grammar, so the class reaches no "
          + "object. Whatever fronts it is selecting on something else.";
      })
      (lib.filter (x: deliveryOf x == "chart") allWorkloads)
    ++ map
      (x: {
        when = slotOf x != null && platform.origin == null;
        message =
          "nixci: workload `${x.name}` claims slot ${showSlot x}, and `nixci.platform.origin` is unset -- so "
          + "the number is checked for collisions inside this platform, and by nothing for which RANGE it "
          + "may come from. Set the origin when the band model is part of the same render.";
      })
      allWorkloads
    ++ map
      (x: {
        when = x.entry.caches != { } && x.w.caches == { };
        message =
          "nixci: runner `${x.name}` backs none of its reconstructible caches ("
          + listNames (lib.attrNames x.entry.caches) + "), so every build starts cold: an empty package "
          + "store, an empty registry, nothing compiled. That is a correct configuration and an expensive "
          + "one, and it is the single difference between this runner shape and a pod-per-step one.";
      })
      (workloadsOfKind "runner");

  ## ---------------------------------------------------------------------
  ## Option shapes
  ## ---------------------------------------------------------------------

  backingType = lib.types.submodule {
    options = {
      claim = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          NAME of an existing PersistentVolumeClaim backing this directory. A name, never a path.
          Nothing here creates the claim: it outlives every version of the software that mounts it,
          so its existence is not the workload's to declare.
        '';
      };

      hostPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Path on the NODE backing this directory instead of a claim, and in practice the common
          answer for a build cache: it is usually a tuned filesystem somebody curates deliberately,
          and it is shared with whatever else needs to read it.

          IT PINS THE WORKLOAD TO A NODE, because the path only exists on one. The VALUE is a fleet
          fact and belongs to the consumer that passes it in -- no path appears anywhere in this
          repository.
        '';
      };

      hostPathType = lib.mkOption {
        type = lib.types.enum [ "Directory" "DirectoryOrCreate" ];
        default = "Directory";
        description = ''
          Whether a missing node path is an error or is created empty. `Directory` (the default)
          refuses to start, which is the right answer for anything under `state`: a forge that finds
          an empty data directory INITIALISES A NEW FORGE, with no repositories in it, and reports
          itself healthy. `DirectoryOrCreate` is defensible for a cache, where an empty directory is
          genuinely a first run.
        '';
      };
    };
  };

  credentialType = lib.types.submodule {
    options = {
      secret = lib.mkOption {
        type = lib.types.str;
        description = "NAME of an existing Secret holding this credential.";
      };
      key = lib.mkOption {
        type = lib.types.str;
        description = ''
          Which key inside that Secret carries it. Required even for a chart-delivered workload,
          where nothing here renders the reference: the chart's own values need the key too, and it
          is published at `nixci.chartCredentials` for exactly that.
        '';
      };
    };
  };

  # Shared by every workload on either plane. What is NOT here matters as much as what is: no
  # `namespace` (a plane decides that), no `replicas` (a warm runner is a single writer), and no
  # `readOnly` on a backing (whether the software may write a directory is the catalogue's).
  sharedOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to render this workload. Declaring the attribute is declaring the workload, so this
        defaults to true; set false to park a declaration without rendering it.
      '';
    };

    project = lib.mkOption {
      type = lib.types.str;
      default = platform.project;
      defaultText = lib.literalExpression "config.nixci.platform.project";
      description = "Delivery project this workload's Application belongs to.";
    };

    createNamespace = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this workload anchors its plane's namespace. Defaults to false: a CI namespace
        outlives every workload in it, and exactly one thing may own it. Two workloads creating one
        namespace fails eval, and so does anchoring from a workload rendered below the app grammar
        -- that Namespace would carry no protection against being pruned.
      '';
    };

    version = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Which version THIS workload runs, used as the image tag. Required for anything delivered as
        a container image, and refused for anything delivered as a chart -- there the version lives
        inside the objects you deliver, and a second copy here is a pin nothing keeps honest.

        No entry in the catalogue carries a version, and nothing here defaults one: which version is
        running is a value, and a platform mid-migration is running two.
      '';
    };

    image = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Whole image reference, replacing the catalogue repository plus `version`. Set it to PIN BY
        DIGEST (`repository:tag@sha256:...`), which is the only way two syncs of an identical
        rendered tree cannot run different code -- the grammar warns while it is unpinned.

        A workload whose upstream publishes only commit-hash tags is declared the same way as any
        other: the commit goes in `version`, or the whole reference goes here.
      '';
    };

    state = lib.mkOption {
      type = lib.types.attrsOf backingType;
      default = { };
      description = ''
        What BACKS each directory this software cannot lose, keyed by the catalogue's own name for
        it. Where it lands inside the container, and whether the software may write it, are
        knowledge and come from the catalogue; what holds it is a value and comes from here.

        EVERY directory the catalogue names must appear. A forge whose configuration directory is
        unbacked regenerates its instance secret on every restart, which invalidates every session
        and every token it ever issued -- and it reports itself healthy throughout.
      '';
    };

    caches = lib.mkOption {
      type = lib.types.attrsOf backingType;
      default = { };
      description = ''
        What backs each RECONSTRUCTIBLE directory, keyed by the catalogue's own name for it. Unlike
        `state`, backing these is optional: losing one costs a long first build and nothing else.

        Backing one also wires the environment that points its toolchain at the mount, and NOT
        backing it leaves that environment unset -- deliberately, because a variable naming a
        directory nothing mounted produces a build that reports cache hits into the container's own
        disappearing filesystem.
      '';
    };

    credentials = lib.mkOption {
      type = lib.types.attrsOf credentialType;
      default = { };
      description = ''
        The credentials this software reads, keyed by the catalogue's ROLE for each one. WHICH
        environment variable a role arrives in is knowledge; which Secret holds it and under which
        key is a value. A role the software does not read is refused, and a required role that is
        missing is refused.

        A SECRET NAMED HERE MAY NOT ALSO BE NAMED FROM THE OTHER PLANE. That is the load-bearing
        invariant of this repository: a CI server and the runner it hands work to share one secret
        VALUE (the agent secret) and must never share one Secret object, because everything else in
        the server's Secret is something a runner must never be able to read.
      '';
    };

    envFromSecrets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        NAMES of existing Secrets loaded wholesale into the environment, for software whose set of
        keys changes without its declaration changing. Counted by the cross-plane guard exactly like
        a named credential -- a whole-Secret mount is the easiest way to hand the execution plane
        something it should not have.
      '';
    };

    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Extra plain environment, merged OVER whatever the catalogue supplies. Plain is the operative
        word: a credential belongs in a Secret, and an address belongs to whatever allocates
        addresses -- the app grammar scans these values and refuses an address literal.

        This is where capacity goes: how many workflows a runner takes at once, how many jobs a
        build runs in parallel, heap sizes. The catalogue supplies what software needs in order to
        be CORRECT and never what it needs in order to be the right size.
      '';
    };

    args = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra entrypoint arguments, appended to whatever the catalogue supplies.";
    };

    manifests = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Whole objects, as YAML documents, delivered under this workload's Application.

        This is where the two things the app grammar cannot express arrive: a vendor's chart output,
        and a schedule. In both cases the object's schema belongs to somebody else's release, or to
        a kind the grammar has no term for, so its text is a value -- exactly like a node path.

        Refused on a workload the grammar renders in full, and on a reference, which renders nothing
        at all.
      '';
    };
  };

  # ONLY THE CONTROL PLANE GETS THESE. An execution-plane workload has no `exposure` and no `slot`
  # option, so giving one an inbound address is "the option does not exist" rather than a review
  # comment. See this file's header, and studies/the-execution-plane-renders-no-service.md.
  reachableOptions = {
    exposure = lib.mkOption {
      type = lib.types.enum [ "internal" "nb" "public" ];
      default = "internal";
      description = ''
        WHO can reach this workload, as a class and never an address. `internal` is the default. A
        forge and a CI server are usually reachable to people, which is the one thing in this
        platform that genuinely needs a front; a cache is usually reached from inside the cluster
        and by whatever pulls artifacts.

        A term of the app grammar, so it reaches an object only on the workloads the grammar
        renders. On a chart delivery a non-default value warns rather than pretending to do
        something.
      '';
    };

    slot = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      description = ''
        THE POSITION this workload holds in the fleet's ordered identity space. Not an address --
        the layers underneath map it into however many address spaces the fleet keeps, which is
        exactly why nothing here moves one.

        The VALUE is a fleet fact and belongs to the consumer that passes it in. What this module
        does with it is refuse two workloads on one number, and refuse a CI server ordered below the
        forge it authenticates through. Which RANGE the numbers may come from is a different
        question, answered by the band model -- see `nixci.platform.origin`.
      '';
    };
  };

  controlOptions = sharedOptions // reachableOptions;

  mkKind = { extra, description, example }: lib.mkOption {
    default = { };
    inherit description example;
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = controlOptions // extra;
    }));
  };
in
{
  options.nixci.platform = {
    controlNamespace = lib.mkOption {
      type = lib.types.str;
      description = ''
        The namespace every CONTROL-PLANE workload lands in: the forge, the CI server, the cache,
        the runner controllers, the schedules. NO DEFAULT, and evaluation fails naming this option
        the moment any of them is declared.

        There is no per-workload override anywhere in this module, and that is the separation being
        structural rather than advisory: a workload's namespace is its plane's, and its plane is a
        property of the software. What a cluster calls this namespace is a value.
      '';
    };

    executionNamespace = lib.mkOption {
      type = lib.types.str;
      description = ''
        The namespace every EXECUTION-PLANE workload lands in: every runner, and the warm builder.
        This is where code somebody pushed actually runs.

        It must differ from `controlNamespace`, and eval fails when it does not, because the split
        is what makes the credential split possible: one Secret set unseals into each namespace, and
        the execution plane's holds nothing but what a runner needs to say hello.
      '';
    };

    project = lib.mkOption {
      type = lib.types.str;
      default = "default";
      description = ''
        Delivery project every workload lands in unless it says otherwise.

        Defaults to `default` -- the delivery tool's own built-in project, which permits every
        destination and is therefore the answer that cannot break a render. It is not the answer to
        leave in place: name a project of your own so the platform is governed like everything else,
        and note that ONE project spanning both namespaces is the usual shape here, because the two
        planes are one subsystem delivered together.
      '';
    };

    clusterDomain = lib.mkOption {
      type = lib.types.str;
      default = "cluster.local";
      description = ''
        The cluster's internal DNS domain, used to build the ONE address that crosses between the
        planes: the CI server endpoint a runner dials. Defaulted, unlike the namespaces, because it
        is a Kubernetes default rather than a fleet fact -- but it is an option because a cluster
        installed with a different one would otherwise get an address that resolves nowhere.
      '';
    };

    origin = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "nixci";
      description = ''
        The declaring-origin name to stamp on the workloads the app grammar renders, handing their
        slots to the BAND MODEL -- which governs which range of the identity space a declaring
        repository's workloads may take a number from.

        `null` by default because `origin` and `slot` are that model's terms: defining them into a
        render that does not include it fails with "the option does not exist". Set this only when
        it is part of the same render, and set it to the name that model binds a band for.

        Execution-plane workloads are stamped with the origin and no number, which is what the band
        model wants for a workload that renders no Service: it asks for a slot only from something
        with an in-cluster address, and a runner deliberately has none.
      '';
    };
  };

  options.nixci.forges = mkKind {
    description = ''
      Git forges, keyed by a name of your choosing. A forge is CI's CODE-HOSTING HALF -- where the
      repositories live, what fires the trigger, and the identity the CI server authenticates
      through -- which is why it is declared in this repository rather than beside it.

      A forge somebody else runs is declared here too, as a reference: it renders no object at all
      and exists to be named by the workloads that depend on it.
    '';
    example = lib.literalExpression ''
      {
        example-forge = {
          forge = "forgejo";
          version = "0.0.0";
          slot = 65;                       # below the server that logs in through it
          exposure = "public";
          state = {
            data.hostPath   = "/example/state/forge/data";
            config.hostPath = "/example/state/forge/config";
            lfs.hostPath    = "/example/state/forge/lfs";
          };
        };

        # Somebody else's forge. Renders nothing; a runner may still name it.
        example-remote-forge.forge = "github";
      }
    '';
    extra = {
      forge = lib.mkOption {
        type = lib.types.enum (lib.attrNames catalogue.forges);
        description = "Which forge, from the catalogue. Available: ${lib.concatStringsSep ", " (lib.attrNames catalogue.forges)}.";
      };
    };
  };

  options.nixci.servers = mkKind {
    description = ''
      CI servers, keyed by a name of your choosing. The web UI, the API, and the endpoint runners
      dial. A CI server runs no pipeline step itself, which is exactly why it can hold the
      platform's credentials.

      Each names the forge it authenticates through, and that forge must be declared: the login and
      the repository connection are one relationship, so a server pointing at an undeclared forge is
      a server nobody can sign in to.
    '';
    example = lib.literalExpression ''
      {
        example-server = {
          server = "crow";
          version = "0.0.0";
          slot = 66;                            # above the forge it logs in through
          exposure = "nb";
          forge = "example-forge";
          forgeUrl = "https://forge.example.com";
          state.data.hostPath = "/example/state/ci-server";
          credentials = {
            forgeClient = { secret = "example-ci-forge-oauth"; key = "client"; };
            forgeSecret = { secret = "example-ci-forge-oauth"; key = "secret"; };
            agentSecret = { secret = "example-ci-forge-oauth"; key = "agent"; };
          };
        };
      }
    '';
    extra = {
      server = lib.mkOption {
        type = lib.types.enum (lib.attrNames catalogue.servers);
        description = "Which CI server, from the catalogue. Available: ${lib.concatStringsSep ", " (lib.attrNames catalogue.servers)}.";
      };

      forge = lib.mkOption {
        type = lib.types.str;
        description = ''
          NAME of the declared forge this server authenticates through and reads repositories from.
          Required, and defaulted nowhere: a CI server without a forge has no source of pipelines
          and no way for anybody to log in.
        '';
      };

      forgeUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://forge.example.com";
        description = ''
          The forge's URL, as a browser reaches it. A fleet fact, which is why it is here rather
          than in the catalogue -- the VARIABLE it arrives in is knowledge and comes from the
          catalogue entry.

          It is the PUBLIC address rather than the in-cluster one, because it is where the OAuth
          handshake redirects a browser. Required when the forge is self-hosted (nobody could
          default it); optional for a remote forge, which the server already knows how to find.
        '';
      };
    };
  };

  options.nixci.caches = mkKind {
    description = ''
      Artifact caches, keyed by a name of your choosing. Where builds land and what serves them
      back: the third thing a CI platform is made of, after somewhere to keep the code and something
      to run the builds.

      A cache is a CONTROL-plane workload even though its contents come from the execution plane,
      because serving artifacts is not running them. The write face is a separate concern -- see the
      catalogue's own notes, which are explicit about which half of a cache each entry is.
    '';
    example = lib.literalExpression ''
      {
        example-cache = {
          cache = "nar-http";
          version = "0.0.0";
          slot = 67;
          state.store.hostPath = "/example/artifacts/store";   # mounted read-only; the catalogue says so
        };
      }
    '';
    extra = {
      cache = lib.mkOption {
        type = lib.types.enum (lib.attrNames catalogue.caches);
        description = "Which cache, from the catalogue. Available: ${lib.concatStringsSep ", " (lib.attrNames catalogue.caches)}.";
      };
    };
  };

  options.nixci.controllers = mkKind {
    description = ''
      Runner controllers, keyed by a name of your choosing. A controller reconciles a declared
      runner pool into actual runner pods and removes them again when the work is done.

      IT IS A CONTROL-PLANE WORKLOAD WHOSE BLAST RADIUS IS THE EXECUTION PLANE. It runs no repo code
      and holds no registration token; it creates every pod that does. This module publishes the
      coordinates a runner pool needs in order to bind back to it -- see `nixci.crossPlaneBindings`
      -- so that nobody has to write the controller's namespace into an execution-plane declaration.
    '';
    example = lib.literalExpression ''
      {
        example-controller = {
          controller = "arc";
          slot = 68;
          manifests = [ (builtins.readFile ./rendered-controller-chart.yaml) ];
        };
      }
    '';
    extra = {
      controller = lib.mkOption {
        type = lib.types.enum (lib.attrNames catalogue.controllers);
        description = "Which controller, from the catalogue. Available: ${lib.concatStringsSep ", " (lib.attrNames catalogue.controllers)}.";
      };
    };
  };

  options.nixci.jobs = lib.mkOption {
    default = { };
    description = ''
      Scheduled work, keyed by a name of your choosing. A CONTROL-plane kind: it is the thing that
      DECIDES to run, not the thing that runs.

      That distinction is the whole rule for this option. A schedule that builds a repository
      belongs in a pipeline the CI server triggers, so that the build happens where builds happen;
      what belongs here is the schedule whose work is the platform's own -- rotating something,
      sweeping something, bumping a lock file.

      A schedule is not a running process, so the app grammar has no term for it and its object is
      taken as a value, exactly like a chart's. Every one of these appears in `nixci.schedules`,
      because the set of things that fire on a timer holding control-plane credentials is precisely
      the set somebody should be able to read in one place.
    '';
    example = lib.literalExpression ''
      {
        example-nightly = {
          schedule = "0 4 * * *";
          manifests = [ (builtins.readFile ./nightly-cronjob.yaml) ];
        };
      }
    '';
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = controlOptions // {
        schedule = lib.mkOption {
          type = lib.types.str;
          example = "0 4 * * *";
          description = ''
            WHEN this fires, in the notation the object you deliver uses. Nothing here renders it --
            the schedule inside the object is what actually fires -- and it is required anyway,
            because it is what makes `nixci.schedules` a readable answer to "what runs on a timer in
            this platform, and how often". A field that only feeds a report is still a field that
            decides something.
          '';
        };
      };
    }));
  };

  options.nixci.runners = lib.mkOption {
    default = { };
    description = ''
      Runners, keyed by a name of your choosing. THE EXECUTION PLANE: pipeline steps run here, as
      processes inside the pod for a warm runner or as pods it creates for a scheduling one. This is
      where code somebody pushed executes.

      Everything about this option's shape follows from that. There is no `exposure` and no `slot`
      -- a runner dials out and nothing dials in, and no catalogue entry on this plane declares a
      port, so the app grammar renders NO SERVICE for any of them. There is no `namespace`, because
      the plane decides it. And a Secret named here may not be named in the control plane, which is
      what keeps the forge's OAuth client secret out of reach of a build script.

      Running SEVERAL runner systems at once is a real state rather than a transitional one: a warm
      builder for the repositories that benefit from a hot cache, an ephemeral pool for the ones
      whose pipelines are written for somebody else's CI.
    '';
    example = lib.literalExpression ''
      {
        # A warm builder: steps run as processes in this pod, on caches that survive between builds.
        example-builder = {
          runner = "crow-agent";
          version = "0.0.0";
          serves = "example-server";                         # the address is DERIVED from this
          state.workspaces.hostPath = "/example/build/workspaces";
          caches = {
            nix.hostPath   = "/example/build/store";
            cargo.hostPath = "/example/build/cargo";
          };
          credentials.agentSecret = { secret = "example-runner-agent"; key = "agent"; };
        };

        # An ephemeral pool for a remote forge, reconciled by a controller in the OTHER plane.
        example-pool = {
          runner = "gha-scale-set";
          serves = "example-remote-forge";
          controller = "example-controller";
          manifests = [ (builtins.readFile ./rendered-pool-chart.yaml) ];
          credentials.forgeToken = { secret = "example-pool-token"; key = "github_token"; };
        };
      }
    '';
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      # NO `reachableOptions`. See this module's header: an execution-plane workload has no
      # exposure class and no slot, and writing either is an unknown-option error.
      options = sharedOptions // {
        runner = lib.mkOption {
          type = lib.types.enum (lib.attrNames catalogue.runners);
          description = "Which runner system, from the catalogue. Available: ${lib.concatStringsSep ", " (lib.attrNames catalogue.runners)}.";
        };

        serves = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            WHAT this runner connects out to, by the name of a declaration in this platform: a
            declared CI server for a runner that dials one, or a declared forge for a pool that
            registers against one. Which of the two is the catalogue's to say.

            `null` is the correct answer for a runner whose control plane is a vendor's service on
            the internet -- this repository models that as absence rather than inventing a group for
            it, and the absence is the accurate statement.

            For a runner that dials a CI server, THE ADDRESS IS DERIVED FROM THIS and never
            supplied: the server's own name, the control plane's namespace and the port its
            catalogue entry says agents dial. It is the one thing that crosses between the planes,
            and deriving it is what fixes the direction.
          '';
        };

        controller = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            NAME of the declared controller that reconciles this pool, for a runner system that has
            one. The controller lives in the CONTROL plane; this module derives its namespace and
            its ServiceAccount and publishes the pair at `nixci.crossPlaneBindings`, so an
            execution-plane declaration never writes a control-plane namespace down.

            Naming none where one is required is refused, because the failure otherwise is the worst
            kind available: every object applies, everything reports healthy, and no runner ever
            registers.
          '';
        };
      };
    }));
  };

  # ── Computed, read-only ───────────────────────────────────────────────────────────────────────

  options.nixci.controlPlane = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = map (x: x.name) onControl;
    defaultText = lib.literalExpression "computed from the declared workloads";
    description = "Workloads in the control plane. No repo code runs in any of them.";
  };

  options.nixci.executionPlane = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = map (x: x.name) onExecution;
    defaultText = lib.literalExpression "computed from the declared workloads";
    description = ''
      Workloads in the execution plane: every runner, and the warm builder. Pipeline steps run in
      these. Read-only, and the point of it is that it is COUNTABLE -- this is the list of places
      where untrusted code executes, and a boundary nobody measures becomes the architecture.
    '';
  };

  options.nixci.controlSecrets = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = secretNamesOfPlane "control";
    defaultText = lib.literalExpression "every Secret named by a control-plane workload";
    description = ''
      Secret NAMES the control plane references. Together with `executionSecrets` this is the
      credential split, stated as data: the two lists must be disjoint, eval fails when they are
      not, and a reader can check the claim rather than believe it.
    '';
  };

  options.nixci.executionSecrets = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = secretNamesOfPlane "execution";
    defaultText = lib.literalExpression "every Secret named by an execution-plane workload";
    description = ''
      Secret NAMES the execution plane references -- everything a build script could reach. It
      should be short, and it should contain nothing that grants access to anything but the CI
      server's front door.
    '';
  };

  options.nixci.crossPlaneBindings = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
    readOnly = true;
    default = lib.listToAttrs
      (map
        (x: lib.nameValuePair x.name {
          controller = x.w.controller;
          namespace = platform.controlNamespace;
          serviceAccount = builtins.replaceStrings [ "{RELEASE}" ] [ x.w.controller ]
            catalogue.controllers.${controllers.${x.w.controller}.controller}.serviceAccount;
        })
        (lib.filter
          (x: x.kind == "runner" && x.w.controller != null && (controllers ? ${x.w.controller}))
          allWorkloads));
    defaultText = lib.literalExpression "runner -> the control-plane controller it binds back to";
    description = ''
      runner pool -> `{ controller, namespace, serviceAccount }` for the controller that reconciles
      it, at its control-plane home. Published rather than rendered, because what consumes it is the
      pool's own chart values and a role binding in the execution namespace.

      THE POINT IS WHICH FIELDS ARE DERIVED. A pool names its controller; it never names the
      controller's namespace or its ServiceAccount, because both follow from the controller's plane
      and from its chart. A pool pointed at the wrong account fails by never being reconciled --
      objects apply, nothing is degraded, no runner appears -- which is exactly the failure a
      derived value cannot produce.
    '';
  };

  options.nixci.charts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
    readOnly = true;
    default = lib.listToAttrs
      (map (x: lib.nameValuePair x.name x.entry.chart)
        (lib.filter (x: deliveryOf x == "chart" && x.entry.chart != null) allWorkloads));
    defaultText = lib.literalExpression "the upstream chart coordinates of every chart-delivered workload";
    description = ''
      workload -> `{ repo, name }` for the upstream Helm chart that delivers it. Published rather
      than rendered, and WITHOUT a version, because a version and its digest change every release
      and are pinned by whoever renders the chart -- a copy here would be a second pin that nothing
      keeps honest.
    '';
  };

  options.nixci.chartCredentials = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
    readOnly = true;
    default = lib.listToAttrs
      (map
        (x: lib.nameValuePair x.name
          (lib.mapAttrs (_: d: d.secret)
            (lib.filterAttrs
              (role: _: (x.entry.credentials.${role} or null) != null
                && x.entry.credentials.${role}.env == null)
              x.w.credentials)))
        (lib.filter (x: deliveryOf x == "chart") allWorkloads));
    defaultText = lib.literalExpression "role -> Secret name, for every chart-delivered workload";
    description = ''
      chart-delivered workload -> `role -> Secret name`. A chart's credential is consumed BY NAME
      through its own values rather than as an environment reference this module renders, so it is
      published instead of injected. Nothing here pretends to wire it: the consumer passes the name
      into the chart values it renders, and the cross-plane guard still counts it.
    '';
  };

  options.nixci.schedules = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    readOnly = true;
    default = lib.mapAttrs (_: w: w.schedule) jobs;
    defaultText = lib.literalExpression "every declared scheduled job";
    description = ''
      job -> when it fires. The set of things that run on a timer in the control plane, in one
      readable place, because that set is exactly what nobody remembers and what holds the
      platform's own credentials.
    '';
  };

  options.nixci.slots = lib.mkOption {
    type = lib.types.attrsOf lib.types.ints.unsigned;
    readOnly = true;
    default = lib.listToAttrs (map (x: lib.nameValuePair x.name (slotOf x)) slotClaims);
    defaultText = lib.literalExpression "every declared workload that claims a slot";
    description = ''
      workload -> the position it claims. Control-plane workloads only, structurally: there is no
      slot option on the execution plane, so a runner can never appear here.
    '';
  };

  options.nixci.renderedByGrammar = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = map (x: x.name) byGrammar;
    defaultText = lib.literalExpression "computed from the declared workloads";
    description = "Workloads rendered through the app grammar, in full.";
  };

  options.nixci.renderedDirectly = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = map (x: x.name) directly;
    defaultText = lib.literalExpression "computed from the declared workloads";
    description = ''
      Workloads rendered one level BELOW the app grammar, because what they deliver is a whole
      object rather than a container -- a vendor's chart output, or a schedule.

      Read-only, and the point of it is that it is COUNTABLE: this is the platform's untyped
      surface, and a boundary nobody measures becomes the architecture.
    '';
  };

  options.nixci.notRendered = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = map (x: x.name) notRendered;
    defaultText = lib.literalExpression "every declared reference";
    description = ''
      Declarations that render NO object at all -- a forge somebody else runs. They are declared so
      that the things depending on them can be checked, and listed here so that "what does this
      platform depend on that it does not operate" has an answer.
    '';
  };

  config = {
    # THE WHOLE CLUSTER-FACING RENDER, and there is nothing else: every object this platform
    # produces that can be described as an app is described as one, in somebody else's vocabulary.
    nixk3s.apps = lib.listToAttrs (map (x: lib.nameValuePair x.name (mkGrammarApp x)) byGrammar);

    applications = lib.listToAttrs (map (x: lib.nameValuePair x.name (mkDirectApp x)) directly);

    nixidy.assertions =
      deliveryAssertions
      ++ storageAssertions
      ++ credentialAssertions
      ++ serverAssertions
      ++ runnerAssertions
      ++ jobAssertions
      ++ orderingAssertions
      ++ planeAssertions
      ++ tierAssertions;

    nixidy.warnings = warnings;
  };
}
