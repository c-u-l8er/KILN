import Config

# Points at the same local Supabase the rest of the [&] stack uses.
config :kiln, Kiln.TestRepo,
  hostname: "127.0.0.1",
  port: 54322,
  username: "postgres",
  password: "postgres",
  database: "postgres",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :kiln, ecto_repos: [Kiln.TestRepo]
config :logger, level: :warning
