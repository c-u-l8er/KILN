defmodule Kiln.PipelineIntakeTest do
  use Kiln.DataCase, async: true

  alias Kiln.Manifests.Manifest
  alias Kiln.PipelineIntake

  setup do
    {:ok, workspace_id: workspace_fixture()}
  end

  defp event(overrides \\ %{}) do
    %{
      "type" => "com.agentelic.consolidation.v1",
      "data" =>
        Map.merge(
          %{
            "name" => "quarterly report filer",
            "slug" => "intake-#{System.unique_integer([:positive])}",
            "version" => "1.0.0",
            "description" => "built by the pipeline, listed by nobody",
            "permissions" => [
              %{"capability" => "read", "scope" => "read", "reason" => "testing"}
            ],
            "spec_hash" => "sha256:deadbeef"
          },
          overrides
        )
    }
  end

  describe "process/1 — the happy path" do
    test "an Agentelic consolidation event becomes a published manifest row", ctx do
      e = event(%{"workspace_id" => ctx.workspace_id})

      assert {:ok, %Manifest{status: :published} = m} = PipelineIntake.process(e)
      assert m.slug == e["data"]["slug"]
      assert m.build_pipeline == "agentelic"

      # A row, not a struct built in memory — and one written with no
      # agent and no publisher, which is the whole extraction claim.
      assert %Manifest{} = Kiln.Manifests.get(m.id)
    end

    test "republishing the same (slug, version) is a changeset error, not a raise", ctx do
      e = event(%{"workspace_id" => ctx.workspace_id})
      assert {:ok, _} = PipelineIntake.process(e)
      assert {:error, {:publish_failed, %Ecto.Changeset{}}} = PipelineIntake.process(e)
    end

    test "an event that names no workspace is refused, not published unaudited" do
      assert {:error, {:publish_failed, :missing_workspace_id}} =
               PipelineIntake.process(event())
    end
  end

  describe "process/1" do
    test "rejects events without type" do
      assert {:error, :missing_event_type} = PipelineIntake.process(%{})
    end

    test "rejects unsupported event types" do
      assert {:error, {:unsupported_event_type, "com.example.unknown"}} =
               PipelineIntake.process(%{"type" => "com.example.unknown"})
    end

    test "rejects events without data" do
      assert {:error, :missing_event_data} =
               PipelineIntake.process(%{"type" => "com.agentelic.consolidation.v1"})
    end

    test "rejects events without spec_hash" do
      assert {:error, :missing_spec_hash} =
               PipelineIntake.process(%{
                 "type" => "com.agentelic.consolidation.v1",
                 "data" => %{"name" => "test"}
               })
    end

    test "rejects events with nil spec_hash" do
      assert {:error, :spec_not_registered} =
               PipelineIntake.process(%{
                 "type" => "com.agentelic.consolidation.v1",
                 "data" => %{"spec_hash" => nil}
               })
    end
  end
end
