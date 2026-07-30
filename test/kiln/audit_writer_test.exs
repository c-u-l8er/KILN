defmodule Kiln.AuditWriterTest do
  use ExUnit.Case, async: true

  alias Kiln.Audit.Event

  @valid_actions ~w(publish install fork deprecate yank trust_change uninstall)

  describe "audit event changeset" do
    test "accepts all valid action types" do
      for action <- @valid_actions do
        changeset =
          Event.changeset(%Event{}, %{
            workspace_id: Ecto.UUID.generate(),
            action: action,
            target_type: "manifest",
            target_id: Ecto.UUID.generate()
          })

        assert changeset.valid?, "Expected action '#{action}' to be valid"
      end
    end

    test "rejects invalid action types" do
      changeset =
        Event.changeset(%Event{}, %{
          workspace_id: Ecto.UUID.generate(),
          action: "invalid_action"
        })

      refute changeset.valid?
      assert %{action: _} = errors_on(changeset)
    end

    test "requires workspace_id and action" do
      changeset = Event.changeset(%Event{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert %{workspace_id: _, action: _} = errors
    end

    test "accepts optional metadata" do
      changeset =
        Event.changeset(%Event{}, %{
          workspace_id: Ecto.UUID.generate(),
          action: "publish",
          metadata: %{"version" => "1.0.0", "agent_id" => Ecto.UUID.generate()}
        })

      assert changeset.valid?
    end

    test "accepts optional actor_user_id" do
      changeset =
        Event.changeset(%Event{}, %{
          workspace_id: Ecto.UUID.generate(),
          actor_user_id: Ecto.UUID.generate(),
          action: "install"
        })

      assert changeset.valid?
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
