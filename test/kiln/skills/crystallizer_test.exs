defmodule Kiln.Skills.CrystallizerTest do
  @moduledoc """
  Unit tests for `Kiln.Skills.Crystallizer`. Pure function
  tests — no DB, no network, no supervised processes — so they run
  in the lean test lane (`mix test test/kiln/skills/`).
  """

  use ExUnit.Case, async: true

  alias Kiln.Skills.Crystallizer

  # -- fixtures -----------------------------------------------------

  defp successful_browser_trace(opts \\ []) do
    %{
      "trace_id" => Keyword.get(opts, :trace_id, "trace_abc123"),
      "body_subtype" => "browser",
      "provider" => "agent-browser",
      "agent_id" => "test-agent",
      "started_at" => "2026-04-21T14:00:00Z",
      "ended_at" => "2026-04-21T14:00:45Z",
      "goal" => Keyword.get(opts, :goal, "Submit weekly expense report"),
      "outcome" => "success",
      "metadata" => %{},
      "edges" => [
        %{
          "edge_id" => 0,
          "state_before" => "sha256:start",
          "state_after" => "sha256:logged_in",
          "typed_action" => %{
            "type" => "navigate",
            "target" => "https://expenses.test/login"
          },
          "latency_ms" => 120,
          "outcome_status" => "success",
          "provenance" => %{"capability" => "&body.browser", "operation" => "act"}
        },
        %{
          "edge_id" => 1,
          "state_before" => "sha256:logged_in",
          "state_after" => "sha256:submitted",
          "typed_action" => %{
            "type" => "click",
            "target" => "@e5/g2",
            "semantic_locator" => %{"role" => "button", "name" => "Submit"}
          },
          "latency_ms" => 243,
          "outcome_status" => "success",
          "provenance" => %{"capability" => "&body.browser", "operation" => "act"}
        }
      ]
    }
  end

  # Deliberately no owner. If crystallizing ever needs one again, every
  # test in this file stops compiling rather than quietly acquiring a
  # dependency on the marketplace KILN was extracted out of.
  defp opts, do: [source_endpoint: "http://localhost:4100/mcp"]

  # -- from_trace/2 -------------------------------------------------

  describe "from_trace/2" do
    test "returns manifest + crystallization attrs for a successful trace" do
      trace = successful_browser_trace()

      assert {:ok, %{manifest: mf, crystallization: cr}} =
               Crystallizer.from_trace(trace, opts())

      # Manifest
      assert mf.version == "0.1.0"
      assert mf.runtime == "opensentience"
      assert mf.status == :draft
      assert mf.name =~ "Submit weekly expense report"
      assert mf.slug =~ ~r/^submit-weekly-expense-report-[0-9a-f]{8}$/
      assert mf.build_pipeline == "ci"
      assert mf.category == "crystallized-skill"
      assert "crystallized" in mf.tags
      assert "&body.browser" in mf.tags
      assert "os-011" in mf.tags

      assert is_list(mf.mcp_servers)
      assert Enum.any?(mf.mcp_servers, &(&1.name == "graphonomous"))

      # The attrs name no owner. Not nil — absent.
      refute Map.has_key?(mf, :agent_id)
      refute Map.has_key?(mf, :publisher_id)

      assert mf.test_results["trace_id"] == "trace_abc123"
      assert mf.test_results["edges_replayed"] == 2
      assert mf.test_results["outcome"] == "success"

      # Crystallization
      assert cr.source_type == :interaction_trace
      assert cr.source_id == "trace_abc123"
      assert cr.body_subtype == "browser"
      assert cr.edge_count == 2
      assert cr.initial_state_hash == "sha256:start"
      assert cr.contributing_trace_ids == ["trace_abc123"]
      assert cr.status == :pending_review
      assert cr.generated_slug == mf.slug
      assert cr.derived_postconditions == ["reaches:sha256:submitted"]
      assert is_binary(cr.summary)
    end

    test "rejects traces whose outcome is not success" do
      trace = successful_browser_trace() |> Map.put("outcome", "failure")

      assert {:error, {:invalid_trace, reason}} = Crystallizer.from_trace(trace, opts())
      assert reason =~ "outcome=failure"
    end

    test "rejects traces without an edges list" do
      trace = successful_browser_trace() |> Map.delete("edges")

      assert {:error, {:invalid_trace, reason}} = Crystallizer.from_trace(trace, opts())
      assert reason =~ "edges"
    end

    test "rejects traces with an empty edges list" do
      trace = successful_browser_trace() |> Map.put("edges", [])

      assert {:error, {:invalid_trace, reason}} = Crystallizer.from_trace(trace, opts())
      assert reason =~ "non-empty"
    end

    test "rejects traces without a trace_id" do
      trace = successful_browser_trace() |> Map.delete("trace_id")

      assert {:error, {:invalid_trace, reason}} = Crystallizer.from_trace(trace, opts())
      assert reason =~ "trace_id"
    end

    test "rejects traces without a body_subtype" do
      trace = successful_browser_trace() |> Map.delete("body_subtype")

      assert {:error, {:invalid_trace, reason}} = Crystallizer.from_trace(trace, opts())
      assert reason =~ "body_subtype"
    end

    test "fallbacks to a trace-id-based slug when goal is missing" do
      trace = successful_browser_trace() |> Map.delete("goal")

      assert {:ok, %{manifest: mf}} = Crystallizer.from_trace(trace, opts())
      assert mf.slug =~ ~r/^trace-[0-9a-f]{8}$/
    end

    test "slug is deterministic for the same trace_id and goal" do
      trace = successful_browser_trace(trace_id: "trace_fixed", goal: "Click the button")

      {:ok, %{manifest: mf1}} = Crystallizer.from_trace(trace, opts())
      {:ok, %{manifest: mf2}} = Crystallizer.from_trace(trace, opts())

      assert mf1.slug == mf2.slug
    end

    test "description mentions subtype, edge count, and the goal" do
      trace = successful_browser_trace(goal: "Approve invoice")

      {:ok, %{manifest: mf}} = Crystallizer.from_trace(trace, opts())

      assert mf.description =~ "Approve invoice"
      assert mf.description =~ "&body.browser"
      assert mf.description =~ "2 recorded edges"
      assert mf.description =~ "fresh authorization"
    end
  end

  # -- derive_permissions/2 -----------------------------------------

  describe "derive_permissions/2" do
    test "always includes the base &body.SUBTYPE:act permission" do
      perms = Crystallizer.derive_permissions("browser", ["click"])

      assert [%{capability: "&body.browser", scope: "act"} | _] = perms
    end

    test "navigate adds network:outbound http" do
      perms = Crystallizer.derive_permissions("browser", ["navigate"])
      assert Enum.any?(perms, &(&1.capability == "network:outbound"))
    end

    test "upload adds fs:read user-selected" do
      perms = Crystallizer.derive_permissions("browser", ["upload"])
      assert Enum.any?(perms, &(&1.capability == "fs:read"))
    end

    test "body.os destructive actions add appropriate sandboxed permissions" do
      perms = Crystallizer.derive_permissions("os", ["shell_exec", "file_write", "file_delete"])

      capabilities = Enum.map(perms, & &1.capability)

      for c <- ["os:exec", "fs:write", "fs:delete"] do
        assert c in capabilities, "expected capability #{c} in #{inspect(capabilities)}"
      end
    end

    test "dedupes by {capability, scope}" do
      perms =
        Crystallizer.derive_permissions("browser", [
          "navigate",
          "navigate",
          "click",
          "click"
        ])

      # base + one network:outbound entry — no dupes
      assert length(perms) == 2
    end
  end

  # -- generate_slug/2 ----------------------------------------------

  describe "generate_slug/2" do
    test "lowercases, strips punctuation, replaces whitespace with hyphens" do
      assert Crystallizer.generate_slug("Submit Expense Report!", "trace_xyz") =~
               ~r/^submit-expense-report-[0-9a-f]{8}$/
    end

    test "clamps long goals to 60 chars" do
      goal = String.duplicate("abc ", 60) |> String.trim()
      slug = Crystallizer.generate_slug(goal, "trace_xyz")

      [base, _suffix] =
        (String.split(slug, ~r/-[0-9a-f]{8}$/, include_captures: true, trim: true) ++ [nil, nil])
        |> Enum.take(2)

      assert String.length(base) <= 60
    end

    test "empty goal falls back to trace-<suffix>" do
      assert Crystallizer.generate_slug("", "trace_zzz") =~ ~r/^trace-[0-9a-f]{8}$/
    end

    test "nil goal falls back to trace-<suffix>" do
      assert Crystallizer.generate_slug(nil, "trace_zzz") =~ ~r/^trace-[0-9a-f]{8}$/
    end

    test "different trace_ids produce different suffixes" do
      s1 = Crystallizer.generate_slug("Same goal", "trace_A")
      s2 = Crystallizer.generate_slug("Same goal", "trace_B")

      refute s1 == s2
    end
  end

  # -- from_cluster/2 -----------------------------------------------

  describe "from_cluster/2" do
    test "crystallizes a cluster of 3 successful traces into one draft" do
      traces =
        for i <- 1..3 do
          successful_browser_trace(trace_id: "trace_cluster_#{i}")
        end

      cluster = %{
        initial_state_hash: "sha256:start",
        traces: traces
      }

      assert {:ok, %{manifest: mf, crystallization: cr}} =
               Crystallizer.from_cluster(cluster, opts())

      assert cr.source_type == :procedural_cluster
      assert cr.source_id =~ ~r/^sha256:start\|[0-9a-f]{12}$/
      assert cr.initial_state_hash == "sha256:start"
      assert length(cr.contributing_trace_ids) == 3
      assert cr.success_rate == Decimal.from_float(1.000)

      # Manifest gains a cluster tag + augmented description
      assert "crystallized-from-cluster" in mf.tags
      assert mf.description =~ "cluster of 3 successful traces"
    end

    test "computes fractional success_rate for mixed outcomes" do
      successes =
        for i <- 1..3 do
          successful_browser_trace(trace_id: "trace_ok_#{i}")
        end

      failures =
        for i <- 1..2 do
          successful_browser_trace(trace_id: "trace_fail_#{i}")
          |> Map.put("outcome", "failure")
        end

      # Use a success as the canonical (from_cluster requires one crystallizable trace).
      cluster = %{
        initial_state_hash: "sha256:start",
        traces: successes ++ failures
      }

      assert {:ok, %{crystallization: cr}} = Crystallizer.from_cluster(cluster, opts())

      # 3 out of 5 → 0.600
      assert Decimal.equal?(cr.success_rate, Decimal.from_float(0.600))
    end

    test "rejects an empty cluster" do
      cluster = %{initial_state_hash: "sha256:x", traces: []}
      assert {:error, {:invalid_cluster, _}} = Crystallizer.from_cluster(cluster, opts())
    end

    test "source_id is deterministic for the same contributing trace set" do
      traces =
        for i <- 1..2 do
          successful_browser_trace(trace_id: "trace_det_#{i}")
        end

      cluster = %{initial_state_hash: "sha256:x", traces: traces}

      {:ok, %{crystallization: a}} = Crystallizer.from_cluster(cluster, opts())
      {:ok, %{crystallization: b}} = Crystallizer.from_cluster(cluster, opts())

      assert a.source_id == b.source_id
    end
  end
end
