defmodule Kiln.Skills.PollWorkerTest do
  @moduledoc """
  The crystallize half of the dark factory, end to end, against a real
  database: a Graphonomous trace goes in, a draft manifest row and a
  crystallization audit row come out.

  `crystallizer_test.exs` proves the transform is correct. It cannot
  prove the loop runs, because it never writes anything. These tests do,
  and there is no agent, publisher, or marketplace row anywhere in them.
  """
  use Kiln.DataCase, async: true

  alias Kiln.Manifests.Manifest
  alias Kiln.Skills.Crystallization
  alias Kiln.Skills.PollWorker

  defp trace(id) do
    %{
      "trace_id" => id,
      "body_subtype" => "browser",
      "goal" => "File the quarterly report",
      "outcome" => "success",
      "edges" => [
        %{
          "edge_id" => 0,
          "state_before" => "sha256:start",
          "state_after" => "sha256:filed",
          "typed_action" => %{"type" => "navigate", "target" => "https://reports.test"},
          "outcome_status" => "success"
        }
      ]
    }
  end

  defp unique_trace, do: trace("trace-#{System.unique_integer([:positive])}")

  describe "crystallize_one/2" do
    test "writes a draft manifest and its audit row with no owner configured" do
      # No :skills_default_agent_id, no publisher, no marketplace. The
      # worker used to refuse to start without them.
      assert {:ok, %Manifest{} = m} = PollWorker.crystallize_one(unique_trace(), [])

      assert m.status == :draft
      assert m.slug =~ ~r/^file-the-quarterly-report-[0-9a-f]{8}$/

      # A row, not a struct we built in memory.
      assert %Manifest{} = Kiln.Manifests.get(m.id)

      cr = Kiln.repo().get_by!(Crystallization, manifest_id: m.id)
      assert cr.source_type == :interaction_trace
      assert cr.status == :pending_review
      assert cr.edge_count == 1
    end

    test "the same trace twice is skipped, not duplicated" do
      t = unique_trace()
      assert {:ok, _} = PollWorker.crystallize_one(t, [])
      assert {:skipped, :already_crystallized} = PollWorker.crystallize_one(t, [])
    end

    test "an unsuccessful trace is refused before anything is written" do
      t = Map.put(unique_trace(), "outcome", "failure")
      assert {:error, {:invalid_trace, _}} = PollWorker.crystallize_one(t, [])
    end
  end

  describe "crystallize_all/2" do
    test "tallies a mixed batch" do
      good = unique_trace()
      already = unique_trace()
      {:ok, _} = PollWorker.crystallize_one(already, [])
      bad = Map.put(unique_trace(), "edges", [])

      assert {:ok, tally} = PollWorker.crystallize_all([good, already, bad], %{})
      assert tally == %{crystallized: 1, skipped: 1, failed: 1}
    end

    test "an empty poll is a no-op, not an error" do
      assert {:ok, %{crystallized: 0, skipped: 0, failed: 0}} =
               PollWorker.crystallize_all([], %{})
    end
  end
end
