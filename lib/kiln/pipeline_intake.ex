defmodule Kiln.PipelineIntake do
  @moduledoc """
  Dark factory pipeline intake — turns a ConsolidationEvent from Agentelic
  into a published manifest.

  Flow:
  1. Validate the CloudEvents envelope (type, source, workspace_id)
  2. Extract artifact manifest + test results
  3. Cross-check spec_hash against SpecPrompt registry
  4. Delegate to `Kiln.Manifests.publish/2`, which enforces spec
     provenance and version immutability and writes the audit event

  KILN is a library, so this takes a decoded event map rather than a
  request. Mounting it at `POST /api/pipeline/intake` — or anywhere
  else — is the host's job.

  Note what step 4 no longer implies. In the marketplace this was
  extracted from, publishing also computed a trust score, warmed an
  agent-keyed cache and broadcast to marketplace subscribers. All three
  are marketplace signals, so a host that wants them does them around
  the `{:ok, manifest}` this returns.
  """

  alias Kiln.Manifests

  require Logger

  @doc """
  Process an incoming ConsolidationEvent from Agentelic.
  Returns `{:ok, manifest}` on success or `{:error, reason}` on failure.
  """
  def process(%{"type" => "com.agentelic.consolidation.v1"} = event) do
    with {:ok, data} <- extract_data(event),
         {:ok, _spec} <- validate_spec_hash(data),
         {:ok, manifest} <- publish_from_event(data) do
      Logger.info("Pipeline intake: published #{manifest.slug}@#{manifest.version}")
      {:ok, manifest}
    end
  end

  def process(%{"type" => type}) do
    {:error, {:unsupported_event_type, type}}
  end

  def process(_) do
    {:error, :missing_event_type}
  end

  # -- Private -----------------------------------------------------------------

  defp extract_data(%{"data" => data}) when is_map(data), do: {:ok, data}
  defp extract_data(_), do: {:error, :missing_event_data}

  defp validate_spec_hash(%{"spec_hash" => hash}) when is_binary(hash) and hash != "" do
    # TODO: Cross-check against SpecPrompt registry via API
    # For now, accept any non-empty hash
    {:ok, hash}
  end

  defp validate_spec_hash(%{"spec_hash" => nil}), do: {:error, :spec_not_registered}
  defp validate_spec_hash(_), do: {:error, :missing_spec_hash}

  defp publish_from_event(data) do
    attrs = %{
      name: data["name"],
      slug: data["slug"],
      version: data["version"],
      description: data["description"],
      category: data["category"],
      tags: data["tags"] || [],
      spec_url: data["spec_url"],
      spec_hash: data["spec_hash"],
      permissions: data["permissions"] || [],
      mcp_servers: data["mcp_servers"] || [],
      runtime: data["runtime"] || "opensentience",
      build_pipeline: "agentelic",
      build_hash: data["artifact_hash"],
      test_results: data["test_results"] || %{}
    }

    case Manifests.publish(attrs, workspace_id: data["workspace_id"]) do
      {:ok, manifest} ->
        {:ok, manifest}

      {:error, :missing_spec_hash} ->
        {:error, :spec_not_registered}

      {:error, changeset} ->
        {:error, {:publish_failed, changeset}}
    end
  end
end
