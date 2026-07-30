defmodule Kiln do
  @moduledoc """
  KILN — the crystallize-and-ship engine.

  KILN turns what an agent *did* into something that can be shipped: it reads
  successful interaction traces out of Graphonomous, crystallizes them into a
  typed manifest, and records an append-only audit of how that manifest came to
  exist.

  It was extracted from FleetPrompt, where it had grown inside the marketplace
  that consumes it. The two are different things: KILN produces manifests,
  FleetPrompt lists them. Everything in `compose` uses `core`, and this is a
  `core` engine.

  ## What KILN does not do

  No trust scoring, no search, no publisher accounts, no marketplace surface.
  Those are FleetPrompt's, and KILN does not know they exist — a claim you can
  check by grepping this repo for `agent` or `publisher` and finding nothing
  that reads a marketplace table.

  ## Host responsibilities

  KILN is a library with no Repo, no supervision tree and no config of its own.
  The host supplies:

      config :kiln,
        repo: MyApp.Repo,
        schema_prefix: "fleet"    # default; see below

  ### On `:schema_prefix`

  It defaults to `"fleet"` because that is where these tables live today, in the
  shared Supabase instance, alongside the marketplace that used to own them.
  KILN's own home is `kiln.*` (migration range 110–119, allocated and unused).

  The default is deliberately the *current* truth rather than the intended one.
  Moving the tables is a data migration on a database other work is live
  against, so it is a decision to be taken deliberately, not a side effect of
  extracting some code. Changing this one line is the whole of the client-side
  work when that decision is made.
  """

  @doc """
  The host's Ecto repo.

  Raises rather than defaulting. A misconfigured engine that silently wrote to
  some other repo would be far worse than one that refuses to start.
  """
  @spec repo() :: module()
  def repo do
    Application.get_env(:kiln, :repo) ||
      raise """
      KILN has no repo configured.

          config :kiln, repo: MyApp.Repo

      KILN is a library and does not own a database connection.
      """
  end

  # Resolved in the module body, exactly as each schema resolves its own
  # `@schema_prefix`, so this reports the prefix the tables were compiled with.
  # A runtime `get_env/3` here could report a prefix the tables are not actually
  # in, and an accessor able to disagree with the thing it describes is worse
  # than no accessor at all.
  @schema_prefix Application.compile_env(:kiln, :schema_prefix, "fleet")

  @doc """
  The Postgres schema KILN's tables live in. See the module doc for why this
  defaults to "fleet" rather than "kiln".

  A host that changes `:schema_prefix` must recompile `:kiln` for this to move
  — which is the same condition the schemas themselves are under.
  """
  @spec schema_prefix() :: String.t()
  def schema_prefix, do: @schema_prefix
end
