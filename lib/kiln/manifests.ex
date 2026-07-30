defmodule Kiln.Manifests do
  @moduledoc """
  Manifest CRUD, keyed on the manifest's own identity: `(slug, version)`.

  This is the half of `FleetPrompt.Registry` that was about the artifact rather
  than about the marketplace. The other half — agents, publishers, trust scores,
  and the `agent_manifests` listing join — stayed in FleetPrompt, because
  answering "which agent is serving this?" is a marketplace question and KILN
  has no idea what an agent is.

  Note what is missing compared to the code this came from: no trust
  computation, no ETS cache, no PubSub broadcast. Trust is a marketplace signal,
  the cache is keyed by agent, and the broadcast is to marketplace subscribers.
  A host that wants those does them around `publish/2`, which is why `publish/2`
  returns the manifest rather than swallowing it.
  """

  import Ecto.Query

  alias Kiln.AuditWriter
  alias Kiln.Manifests.Manifest

  @doc """
  Create a draft manifest.

  A draft needs no spec hash and no listing. It is the crystallizer's output
  before a human has looked at it.
  """
  @spec create_draft(map()) :: {:ok, Manifest.t()} | {:error, Ecto.Changeset.t()}
  def create_draft(attrs) do
    %Manifest{}
    |> Manifest.changeset(Map.put(attrs, :status, :draft))
    |> Kiln.repo().insert()
  end

  @doc """
  Publish a manifest.

  Requires `spec_hash` — a manifest that cannot say which spec it was built
  from is not provenance, it is an assertion. Pass `skip_spec_validation: true`
  only in tests.

  Requires `:workspace_id` for the same reason. The manifest row and its audit
  event are written in one transaction: if the audit cannot be written, the
  manifest is not published. This is the point of the engine, so it is not
  something to do on a best-effort basis.

  The version this was extracted from called the audit writer for its side
  effect and discarded the result. `audit_events.workspace_id` is NOT NULL, so
  every publish that did not happen to supply a workspace produced a manifest
  with no provenance record and reported success. Nothing failed, which is why
  nobody noticed.

  ## Options

    * `:workspace_id` — required; which workspace this publish happened in
    * `:actor_id` — who published, for the audit trail
    * `:skip_spec_validation` — bypass the spec_hash requirement, tests only
  """
  @spec publish(map(), keyword()) ::
          {:ok, Manifest.t()}
          | {:error, Ecto.Changeset.t() | :missing_spec_hash | :missing_workspace_id}
  def publish(attrs, opts \\ []) do
    with :ok <- validate_spec_hash(attrs, opts),
         {:ok, workspace_id} <- fetch_workspace_id(opts) do
      attrs = Map.put(attrs, :status, :published)

      Kiln.repo().transaction(fn ->
        with {:ok, manifest} <- %Manifest{} |> Manifest.changeset(attrs) |> Kiln.repo().insert(),
             {:ok, _event} <- AuditWriter.record_publish(manifest, opts[:actor_id], workspace_id) do
          manifest
        else
          {:error, reason} -> Kiln.repo().rollback(reason)
        end
      end)
    end
  end

  @spec get(binary()) :: Manifest.t() | nil
  def get(id), do: Kiln.repo().get(Manifest, id)

  @spec get!(binary()) :: Manifest.t()
  def get!(id), do: Kiln.repo().get!(Manifest, id)

  @doc "Get an exact `(slug, version)` — the manifest's full coordinate."
  @spec get_by_version(String.t(), String.t()) :: Manifest.t() | nil
  def get_by_version(slug, version),
    do: Kiln.repo().get_by(Manifest, slug: slug, version: version)

  @doc """
  The latest published manifest for a slug.

  "Latest" means most recently created, with `version` as a tie-break.

  The tie-break is not decoration. `created_at` is `utc_datetime` — second
  precision — so two manifests published in the same second sorted
  non-deterministically, and `get_latest/1` could return either. A
  crystallization run publishes in bursts, so same-second publishes are the
  normal case here rather than a corner. This was inherited from the code KILN
  was extracted from, where it was invisible because nothing published fast
  enough to collide.

  Two things this deliberately does *not* do:

    * It does not order by semver. `version` is compared as text, so 10.0.0
      sorts below 2.0.0. Within one second that is arbitrary-but-stable, which
      is all the tie-break is for; across seconds `created_at` decides and
      publish order wins. Real semver ordering is a behaviour change and wants
      to be chosen, not slipped in under a bug fix.
    * It does not consider drafts. Only `:published` is a candidate.
  """
  @spec get_latest(String.t()) :: Manifest.t() | nil
  def get_latest(slug) do
    Manifest
    |> where([m], m.slug == ^slug and m.status == :published)
    |> order_by([m], desc: m.created_at, desc: m.version)
    |> limit(1)
    |> Kiln.repo().one()
  end

  @doc "All versions of a slug, newest first."
  @spec list_versions(String.t(), keyword()) :: [Manifest.t()]
  def list_versions(slug, opts \\ []) do
    Manifest
    |> where([m], m.slug == ^slug)
    |> maybe_filter_status(opts[:status])
    |> order_by([m], desc: m.created_at)
    |> limit(^(opts[:limit] || 20))
    |> Kiln.repo().all()
  end

  @doc """
  Transition a manifest's status. Legal transitions are enforced by
  `Manifest.status_changeset/2`: draft → published → deprecated → yanked.
  """
  @spec transition_status(Manifest.t(), atom(), keyword()) ::
          {:ok, Manifest.t()} | {:error, Ecto.Changeset.t()}
  def transition_status(%Manifest{} = manifest, new_status, opts \\ []) do
    attrs = maybe_add_reason(%{status: new_status}, new_status, opts[:reason])

    manifest
    |> Manifest.status_changeset(attrs)
    |> Kiln.repo().update()
  end

  @spec deprecate(Manifest.t(), String.t()) ::
          {:ok, Manifest.t()} | {:error, Ecto.Changeset.t()}
  def deprecate(%Manifest{} = manifest, reason),
    do: transition_status(manifest, :deprecated, reason: reason)

  @spec yank(Manifest.t()) :: {:ok, Manifest.t()} | {:error, Ecto.Changeset.t()}
  def yank(%Manifest{} = manifest), do: transition_status(manifest, :yanked)

  # -- Private -----------------------------------------------------------------

  defp validate_spec_hash(attrs, opts) do
    if Keyword.get(opts, :skip_spec_validation, false) do
      :ok
    else
      case Map.get(attrs, :spec_hash) || Map.get(attrs, "spec_hash") do
        nil -> {:error, :missing_spec_hash}
        "" -> {:error, :missing_spec_hash}
        _ -> :ok
      end
    end
  end

  defp fetch_workspace_id(opts) do
    case Keyword.get(opts, :workspace_id) do
      nil -> {:error, :missing_workspace_id}
      "" -> {:error, :missing_workspace_id}
      id -> {:ok, id}
    end
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [m], m.status == ^status)

  defp maybe_add_reason(attrs, :deprecated, reason) when is_binary(reason),
    do: Map.put(attrs, :deprecated_reason, reason)

  defp maybe_add_reason(attrs, _, _), do: attrs
end
