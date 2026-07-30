defmodule Kiln.Manifests.Manifest do
  @moduledoc """
  A manifest is the artifact the crystallize-and-ship engine emits. It is
  identified by `(slug, version)` and by nothing else.

  It used to carry `agent_id` and `publisher_id`, both required. That made the
  engine unable to write its own output without a marketplace publisher row
  already existing — the engine depended on the marketplace in order to produce
  the thing the marketplace exists to list. The dependency ran backwards.

  Ownership now lives in `fleet.agent_manifests`, a join the marketplace writes
  when it decides to list a manifest. A manifest can exist with no agent
  pointing at it; that is a manifest that has been built but not listed, which
  is a real state the old schema could not represent.

  Consequence to know about: `slug` is now a registry-wide coordinate, not a
  per-agent label. Two agents cannot publish the same slug. That is the correct
  behaviour for a package registry and a behaviour change for a marketplace.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  # Defaults to "fleet" — where these tables live today, next to the marketplace
  # that used to own them. KILN's own home is `kiln.*`. See `Kiln` for why the
  # default is the current truth rather than the intended one. `compile_env`
  # because Ecto resolves @schema_prefix at compile time.
  @schema_prefix Application.compile_env(:kiln, :schema_prefix, "fleet")

  schema "manifests" do
    # Identity
    field :name, :string
    field :slug, :string
    field :version, :string
    field :description, :string
    field :category, :string
    field :tags, {:array, :string}, default: []

    # Spec linkage
    field :spec_url, :string
    field :spec_hash, :string

    # Permissions (declared upfront)
    # Each: %{capability: "orders:read", scope: "read", reason: "..."}
    field :permissions, {:array, :map}, default: []

    # MCP dependencies
    # Each: %{name: "graphonomous", url: "...", required: true}
    field :mcp_servers, {:array, :map}, default: []

    # Runtime requirements
    field :runtime, :string, default: "opensentience"
    field :min_runtime_version, :string

    # Build provenance
    field :build_pipeline, :string
    field :build_hash, :string
    field :test_results, :map, default: %{}

    # Trust (computed, not declared)
    field :trust_score, :integer

    # Lifecycle
    field :status, Ecto.Enum,
      values: [:draft, :published, :deprecated, :yanked],
      default: :draft

    field :deprecated_reason, :string
    field :forked_from, :binary_id

    timestamps(inserted_at: :created_at, type: :utc_datetime)
  end

  @required_fields [:name, :slug, :version, :description, :permissions]
  @optional_fields [
    :category,
    :tags,
    :spec_url,
    :spec_hash,
    :mcp_servers,
    :runtime,
    :min_runtime_version,
    :build_pipeline,
    :build_hash,
    :test_results,
    :status,
    :deprecated_reason,
    :forked_from
  ]

  def changeset(manifest, attrs) do
    manifest
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:version, ~r/^\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?$/)
    |> validate_format(:slug, ~r/^[a-z0-9\-]+$/)
    |> validate_inclusion(:build_pipeline, ~w(agentelic manual ci))
    |> validate_number(:trust_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    # DB-level constraint is named `manifests_slug_version_key` (Postgres's
    # default for UNIQUE). The name is asserted here because the previous
    # declaration named an index that did not exist — `unique_constraint` only
    # converts the errors it is told the name of, so duplicate-version publishes
    # raised instead of returning `{:error, changeset}`, and nothing failed
    # until a duplicate was actually attempted.
    |> unique_constraint([:slug, :version],
      name: "manifests_slug_version_key"
    )
  end

  @doc """
  Changeset for status transitions only. Enforces valid transitions:
  - draft → published
  - published → deprecated | yanked
  - deprecated → yanked
  """
  def status_changeset(manifest, attrs) do
    manifest
    |> cast(attrs, [:status, :deprecated_reason])
    |> validate_required([:status])
    |> validate_status_transition(manifest.status)
  end

  defp validate_status_transition(changeset, current_status) do
    case get_change(changeset, :status) do
      nil ->
        changeset

      new_status ->
        if valid_transition?(current_status, new_status) do
          changeset
        else
          add_error(
            changeset,
            :status,
            "invalid transition from #{current_status} to #{new_status}"
          )
        end
    end
  end

  defp valid_transition?(:draft, :published), do: true
  defp valid_transition?(:published, :deprecated), do: true
  defp valid_transition?(:published, :yanked), do: true
  defp valid_transition?(:deprecated, :yanked), do: true
  defp valid_transition?(_, _), do: false
end
