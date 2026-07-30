defmodule Kiln.TestRepo do
  @moduledoc """
  A repo that exists only so this library's own tests have somewhere to write.

  KILN ships no repo. A host supplies one via `config :kiln, repo: MyApp.Repo`,
  and this is that config's value inside this repo and nowhere else.
  """
  use Ecto.Repo, otp_app: :kiln, adapter: Ecto.Adapters.Postgres
end
