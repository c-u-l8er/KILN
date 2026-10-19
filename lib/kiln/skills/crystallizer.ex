defmodule Kiln.Skills.Crystallizer do
  @moduledoc """
  Pure transform from a Graphonomous procedural artifact to a
  draft-manifest + crystallization-audit pair.

  This module makes no DB calls and no network calls — it takes a
  `TraceInput` (one successful InteractionTrace) or a `ClusterInput`
  (a group of traces sharing the same initial_state_hash) and
  produces the plain-map attrs that `Kiln.Manifests.create_draft/1`
  expects, plus the matching crystallization audit attrs.

  The dark-factory loop is:

      Graphonomous records InteractionTrace (&memory.episodic.store)
        └── PollWorker lists successful traces
              └── Crystallizer.from_trace/2     ← **this module**
                    └── Manifests.create_draft  (status: :draft)
                          └── (a reviewer transitions it to :published)

  What the manifest attrs do *not* contain is an owner. A crystallized
  skill is identified by `(slug, version)` and nothing else; who lists
  it is a question for whatever marketplace consumes KILN's output, and
  is answered after the draft exists rather than being required to
  create one. This module used to `Keyword.fetch!` an `:agent_id` and a
  `:publisher_id`, which meant the engine could not crystallize a trace
  unless a marketplace row already existed for the thing it had not
  built yet.

  Deterministic slug generation, permission derivation from typed
  actions, and postcondition summarization all live here so they can
  be unit-tested in isolation.
  """

  @type trace :: map()
  @type cluster :: %{
          required(:initial_state_hash) => String.t(),
          required(:traces) => [trace()],
          optional(:success_rate) => float()
        }

  @type manifest_attrs :: map()
  @type crystallization_attrs :: map()

  @default_runtime "opensentience"
  @default_version "0.1.0"

  @doc """
  Convert a single successful InteractionTrace into a draft-manifest
  attrs map and a matching crystallization audit attrs map.

  Options (all optional):
    * `:version` — manifest version, default `"0.1.0"`.
    * `:runtime` — default `"opensentience"`.
    * `:category`, `:mcp_servers`, `:source_provider` — attr overrides.
    * `:source_endpoint` — the MCP URL the trace was fetched from.
    * `:worker` — stamped into `crystallized_by_worker`.

  Returns `{:ok, %{manifest: manifest_attrs, crystallization: crystallization_attrs}}`
  or `{:error, {:invalid_trace, reason}}`.
  """
  @spec from_trace(trace(), keyword()) ::
          {:ok, %{manifest: manifest_attrs(), crystallization: crystallization_attrs()}}
          | {:error, {:invalid_trace, String.t()}}
  def from_trace(trace, opts) when is_map(trace) and is_list(opts) do
    with {:ok, trace_id} <- fetch_string(trace, ["trace_id", :trace_id]),
         {:ok, subtype} <- fetch_string(trace, ["body_subtype", :body_subtype]),
         {:ok, edges} <- fetch_list(trace, ["edges", :edges]),
         :ok <- require_non_empty_edges(edges),
         :ok <- require_success_outcome(trace) do
      manifest = build_manifest_from_trace(trace, trace_id, subtype, edges, opts)

      crystallization = %{
        source_type: :interaction_trace,
        source_id: trace_id,
        source_provider: Keyword.get(opts, :source_provider, "graphonomous"),
        source_endpoint: Keyword.get(opts, :source_endpoint),
        body_subtype: subtype,
        edge_count: length(edges),
        initial_state_hash: initial_state_hash(edges),
        contributing_trace_ids: [trace_id],
        success_rate: nil,
        summary: manifest.description,
        generated_slug: manifest.slug,
        derived_permissions: manifest.permissions,
        derived_postconditions: derive_postconditions(edges),
        status: :pending_review,
        crystallized_at: DateTime.utc_now() |> DateTime.truncate(:second),
        crystallized_by_worker: Keyword.get(opts, :worker),
        metadata: %{"trace_outcome" => trace_outcome_string(trace)}
      }

      {:ok, %{manifest: manifest, crystallization: crystallization}}
    end
  end

  @doc """
  Convert a cluster of successful traces that share the same
  `initial_state_hash` into a single draft-manifest + audit pair.

  Uses the *first* trace as the canonical description; contributing
  trace ids are stored in the audit record so you can trace back to
  every recording that informed the skill.
  """
  @spec from_cluster(cluster(), keyword()) ::
          {:ok, %{manifest: manifest_attrs(), crystallization: crystallization_attrs()}}
          | {:error, {:invalid_cluster, String.t()}}
  def from_cluster(%{traces: [canonical | _] = traces} = cluster, opts)
      when is_list(traces) and length(traces) > 0 do
    success_rate = Map.get(cluster, :success_rate) || compute_success_rate(traces)

    case from_trace(canonical, opts) do
      {:ok, %{manifest: mf, crystallization: cr}} ->
        trace_ids =
          traces |> Enum.map(&get_in_s(&1, ["trace_id", :trace_id])) |> Enum.reject(&is_nil/1)

        merged_cr =
          cr
          |> Map.put(:source_type, :procedural_cluster)
          |> Map.put(:source_id, cluster_source_id(cluster, trace_ids))
          |> Map.put(:initial_state_hash, cluster[:initial_state_hash])
          |> Map.put(:contributing_trace_ids, trace_ids)
          |> Map.put(:success_rate, normalize_decimal(success_rate))
          |> Map.update(:metadata, %{}, fn m ->
            Map.merge(m, %{
              "cluster_size" => length(traces),
              "contributing_trace_ids" => trace_ids
            })
          end)

        merged_mf =
          mf
          |> Map.update(:description, "", fn d ->
            d <> " (derived from a cluster of #{length(traces)} successful traces)"
          end)
          |> Map.update(:tags, [], fn tags ->
            (tags ++ ["crystallized-from-cluster"]) |> Enum.uniq()
          end)

        {:ok, %{manifest: merged_mf, crystallization: merged_cr}}

      {:error, {:invalid_trace, reason}} ->
        {:error, {:invalid_cluster, reason}}
    end
  end

  def from_cluster(_, _),
    do: {:error, {:invalid_cluster, "cluster requires a :traces list with 1+ entries"}}

  # -- manifest construction ----------------------------------------

  defp build_manifest_from_trace(trace, trace_id, subtype, edges, opts) do
    goal = get_in_s(trace, ["goal", :goal])
    slug = generate_slug(goal, trace_id)
    action_types = Enum.map(edges, &edge_action_type/1) |> Enum.uniq()
    permissions = derive_permissions(subtype, action_types)

    %{
      name: generate_name(goal, subtype),
      slug: slug,
      version: Keyword.get(opts, :version, @default_version),
      description: build_description(goal, subtype, edges),
      permissions: permissions,
      runtime: Keyword.get(opts, :runtime, @default_runtime),
      category: Keyword.get(opts, :category, "crystallized-skill"),
      tags: ["crystallized", "&body.#{subtype}", "os-011"],
      mcp_servers:
        Keyword.get(opts, :mcp_servers, [
          %{
            name: "graphonomous",
            url: Keyword.get(opts, :source_endpoint, "https://graphonomous-mcp.fly.dev/mcp"),
            required: true
          }
        ]),
      build_pipeline: "ci",
      test_results: %{
        "trace_id" => trace_id,
        "edges_replayed" => length(edges),
        "outcome" => trace_outcome_string(trace)
      },
      status: :draft
    }
  end

  # -- permission derivation ----------------------------------------

  @doc """
  Derive the permissions a crystallized skill must declare, given the
  `&body.*` subtype and the set of typed-action types observed in the
  trace. Permission shape matches the Kiln `Manifest.permissions`
  field: `%{capability, scope, reason}`.
  """
  @spec derive_permissions(String.t(), [String.t()]) :: [map()]
  def derive_permissions(subtype, action_types) do
    base = %{
      capability: "&body.#{subtype}",
      scope: "act",
      reason: "Execute typed actions recorded during successful playback"
    }

    extras =
      action_types
      |> Enum.flat_map(&permission_for_action_type/1)
      |> Enum.uniq_by(&Map.take(&1, [:capability, :scope]))

    [base | extras]
  end

  defp permission_for_action_type("navigate"),
    do: [
      %{capability: "network:outbound", scope: "http", reason: "navigation between URLs"}
    ]

  defp permission_for_action_type("upload"),
    do: [%{capability: "fs:read", scope: "user-selected", reason: "upload local files"}]

  defp permission_for_action_type("screenshot"),
    do: [%{capability: "media:capture", scope: "viewport", reason: "capture page state"}]

  defp permission_for_action_type("file_write"),
    do: [%{capability: "fs:write", scope: "sandboxed", reason: "write files on the host"}]

  defp permission_for_action_type("file_delete"),
    do: [%{capability: "fs:delete", scope: "sandboxed", reason: "delete files on the host"}]

  defp permission_for_action_type("shell_exec"),
    do: [%{capability: "os:exec", scope: "sandboxed", reason: "run shell commands"}]

  defp permission_for_action_type(_), do: []

  # -- summary / slug generation ------------------------------------

  @doc "Slugify a goal string; fall back to a trace-id-based slug."
  @spec generate_slug(String.t() | nil, String.t()) :: String.t()
  def generate_slug(goal, trace_id) when is_binary(goal) and goal != "" do
    slug =
      goal
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s\-]/, "")
      |> String.trim()
      |> String.replace(~r/\s+/, "-")
      |> String.slice(0, 60)

    # Append a short hash of the trace_id for uniqueness
    suffix = trace_id_suffix(trace_id)

    case slug do
      "" -> fallback_slug(trace_id)
      s -> s <> "-" <> suffix
    end
  end

  def generate_slug(_, trace_id), do: fallback_slug(trace_id)

  defp fallback_slug(trace_id) do
    "trace-" <> trace_id_suffix(trace_id)
  end

  defp trace_id_suffix(trace_id) when is_binary(trace_id) do
    :crypto.hash(:sha256, trace_id)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 8)
  end

  defp generate_name(goal, subtype) when is_binary(goal) and goal != "" do
    goal |> String.slice(0, 100)
  rescue
    _ -> default_name(subtype)
  end

  defp generate_name(_, subtype), do: default_name(subtype)

  defp default_name(subtype), do: "Crystallized &body.#{subtype} skill"

  defp build_description(goal, subtype, edges) do
    intro =
      case goal do
        g when is_binary(g) and g != "" -> "Achieves: #{g}. "
        _ -> ""
      end

    intro <>
      "Crystallized from a GRASP InteractionTrace against &body.#{subtype} " <>
      "(#{length(edges)} recorded edges). Replay requires a conforming " <>
      "&body.#{subtype} provider and fresh authorization for any destructive edges."
  end

  # -- cluster helpers ----------------------------------------------

  defp cluster_source_id(cluster, trace_ids) do
    # Deterministic cluster id: initial_state_hash + a short hash of
    # the sorted contributing trace ids.
    base = cluster[:initial_state_hash] || "cluster"

    ids_hash =
      trace_ids
      |> Enum.sort()
      |> Enum.join(",")
      |> (&:crypto.hash(:sha256, &1)).()
      |> Base.encode16(case: :lower)
      |> String.slice(0, 12)

    base <> "|" <> ids_hash
  end

  defp compute_success_rate(traces) do
    total = length(traces)

    successes =
      Enum.count(traces, fn t ->
        trace_outcome_string(t) == "success"
      end)

    if total == 0, do: 0.0, else: successes / total
  end

  defp normalize_decimal(nil), do: nil
  defp normalize_decimal(%Decimal{} = d), do: d
  defp normalize_decimal(n) when is_float(n), do: Decimal.from_float(Float.round(n, 3))
  defp normalize_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp normalize_decimal(_), do: nil

  # -- extraction helpers -------------------------------------------

  defp fetch_string(map, keys) do
    case get_in_s(map, keys) do
      v when is_binary(v) and v != "" ->
        {:ok, v}

      _ ->
        {:error, {:invalid_trace, "#{Enum.join(Enum.map(keys, &to_string/1), "|")} is required"}}
    end
  end

  defp fetch_list(map, keys) do
    case get_in_s(map, keys) do
      v when is_list(v) ->
        {:ok, v}

      _ ->
        {:error,
         {:invalid_trace, "#{Enum.join(Enum.map(keys, &to_string/1), "|")} must be a list"}}
    end
  end

  defp require_non_empty_edges([]), do: {:error, {:invalid_trace, "edges must be non-empty"}}
  defp require_non_empty_edges(_), do: :ok

  defp require_success_outcome(trace) do
    case trace_outcome_string(trace) do
      "success" ->
        :ok

      other ->
        {:error, {:invalid_trace, "only successful traces are crystallizable (outcome=#{other})"}}
    end
  end

  defp trace_outcome_string(trace) do
    case get_in_s(trace, ["outcome", :outcome]) do
      v when is_binary(v) -> v
      v when is_atom(v) and not is_nil(v) -> Atom.to_string(v)
      _ -> "unknown"
    end
  end

  defp edge_action_type(edge) do
    case get_in_s(edge, [["typed_action", "type"], [:typed_action, :type]]) do
      v when is_binary(v) -> v
      _ -> "unknown"
    end
  end

  defp initial_state_hash([first | _]),
    do: get_in_s(first, ["state_before", :state_before])

  defp initial_state_hash(_), do: nil

  defp derive_postconditions(edges) do
    # Cheap heuristic: the final edge's state_after stands in for the
    # skill's achieved-state. Real providers may enrich this via
    # semantic labeling downstream.
    case List.last(edges) do
      nil ->
        []

      edge ->
        case get_in_s(edge, ["state_after", :state_after]) do
          v when is_binary(v) -> ["reaches:" <> v]
          _ -> []
        end
    end
  end

  # `get_in/2`-style lookup that tries both string and atom keys, and
  # accepts a path (list of keys) OR a list of parallel keys to try.
  defp get_in_s(map, keys) when is_map(map) and is_list(keys) do
    cond do
      keys == [] ->
        nil

      # Nested path of path-lists: tries each full path in order.
      Enum.all?(keys, &is_list/1) ->
        Enum.find_value(keys, fn path -> get_in(map, path) end)

      true ->
        # Flat list of keys to try at the top level
        Enum.find_value(keys, fn k -> Map.get(map, k) end)
    end
  end

  defp get_in_s(_, _), do: nil
end
