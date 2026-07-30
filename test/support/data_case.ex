defmodule Kiln.DataCase do
  @moduledoc """
  Test case for anything that touches Postgres.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto
      import Ecto.Query
      import Kiln.DataCase
    end
  end

  @doc """
  Insert a real `amp.workspaces` row and return its id.

  KILN ships no workspace schema — a workspace belongs to the host, in the
  shared `amp.*` substrate. But `audit_events.workspace_id` is NOT NULL and
  references it, so a test that wants to prove a publish was audited has to make
  one exist rather than invent a UUID. The sandbox rolls it back.
  """
  def workspace_fixture(name \\ "kiln test workspace") do
    slug = "kiln-test-ws-#{System.unique_integer([:positive])}"

    %Postgrex.Result{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Kiln.TestRepo,
        "insert into amp.workspaces (name, slug) values ($1, $2) returning id",
        [name, slug]
      )

    Ecto.UUID.cast!(id)
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Kiln.TestRepo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
