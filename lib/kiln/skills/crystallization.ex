defmodule Kiln.Skills.Crystallization do
  @moduledoc """
  Audit record for a single skill crystallization — the conversion of a
  Graphonomous procedural artifact into a Kiln draft manifest.

  One row exists per upstream artifact (trace, cluster, or composition
  candidate). The `(source_type, source_id)` unique constraint is what
  makes the poll worker idempotent.
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

  @source_types ~w(interaction_trace procedural_cluster composition_candidate)a
  @statuses ~w(pending_review approved rejected superseded)a

  schema "skill_crystallizations" do
    belongs_to :manifest, Kiln.Manifests.Manifest

    field :source_type, Ecto.Enum, values: @source_types
    field :source_id, :string
    field :source_provider, :string, default: "graphonomous"
    field :source_endpoint, :string

    field :initial_state_hash, :string
    field :body_subtype, :string
    field :edge_count, :integer, default: 0
    field :success_rate, :decimal
    field :contributing_trace_ids, {:array, :string}, default: []

    field :summary, :string
    field :generated_slug, :string
    field :derived_permissions, {:array, :map}, default: []
    field :derived_postconditions, {:array, :string}, default: []

    field :status, Ecto.Enum, values: @statuses, default: :pending_review
    field :rejection_reason, :string
    field :reviewed_at, :utc_datetime
    field :reviewer_user_id, :binary_id

    field :crystallized_at, :utc_datetime
    field :crystallized_by_worker, :string

    field :metadata, :map, default: %{}
  end

  @required ~w(source_type source_id source_provider edge_count generated_slug)a
  @optional ~w(
    manifest_id source_endpoint initial_state_hash body_subtype success_rate
    contributing_trace_ids summary derived_permissions derived_postconditions
    status rejection_reason reviewed_at reviewer_user_id
    crystallized_at crystallized_by_worker metadata
  )a

  @doc "Valid changeset for a brand-new crystallization."
  def changeset(record, attrs) do
    record
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:edge_count, greater_than_or_equal_to: 0)
    |> validate_format(:generated_slug, ~r/^[a-z0-9\-]+$/)
    |> validate_length(:summary, max: 500)
    |> unique_constraint([:source_type, :source_id],
      name: :crystallizations_source_unique
    )
  end

  @doc "Valid list of source types (see migration 034)."
  def source_types, do: @source_types

  @doc "Valid list of crystallization statuses."
  def statuses, do: @statuses
end
