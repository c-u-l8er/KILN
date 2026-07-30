defmodule Kiln.ManifestsTest do
  @moduledoc """
  The load-bearing test for the extraction.

  Everything else in this repo could pass while KILN was still unable to do the
  one thing it was extracted to do: produce a manifest by itself, against a real
  database, with no marketplace present. These tests write real rows.
  """
  use Kiln.DataCase, async: true

  import Ecto.Query

  alias Kiln.Audit.Event
  alias Kiln.Manifests
  alias Kiln.Manifests.Manifest

  setup do
    {:ok, workspace_id: workspace_fixture()}
  end

  # Every publish needs a workspace, because every publish writes an audit
  # event and an audit event without a workspace cannot be written at all.
  defp publish(attrs, ctx, opts \\ []),
    do: Manifests.publish(attrs, Keyword.put(opts, :workspace_id, ctx.workspace_id))

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "kiln test",
        slug: "kiln-test-#{System.unique_integer([:positive])}",
        version: "1.0.0",
        description: "a manifest KILN made on its own",
        permissions: [%{"capability" => "read", "scope" => "read", "reason" => "testing"}],
        spec_hash: "sha256:abc123",
        build_pipeline: "agentelic"
      },
      overrides
    )
  end

  describe "the extraction claim" do
    test "creates a draft with no agent and no publisher anywhere in sight" do
      assert {:ok, %Manifest{} = m} = Manifests.create_draft(attrs())
      assert m.status == :draft
      # Reading it back proves it is a row, not a struct we built in memory.
      assert %Manifest{} = Manifests.get(m.id)
    end

    test "publishes with no agent and no publisher", ctx do
      a = attrs()
      assert {:ok, %Manifest{status: :published} = m} = publish(a, ctx)
      assert m.slug == a.slug
    end

    test "the manifest struct has no agent_id or publisher_id field at all" do
      # Not "is nil" — absent. If either ever comes back as a field, the
      # backwards dependency has been reintroduced and this fails loudly.
      fields = Manifest.__schema__(:fields)
      refute :agent_id in fields
      refute :publisher_id in fields
    end
  end

  describe "spec provenance" do
    test "refuses to publish without a spec_hash", ctx do
      assert {:error, :missing_spec_hash} = publish(Map.delete(attrs(), :spec_hash), ctx)
    end

    test "refuses an empty spec_hash", ctx do
      assert {:error, :missing_spec_hash} = publish(attrs(%{spec_hash: ""}), ctx)
    end

    test "skip_spec_validation is honoured, for tests only", ctx do
      assert {:ok, _} =
               publish(Map.delete(attrs(), :spec_hash), ctx, skip_spec_validation: true)
    end
  end

  describe "audit provenance" do
    test "a publish writes its audit event, in the same transaction", ctx do
      assert {:ok, m} = publish(attrs(), ctx)

      assert [event] =
               Kiln.repo().all(from e in Event, where: e.target_id == ^m.id)

      assert event.action == "publish"
      assert event.target_type == "manifest"
      assert event.workspace_id == ctx.workspace_id
      assert event.metadata["slug"] == m.slug
      assert event.metadata["version"] == "1.0.0"
    end

    test "refuses to publish with no workspace" do
      # Not a nicety. `audit_events.workspace_id` is NOT NULL, so a publish
      # without one cannot record how the manifest came to exist — and the
      # code this was extracted from returned {:ok, manifest} anyway.
      assert {:error, :missing_workspace_id} = Manifests.publish(attrs())
    end

    test "an unknown workspace fails the publish instead of writing an orphan" do
      ghost = Ecto.UUID.generate()

      assert {:error, %Ecto.Changeset{} = cs} =
               Manifests.publish(attrs(), workspace_id: ghost)

      assert [{:workspace_id, {_, opts}}] = cs.errors
      assert opts[:constraint] == :foreign
    end

    test "the manifest is rolled back when the audit cannot be written" do
      a = attrs()
      assert {:error, _} = Manifests.publish(a, workspace_id: Ecto.UUID.generate())

      # No half-published manifest left behind.
      assert Manifests.get_by_version(a.slug, a.version) == nil
    end
  end

  describe "version immutability" do
    test "refuses a duplicate (slug, version) as an error, not a raise", ctx do
      a = attrs()
      assert {:ok, _} = publish(a, ctx)

      # The distinction matters: an unnamed DB constraint surfaces as a raised
      # Postgrex error instead of a changeset, which callers cannot pattern
      # match on. This is the bug the FleetPrompt version carried for a while.
      assert {:error, %Ecto.Changeset{} = cs} = publish(a, ctx)
      assert [{:slug, {_, opts}}] = cs.errors
      assert opts[:constraint] == :unique
    end

    test "the same slug at a different version is fine", ctx do
      a = attrs()
      assert {:ok, _} = publish(a, ctx)
      assert {:ok, _} = publish(%{a | version: "1.0.1"}, ctx)
    end
  end

  describe "lookup by the manifest's own coordinate" do
    test "get_by_version and get_latest key on slug, not on any agent", ctx do
      a = attrs()
      {:ok, _} = publish(a, ctx)
      {:ok, newer} = publish(%{a | version: "2.0.0"}, ctx)

      assert %Manifest{version: "1.0.0"} = Manifests.get_by_version(a.slug, "1.0.0")
      assert %Manifest{id: id} = Manifests.get_latest(a.slug)
      assert id == newer.id
      assert length(Manifests.list_versions(a.slug)) == 2
    end

    test "get_latest is deterministic for same-second publishes", ctx do
      # created_at is second-precision, so these two collide. Before the version
      # tie-break, get_latest/1 returned either one — and a crystallization run
      # publishes fast enough that this is the normal case, not a corner.
      a = attrs()
      {:ok, _} = publish(a, ctx)
      {:ok, _} = publish(%{a | version: "2.0.0"}, ctx)

      results = for _ <- 1..20, do: Manifests.get_latest(a.slug).version
      assert Enum.uniq(results) == ["2.0.0"]
    end

    test "a draft is not the latest published" do
      a = attrs()
      {:ok, _} = Manifests.create_draft(a)
      assert Manifests.get_latest(a.slug) == nil
    end
  end

  describe "status lifecycle" do
    test "published -> deprecated -> yanked, and no illegal jumps", ctx do
      {:ok, m} = publish(attrs(), ctx)

      assert {:ok, dep} = Manifests.deprecate(m, "superseded")
      assert dep.status == :deprecated
      assert dep.deprecated_reason == "superseded"

      assert {:ok, yanked} = Manifests.yank(dep)
      assert yanked.status == :yanked

      # yanked is terminal
      assert {:error, %Ecto.Changeset{}} = Manifests.transition_status(yanked, :published)
    end
  end
end
