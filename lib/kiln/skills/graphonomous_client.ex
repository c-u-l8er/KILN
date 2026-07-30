defmodule Kiln.Skills.GraphonomousClient do
  @moduledoc """
  Behaviour for fetching successful `InteractionTrace` records from a
  Graphonomous MCP server.

  The default implementation (`Kiln.Skills.GraphonomousClient.HTTP`)
  makes MCP JSON-RPC calls against the configured endpoint via the
  Erlang stdlib `:httpc` client:

      Kiln.Skills.GraphonomousClient.HTTP.fetch_successful_traces(
        endpoint: "https://graphonomous-mcp.fly.dev/mcp",
        state_hash: "sha256:...",
        limit: 10
      )

  Tests use `Kiln.Skills.GraphonomousClient.Stub` or the HTTP
  impl with an injected transport (see
  `Kiln.Skills.GraphonomousClient.HTTP.fetch_successful_traces/1`,
  `:transport` option). Override via application config:

      config :kiln, :graphonomous_client,
        Kiln.Skills.GraphonomousClient.Stub

  No LLM calls happen here. This is a pure data-layer transport.
  """

  @type trace :: map()
  @type opts :: keyword()
  @type telespace_ref :: %{required(String.t()) => term()}

  @callback fetch_successful_traces(opts()) :: {:ok, [trace()]} | {:error, term()}
  @callback initialize_telespace(opts()) :: {:ok, telespace_ref()} | {:error, term()}

  @doc "Resolve the configured client module (defaults to the HTTP impl)."
  @spec impl() :: module()
  def impl do
    Application.get_env(
      :kiln,
      :graphonomous_client,
      Kiln.Skills.GraphonomousClient.HTTP
    )
  end
end

