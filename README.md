# KILN

The crystallize-and-ship engine for the [&] ecosystem.

KILN turns what an agent *did* into something that can be shipped. It reads
successful interaction traces out of [Graphonomous](https://github.com/c-u-l8er/graphonomous),
crystallizes them into a typed manifest, and records an append-only audit of how
that manifest came to exist.

It is a library. No Repo, no supervision tree, no web layer, no config of its
own — the host supplies all four. That is the difference between an engine and a
product.

## Why it exists separately

KILN was extracted from [FleetPrompt](https://github.com/c-u-l8er/fleetprompt.com),
where it had grown inside the marketplace that consumes it. The two are
different things: KILN produces manifests, FleetPrompt lists them.

The extraction was not cosmetic. `manifests` carried a required `agent_id` and a
required `publisher_id`, which meant the engine could not write its own output
unless a marketplace publisher row already existed — the producer depended on the
consumer, in order to produce the thing the consumer exists to list. The
dependency ran backwards, and it was the one thing making extraction impossible.

A manifest is now identified by `(slug, version)` and by nothing else. Ownership
lives in `fleet.agent_manifests`, a join the marketplace writes when it decides
to list something. A manifest with no agent pointing at it is a manifest that has
been built but not listed — a real state the old schema could not represent.

Two consequences worth knowing:

- `slug` is a registry-wide coordinate now, not a per-agent label. Two agents
  cannot publish the same slug. That is correct for a package registry and it is
  a behaviour change for a marketplace.
- Crystallizing a trace no longer takes an owner. It used to `Keyword.fetch!` an
  `:agent_id`, so the dark-factory poll worker refused to start
  (`:agent_id_not_configured`) unless a marketplace agent was configured.

## What is here

    Kiln                        host seams: repo/0 and schema_prefix/0
    Kiln.Manifests              CRUD keyed on (slug, version)
    Kiln.Manifests.Manifest     the artifact
    Kiln.AuditWriter            append-only provenance
    Kiln.Audit.Event
    Kiln.PipelineIntake         Agentelic ConsolidationEvent -> published manifest
    Kiln.Skills.GraphonomousClient  MCP client for interaction traces
    Kiln.Skills.Crystallizer    pure transform: trace -> draft manifest attrs
    Kiln.Skills.Crystallization  audit row for one crystallization
    Kiln.Skills.PollWorker      optional Oban worker driving the loop

The dark-factory loop KILN owns is steps 4 and 5:

    Graphonomous records an InteractionTrace   (step 3, elsewhere)
      └── PollWorker lists successful traces
            └── Crystallizer.from_trace/2
                  └── Manifests.create_draft   (status: :draft)
                        └── a reviewer publishes it

## What is deliberately not here

No trust scoring, no search, no publisher accounts, no marketplace surface, no
ETS cache, no PubSub broadcast. Trust is a marketplace signal, the old cache was
keyed by agent, and the broadcast went to marketplace subscribers. A host that
wants them does them around the `{:ok, manifest}` that `publish/2` returns, which
is why `publish/2` returns it rather than swallowing it.

You can check the claim by grepping this repo for `agent` or `publisher` and
finding nothing that reads a marketplace table.

## Host contract

    config :kiln,
      repo: MyApp.Repo,
      schema_prefix: "fleet"    # default

`repo/0` raises rather than defaulting. A misconfigured engine that silently
wrote to some other repo would be worse than one that refuses to start.

`schema_prefix` defaults to `"fleet"` because that is where these tables live
today, in the shared Supabase instance, next to the marketplace that used to own
them. KILN's own home is `kiln.*` (migration range 110–119, allocated and
unused). The default is deliberately the *current* truth rather than the intended
one: moving the tables is a data migration on a database other work is live
against, so it is a decision to be taken deliberately, not a side effect of
extracting some code. Changing that one line is the whole of the client-side work
when the decision is made.

Ecto resolves `@schema_prefix` at compile time, so it is read with
`Application.compile_env/3`. A host that changes it must recompile `:kiln`.

Oban is an optional dependency. It is only needed if you run `Kiln.Skills.PollWorker`
as a background job; a host that drives crystallization synchronously does not
inherit a job queue.

## Publishing requires a workspace

`Manifests.publish/2` requires `:workspace_id`, and writes the manifest and its
audit event in one transaction. If the audit cannot be written, nothing is
published.

This is stricter than the code KILN came from, on purpose. That version called
the audit writer for its side effect and discarded the result. Because
`audit_events.workspace_id` is `NOT NULL`, every publish that did not happen to
supply a workspace produced a manifest with no provenance record and reported
success. Nothing failed, which is why nobody noticed.

## Tests

    mix test

85 tests. They run against a real Postgres — the local shared Supabase instance
on port 54322 — inside the Ecto SQL sandbox, and they write real rows. That is
deliberate: an earlier revision of this suite was entirely changeset tests, so it
was green while KILN was still unable to do the one thing it was extracted to do.
`test/kiln/manifests_test.exs` and `test/kiln/skills/poll_worker_test.exs` are
the load-bearing ones.

`test/kiln/skills/graphonomous_client_test.exs` stands up a real HTTP server and
exercises the real `:httpc` transport against a real socket, because a transport
tested only against a stub is a transport that has never been tested.

## Known gaps

- **The ship half is not here.** `install_engine`, `installs` and
  `agent_versions` stayed in FleetPrompt. `installs.agent_id` and
  `agent_versions.agent_id` carry hard foreign keys into `fleet.agents`, so
  extracting them means re-pointing those FKs at manifests — a schema decision
  about what an install is an install *of*, not a refactor.
- **`GraphonomousClient.initialize_telespace/1` has no caller here.** It belongs
  to the ship half — it warms a memory telespace for a newly installed agent. It
  takes an opaque `:agent_id` and passes it to MCP metadata, so it reads no
  marketplace table, but it arrived ahead of the code that will use it.
- **Status transitions are not audited.** `deprecate/2` and `yank/1` write no
  audit event, though `deprecate` and `yank` are both valid audit actions.
- **`manifests.trust_score` is still a column** on an engine table that KILN
  never writes. It is a marketplace value living on the artifact.
- **Tables still live in `fleet.*`.** See the host contract above.

## Licence

MIT.
