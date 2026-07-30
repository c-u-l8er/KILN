defmodule Kiln.MixProject do
  use Mix.Project

  def project do
    [
      app: :kiln,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      description: "The crystallize-and-ship engine for the [&] ecosystem.",
      package: package()
    ]
  end

  def application do
    [
      # :inets carries :httpc, the default transport for
      # Kiln.Skills.GraphonomousClient. Declared here rather than
      # lazy-started so it is available before the first poll.
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # KILN is a library. It has no Repo of its own, no supervision tree, and no
  # web layer — the host application supplies all three. That is the difference
  # between an engine and a product, and keeping the dep list this short is how
  # the difference stays true.
  defp deps do
    [
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:jason, "~> 1.2"},
      # Only Kiln.Skills.PollWorker needs Oban, and only when the host runs it
      # as a background job. Optional so a host that drives crystallization
      # synchronously does not inherit a job queue.
      {:oban, "~> 2.19", optional: true},
      # Test-only. The GraphonomousClient suite stands up a fake MCP server to
      # exercise the real :httpc transport against a real socket. Kept rather
      # than deleted on extraction, because a transport tested only against a
      # stub is a transport that has never been tested.
      {:plug, "~> 1.16", only: :test},
      {:bandit, "~> 1.5", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/c-u-l8er/KILN"}
    ]
  end

  defp aliases do
    [
      precommit: ["compile --warnings-as-errors", "format", "test"]
    ]
  end
end