defmodule Kiln.Skills.GraphonomousClient.HTTP do
  @moduledoc """
  Default HTTP implementation — issues MCP JSON-RPC `tools/call`
  requests against a Graphonomous server using `:httpc` from the
  standard library so no new runtime dependency is required.

  The response-parsing path and the transport path are separable:

    * `fetch_successful_traces/1` is the top-level entry point.
    * `parse_response/1` turns a raw JSON-RPC response body into a
      `{:ok, [trace()]}` / `{:error, term()}` — unit-testable with
      only a fixture string.
    * The transport (`:httpc.request`) is injectable via the
      `:transport` option so tests can substitute a fake.

  Each trace is returned in the shape the `Kiln.Skills.Crystallizer`
  expects: `replay_manifest.edges` is hoisted to the top-level
  `"edges"` key so the Crystallizer's existing parser accepts the map
  unchanged.
  """

  @behaviour Kiln.Skills.GraphonomousClient

  require Logger

  @default_timeout_ms 15_000

  @impl true
  def fetch_successful_traces(opts) do
    endpoint = Keyword.get(opts, :endpoint) || default_endpoint()
    state_hash = Keyword.get(opts, :state_hash)
    trace_id = Keyword.get(opts, :trace_id)
    limit = Keyword.get(opts, :limit, 5)
    body_subtype = Keyword.get(opts, :body_subtype)
    transport = Keyword.get(opts, :transport, &default_transport/3)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    body = build_payload(state_hash, trace_id, limit, body_subtype)

    case transport.(endpoint, body, timeout) do
      {:ok, response_body} -> parse_response(response_body)
      {:error, reason} -> {:error, {:transport_failed, reason}}
    end
  end

  @doc """
  Initialize a memory telespace for a newly-installed agent by
  storing a `semantic` node in the target Graphonomous instance. This
  is the "Graphonomous connect" step of `Kiln.InstallEngine`
  (install-flow step 6).

  Required opts:
    * `:agent_id` — the installed agent's id
    * `:workspace_id` — workspace id for scoping

  Optional opts:
    * `:endpoint` — Graphonomous MCP URL (defaults to configured endpoint)
    * `:version_id` — agent version id; embedded in metadata
    * `:installed_by` — user id; embedded in metadata
    * `:transport` — `(url, body, timeout_ms -> {:ok, bin} | {:error, t})`; for tests
    * `:timeout_ms`

  Returns `{:ok, %{"node_id" => ..., "endpoint" => ...}}` on success,
  or `{:error, reason}` where `reason` is one of:

    * `{:transport_failed, _}` — network/HTTP failure
    * `{:jsonrpc_error, code, msg}` — MCP-level protocol error
    * `{:tool_error, error, reason}` — Graphonomous returned
      `structuredContent.status == "error"`
    * `{:malformed_response, _}` — non-JSON response body
    * `{:unexpected_response_shape, _}` — JSON but not in expected shape
    * `{:missing_required, field}` — missing :agent_id or :workspace_id

  Callers should treat errors as non-fatal for the install flow: the
  install completes, but the `graphonomous-connect` audit step will
  be logged with a warning rather than blocking the user. This matches
  the graceful-degradation contract declared in
  `Kiln.InstallEngine`'s module doc.
  """
  @impl true
  @spec initialize_telespace(keyword()) :: {:ok, map()} | {:error, term()}
  def initialize_telespace(opts) do
    with {:ok, agent_id} <- fetch_required(opts, :agent_id),
         {:ok, workspace_id} <- fetch_required(opts, :workspace_id) do
      endpoint = Keyword.get(opts, :endpoint) || default_endpoint()
      transport = Keyword.get(opts, :transport, &default_transport/3)
      timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

      metadata =
        %{
          "agent_id" => agent_id,
          "workspace_id" => workspace_id,
          "kind" => "fleetprompt_install_telespace"
        }
        |> maybe_put("version_id", Keyword.get(opts, :version_id))
        |> maybe_put("installed_by", Keyword.get(opts, :installed_by))

      content =
        "Kiln install telespace for agent=#{agent_id} workspace=#{workspace_id}"

      body = build_store_node_payload(content, metadata)

      case transport.(endpoint, body, timeout) do
        {:ok, response_body} ->
          parse_store_node_response(response_body, endpoint)

        {:error, reason} ->
          {:error, {:transport_failed, reason}}
      end
    end
  end

  defp fetch_required(opts, key) do
    case Keyword.get(opts, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing_required, key}}
    end
  end

  @doc false
  # Public-ish for testing — builds the JSON-RPC payload for
  # `act(action: "store_node", ...)`.
  @spec build_store_node_payload(String.t(), map()) :: binary()
  def build_store_node_payload(content, metadata) when is_binary(content) and is_map(metadata) do
    args = %{
      "action" => "store_node",
      "content" => content,
      "node_type" => "semantic",
      "confidence" => 0.9,
      "source" => "fleetprompt.install_engine",
      "metadata" => Jason.encode!(metadata)
    }

    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => "tools/call",
      "params" => %{
        "name" => "act",
        "arguments" => args
      }
    })
  end

  @doc false
  @spec parse_store_node_response(binary() | map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def parse_store_node_response(body, endpoint) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_store_node_response(decoded, endpoint)
      {:error, err} -> {:error, {:malformed_response, err}}
    end
  end

  def parse_store_node_response(%{"error" => %{"code" => code, "message" => msg}}, _endpoint) do
    {:error, {:jsonrpc_error, code, msg}}
  end

  def parse_store_node_response(%{"result" => result}, endpoint) when is_map(result) do
    structured = Map.get(result, "structuredContent") || Map.get(result, :structured_content)

    cond do
      is_map(structured) and structured["status"] == "error" ->
        {:error, {:tool_error, structured["error"], structured["reason"]}}

      is_map(structured) ->
        node_id =
          Map.get(structured, "node_id") || Map.get(structured, "id") ||
            get_in(structured, ["node", "id"])

        {:ok, %{"node_id" => node_id, "endpoint" => endpoint, "raw" => structured}}

      is_list(result["content"]) ->
        parse_store_node_from_content_array(result["content"], endpoint)

      true ->
        {:error, {:unexpected_response_shape, Map.keys(result)}}
    end
  end

  def parse_store_node_response(other, _endpoint),
    do: {:error, {:unexpected_response_shape, other}}

  defp parse_store_node_from_content_array(content, endpoint) do
    with %{"type" => "text", "text" => text} <- List.first(content) || %{},
         {:ok, decoded} <- Jason.decode(text),
         true <- is_map(decoded) do
      node_id =
        Map.get(decoded, "node_id") || Map.get(decoded, "id") ||
          get_in(decoded, ["node", "id"])

      {:ok, %{"node_id" => node_id, "endpoint" => endpoint, "raw" => decoded}}
    else
      _ -> {:error, {:unexpected_response_shape, :content_text}}
    end
  end

  @doc """
  Parse a raw MCP JSON-RPC response body into a list of traces. Handles
  both string bodies and already-decoded maps. Public for testing.
  """
  @spec parse_response(binary() | map()) :: {:ok, [map()]} | {:error, term()}
  def parse_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, err} -> {:error, {:malformed_response, err}}
    end
  end

  def parse_response(%{"error" => %{"code" => code, "message" => msg}}) do
    {:error, {:jsonrpc_error, code, msg}}
  end

  def parse_response(%{"result" => result}) when is_map(result) do
    structured = Map.get(result, "structuredContent") || Map.get(result, :structured_content)

    cond do
      is_map(structured) and structured["status"] == "error" ->
        {:error, {:tool_error, structured["error"], structured["reason"]}}

      is_map(structured) and is_list(structured["traces"]) ->
        {:ok, Enum.map(structured["traces"], &flatten_trace/1)}

      # Some MCP transports deliver structured payloads inside the
      # content[].text field as an embedded JSON string. Fall through
      # to parse that.
      is_list(result["content"]) ->
        parse_from_content_array(result["content"])

      true ->
        {:error, {:unexpected_response_shape, Map.keys(result)}}
    end
  end

  def parse_response(other), do: {:error, {:unexpected_response_shape, other}}

  # Hoist replay_manifest.edges to the top level so downstream parsers
  # (e.g. Kiln.Skills.Crystallizer) see the shape they expect.
  defp flatten_trace(trace) when is_map(trace) do
    manifest = Map.get(trace, "replay_manifest") || %{}
    edges = Map.get(manifest, "edges", Map.get(trace, "edges", []))

    trace
    |> Map.put("edges", edges)
    # Keep the replay_manifest around under a distinct key in case
    # downstream wants it (e.g. to check `destructive` or
    # `re_authorization_required`).
    |> Map.put_new("replay_manifest", manifest)
  end

  defp flatten_trace(other), do: other

  defp parse_from_content_array(content) do
    with %{"type" => "text", "text" => text} <- List.first(content) || %{},
         {:ok, decoded} <- Jason.decode(text),
         true <- is_map(decoded) and is_list(decoded["traces"]) do
      {:ok, Enum.map(decoded["traces"], &flatten_trace/1)}
    else
      _ -> {:error, {:unexpected_response_shape, :content_text}}
    end
  end

  @doc false
  # Public-ish for testing — builds the exact JSON-RPC payload we POST.
  @spec build_payload(String.t() | nil, String.t() | nil, integer(), String.t() | nil) :: binary()
  def build_payload(state_hash, trace_id, limit, body_subtype) do
    args =
      %{"action" => "replay", "limit" => limit}
      |> maybe_put("state_hash", state_hash)
      |> maybe_put("trace_id", trace_id)
      |> maybe_put("body_subtype", body_subtype)

    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => "tools/call",
      "params" => %{
        "name" => "retrieve",
        "arguments" => args
      }
    })
  end

  @doc false
  # Default transport: HTTP POST via :httpc. Returns {:ok, body_bin}
  # or {:error, reason}. Tests inject their own.
  #
  # Internally this wraps `post_with_headers/4` (MCP-aware, handles
  # session lifecycle) but presents the legacy single-call interface
  # that injected test transports expect — the MCP handshake runs
  # before the actual payload is sent.
  @spec default_transport(String.t(), binary(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def default_transport(url, body, timeout) do
    ensure_inets_started()

    # If the caller is sending a JSON-RPC payload that is NOT an
    # `initialize` call, run the MCP handshake first so the session
    # id is valid. This keeps `initialize_telespace/1` /
    # `fetch_successful_traces/1` working against Streamable HTTP
    # MCP endpoints (Anubis, etc.) without each caller having to
    # orchestrate the session lifecycle themselves.
    case classify_payload(body) do
      :mcp_initialize ->
        # Send as-is; caller owns the session handshake.
        post_with_headers(url, body, nil, timeout) |> unwrap_body()

      {:mcp_tool_call, _method} ->
        case mcp_handshake(url, timeout) do
          {:ok, session_id} ->
            post_with_headers(url, body, session_id, timeout) |> unwrap_body()

          {:error, reason} ->
            {:error, reason}
        end

      :unknown ->
        post_with_headers(url, body, nil, timeout) |> unwrap_body()
    end
  end

  defp classify_payload(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"method" => "initialize"}} -> :mcp_initialize
      {:ok, %{"method" => method}} -> {:mcp_tool_call, method}
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  # Runs the MCP initialize handshake against the endpoint, returning
  # {:ok, session_id_or_nil}. Some MCP servers don't issue session ids
  # (local stdio-emulated endpoints, simple test fakes); for those we
  # return `{:ok, nil}` and subsequent calls proceed without the
  # mcp-session-id header.
  defp mcp_handshake(url, timeout) do
    init_body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{},
          "clientInfo" => %{
            "name" => "fleetprompt-graphonomous-client",
            "version" => "0.1.0"
          }
        }
      })

    case post_with_headers(url, init_body, nil, timeout) do
      {:ok, %{status: status, body: body, headers: headers}} when status in 200..299 ->
        session_id = extract_session_id(headers, body)

        # Fire-and-forget `notifications/initialized` so the server
        # transitions the session to the "ready" state.
        notif_body =
          Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

        _ = post_with_headers(url, notif_body, session_id, timeout)

        {:ok, session_id}

      {:ok, %{status: status, body: body}} ->
        {:error, {:mcp_handshake_failed, status, body}}

      {:error, reason} ->
        {:error, {:transport_failed, reason}}
    end
  end

  defp extract_session_id(headers, _body) when is_list(headers) do
    Enum.find_value(headers, fn
      {"mcp-session-id", v} -> v
      {k, v} when is_binary(k) -> if String.downcase(k) == "mcp-session-id", do: v
      _ -> nil
    end)
  end

  defp extract_session_id(_, _), do: nil

  defp unwrap_body({:ok, %{body: body}}), do: {:ok, body}
  defp unwrap_body({:error, _} = err), do: err

  @doc false
  @spec post_with_headers(String.t(), binary(), String.t() | nil, non_neg_integer()) ::
          {:ok, %{status: non_neg_integer(), body: binary(), headers: list()}}
          | {:error, term()}
  def post_with_headers(url, body, session_id, timeout) do
    ensure_inets_started()

    url_charlist = String.to_charlist(url)

    base_headers = [
      # Anubis Streamable HTTP requires advertising both JSON and SSE.
      {~c"accept", ~c"application/json, text/event-stream"}
    ]

    headers =
      if session_id do
        [{~c"mcp-session-id", String.to_charlist(session_id)} | base_headers]
      else
        base_headers
      end

    content_type = ~c"application/json"
    request = {url_charlist, headers, content_type, body}

    http_opts = [
      timeout: timeout,
      connect_timeout: min(timeout, 5_000)
    ]

    opts = [body_format: :binary]

    case :httpc.request(:post, request, http_opts, opts) do
      {:ok, {{_, status, _}, resp_headers, resp_body}} when status in 200..299 ->
        normalized_body = maybe_parse_sse(resp_body, resp_headers)
        normalized_headers = normalize_headers(resp_headers)
        {:ok, %{status: status, body: normalized_body, headers: normalized_headers}}

      {:ok, {{_, status, reason}, _headers, resp_body}} ->
        {:error, {:http_status, status, to_string(reason), resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Anubis Streamable HTTP may return a single JSON-RPC response
  # either as `Content-Type: application/json` OR as an SSE frame
  # (`text/event-stream`) with one `data: {...}` line. Collapse the
  # SSE form to the embedded JSON so downstream parsing is uniform.
  defp maybe_parse_sse(body, headers) do
    content_type =
      Enum.find_value(headers, "", fn
        {k, v} when is_list(k) ->
          if List.to_string(k) |> String.downcase() == "content-type",
            do: List.to_string(v)

        _ ->
          false
      end) || ""

    if String.contains?(content_type, "text/event-stream") do
      extract_sse_data(body) || body
    else
      body
    end
  end

  defp extract_sse_data(body) when is_binary(body) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.find_value(fn line ->
      case line do
        "data: " <> json -> json
        "data:" <> rest -> String.trim_leading(rest)
        _ -> nil
      end
    end)
  end

  defp extract_sse_data(_), do: nil

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      {k, v} when is_list(k) -> {List.to_string(k) |> String.downcase(), List.to_string(v)}
      {k, v} when is_binary(k) -> {String.downcase(k), to_string(v)}
      other -> other
    end)
  end

  defp normalize_headers(_), do: []

  defp ensure_inets_started do
    # :httpc is part of the `inets` OTP app — production environments
    # already start it (Graphonomous does), but tests that exercise
    # this module directly may not.
    _ = :inets.start()
    _ = :ssl.start()
    :ok
  end

  defp default_endpoint do
    Application.get_env(
      :kiln,
      :graphonomous_endpoint,
      "https://graphonomous-mcp.fly.dev/mcp"
    )
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, _k, ""), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end

