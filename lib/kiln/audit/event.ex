defmodule Kiln.Audit.Event do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  # Defaults to "fleet" — where these tables live today, next to the marketplace
  # that used to own them. KILN's own home is `kiln.*`. See `Kiln` for why the
  # default is the current truth rather than the intended one. `compile_env`
  # because Ecto resolves @schema_prefix at compile time.
  @schema_prefix Application.compile_env(:kiln, :schema_prefix, "fleet")

  schema "audit_events" do
    field :workspace_id, :binary_id
    field :actor_user_id, :binary_id
    field :action, :string
    field :target_type, :string
    field :target_id, :binary_id
    field :metadata, :map

    # Append-only — no updated_at
    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime)
  end

  @valid_actions ~w(publish install fork deprecate yank trust_change uninstall)

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:workspace_id, :actor_user_id, :action, :target_type, :target_id, :metadata])
    |> validate_required([:workspace_id, :action])
    |> validate_inclusion(:action, @valid_actions)
    # `workspace_id` is NOT NULL and references `amp.workspaces` — the shared
    # substrate, not the marketplace. Naming the constraint is what turns an
    # unknown workspace into `{:error, changeset}` a caller can match instead of
    # a raised Postgrex error it cannot.
    |> foreign_key_constraint(:workspace_id, name: "audit_events_workspace_id_fkey")
    |> foreign_key_constraint(:actor_user_id, name: "audit_events_actor_user_id_fkey")
  end
end
