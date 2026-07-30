defmodule Kiln.AuditWriter do
  @moduledoc """
  Writes audit events for manifest operations. Append-only — audit events are
  never updated or deleted.

  Every event needs a `workspace_id`: the column is NOT NULL and references
  `amp.workspaces`, so there is no such thing as an unowned audit event. Callers
  therefore have to say which workspace they are acting in; the engine cannot
  work it out, and the version of this module KILN was extracted from worked it
  out by loading a marketplace table.

  What is deliberately absent: install and trust-change events. Installs belong
  to the ship half, which is not in KILN yet, and trust is a marketplace signal.
  Both were here on arrival with no caller.
  """

  alias Kiln.Audit.Event

  @doc """
  Write an audit event.

  ## Examples

      AuditWriter.write(%{
        workspace_id: workspace_id,
        actor_user_id: user_id,
        action: "publish",
        target_type: "manifest",
        target_id: manifest_id,
        metadata: %{"version" => "2.1.0"}
      })
  """
  def write(attrs) do
    %Event{}
    |> Event.changeset(attrs)
    |> Kiln.repo().insert()
  end

  @doc """
  Write a publish audit event.

  `workspace_id` is passed in rather than looked up. It used to be derived by
  loading `fleet.agents` from `manifest.agent_id`, which made the audit writer —
  engine code — read a marketplace table to record an engine event. The caller
  knows which workspace it is publishing into; the engine does not.
  """
  def record_publish(manifest, actor_id, workspace_id) do
    write(%{
      workspace_id: workspace_id,
      actor_user_id: actor_id,
      action: "publish",
      target_type: "manifest",
      target_id: manifest.id,
      metadata: %{"version" => manifest.version, "slug" => manifest.slug}
    })
  end

  @doc "Write a fork audit event."
  def record_fork(forked_manifest, source_id, actor_id, workspace_id) do
    write(%{
      workspace_id: workspace_id,
      actor_user_id: actor_id,
      action: "fork",
      target_type: "manifest",
      target_id: forked_manifest.id,
      metadata: %{"forked_from" => source_id}
    })
  end
end