defmodule Kiln.Skills.GraphonomousClient.Stub do
  @moduledoc """
  Test stub — returns whatever traces have been pre-seeded via
  `put_traces/1`. Used by the crystallization unit tests and by
  anyone who wants to run the poll worker end-to-end without a live
  Graphonomous MCP server.
  """

  @behaviour Kiln.Skills.GraphonomousClient

  @table :kiln_graphonomous_stub

  @doc "Seed the stub with traces that will be returned on the next fetch."
  def put_traces(traces) when is_list(traces) do
    ensure_table()
    :ets.insert(@table, {:traces, traces})
    :ok
  end

  @doc "Clear all seeded traces."
  def clear do
    ensure_table()
    :ets.delete(@table, :traces)
    :ok
  end

  @impl true
  def fetch_successful_traces(_opts) do
    ensure_table()

    case :ets.lookup(@table, :traces) do
      [{:traces, list}] when is_list(list) -> {:ok, list}
      _ -> {:ok, []}
    end
  end

  @doc """
  Seed the next `initialize_telespace/1` return value. Accepts either
  a `{:ok, map}` / `{:error, term}` shape or a bare map (wrapped in
  `{:ok, _}`). If unset, `initialize_telespace/1` returns a stub
  `{:ok, %{"node_id" => "stub-telespace", "endpoint" => "stub"}}`.
  """
  def put_telespace_result(result) do
    ensure_table()
    :ets.insert(@table, {:telespace, result})
    :ok
  end

  @impl true
  def initialize_telespace(_opts) do
    ensure_table()

    case :ets.lookup(@table, :telespace) do
      [{:telespace, {:ok, _} = ok}] -> ok
      [{:telespace, {:error, _} = err}] -> err
      [{:telespace, map}] when is_map(map) -> {:ok, map}
      _ -> {:ok, %{"node_id" => "stub-telespace", "endpoint" => "stub"}}
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])

      _ ->
        :ok
    end
  end
end
