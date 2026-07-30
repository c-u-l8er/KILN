defmodule Kiln.Skills.PollWorker do
  @moduledoc """
  Oban worker that polls Graphonomous for successful InteractionTraces
  and crystallizes them into draft manifests.

  This closes dark-factory loop steps 4→5: machine A records a trace
  in Graphonomous via `&memory.episodic.store`, this worker converts
  it to a draft manifest, a reviewer promotes it to `:published`, and
  machine B installs + replays it.

  Cron: configure via the Oban Plugin.Cron spec. Typical cadence is
  every five minutes with overlapping prevention via
  `unique: [period: 300]`.

  ## Args (all optional)

    * `"endpoint"`        — Graphonomous MCP URL override
    * `"state_hash"`      — Fetch traces rooted at a specific StateHash
    * `"limit"`           — Max traces per poll (default 5)

  There is deliberately no owner argument. A poll produces drafts; who
  lists them is decided later and elsewhere. This worker used to refuse
  to run at all (`:agent_id_not_configured`) unless a marketplace agent
  and publisher were configured, which made the engine's own background
  job unrunnable without the marketplace it feeds.
  """

  use Oban.Worker, queue: :skills, max_attempts: 3

  alias Kiln.Manifests
  alias Kiln.Skills.{Crystallization, Crystallizer, GraphonomousClient}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    client = GraphonomousClient.impl()

    with {:ok, traces} <- client.fetch_successful_traces(client_opts(args)),
         {:ok, summary} <- crystallize_all(traces, args) do
      {:ok, summary}
    else
      {:error, reason} ->
        Logger.warning("Skill crystallization poll failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Crystallize every trace in the given list, skipping any that have
  already been crystallized (idempotent via the
  `(source_type, source_id)` unique constraint on
  `fleet.skill_crystallizations`).

  Returns `{:ok, %{crystallized: N, skipped: M, failed: K}}`.
  """
  @spec crystallize_all([map()], map()) :: {:ok, map()} | {:error, term()}
  def crystallize_all(traces, args) when is_list(traces) and is_map(args) do
    results =
      Enum.map(traces, fn trace ->
        crystallize_one(trace,
          worker: "Kiln.Skills.PollWorker",
          source_endpoint: args["endpoint"]
        )
      end)

    tally = Enum.frequencies_by(results, fn {status, _} -> status end)

    {:ok,
     %{
       crystallized: Map.get(tally, :ok, 0),
       skipped: Map.get(tally, :skipped, 0),
       failed: Map.get(tally, :error, 0)
     }}
  end

  @doc """
  Crystallize one trace. Returns `{:ok, manifest}` on success,
  `{:skipped, reason}` when a crystallization for the same source
  already exists, or `{:error, reason}` on a transform/publish failure.
  """
  @spec crystallize_one(map(), keyword()) ::
          {:ok, Kiln.Manifests.Manifest.t()}
          | {:skipped, atom()}
          | {:error, term()}
  def crystallize_one(trace, opts) when is_map(trace) and is_list(opts) do
    case Crystallizer.from_trace(trace, opts) do
      {:ok, %{manifest: manifest_attrs, crystallization: cr_attrs}} ->
        # Pre-check for idempotency: if a crystallization for this
        # (source_type, source_id) already exists we short-circuit
        # without attempting any inserts. This avoids relying on
        # downstream constraint violations — in particular, the
        # manifest's (slug, version) unique constraint would
        # otherwise fire FIRST (since a second run generates the
        # same version "0.1.0") and mask the crystallization-side
        # conflict as a generic changeset error instead of the
        # intended `:already_crystallized` skip.
        if crystallization_exists?(cr_attrs) do
          {:skipped, :already_crystallized}
        else
          insert_pair(manifest_attrs, cr_attrs)
        end

      {:error, {:invalid_trace, reason}} ->
        {:error, {:invalid_trace, reason}}
    end
  end

  defp crystallization_exists?(%{source_type: type, source_id: id})
       when not is_nil(type) and is_binary(id) do
    import Ecto.Query

    Kiln.repo().exists?(
      from(c in Crystallization, where: c.source_type == ^type and c.source_id == ^id)
    )
  end

  defp crystallization_exists?(_), do: false

  # -- internals ----------------------------------------------------

  defp insert_pair(manifest_attrs, cr_attrs) do
    Kiln.repo().transaction(fn ->
      case Manifests.create_draft(manifest_attrs) do
        {:ok, manifest} ->
          cr_attrs = Map.put(cr_attrs, :manifest_id, manifest.id)

          case insert_crystallization(cr_attrs) do
            {:ok, _} ->
              {:ok, manifest}

            {:error, %Ecto.Changeset{errors: errors}} ->
              if Keyword.has_key?(errors, :source_id) do
                Kiln.repo().rollback({:skipped, :already_crystallized})
              else
                Kiln.repo().rollback({:error, errors})
              end
          end

        {:error, changeset} ->
          Kiln.repo().rollback({:error, changeset})
      end
    end)
    |> case do
      {:ok, {:ok, manifest}} -> {:ok, manifest}
      {:error, {:skipped, reason}} -> {:skipped, reason}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_crystallization(attrs) do
    %Crystallization{}
    |> Crystallization.changeset(attrs)
    |> Kiln.repo().insert()
  end

  defp client_opts(args) do
    []
    |> maybe_put(:endpoint, args["endpoint"])
    |> maybe_put(:state_hash, args["state_hash"])
    |> maybe_put(:limit, args["limit"])
  end

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: Keyword.put(list, key, value)
end
