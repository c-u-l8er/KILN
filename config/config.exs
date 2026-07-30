import Config

# KILN is a library. This file exists so `mix test` inside this repo has a repo
# to talk to; a host application configures :kiln in its own config and never
# sees this.
config :kiln,
  repo: Kiln.TestRepo,
  schema_prefix: "fleet"

import_config "#{config_env()}.exs"
