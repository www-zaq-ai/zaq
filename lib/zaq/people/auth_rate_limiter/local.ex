defmodule Zaq.People.AuthRateLimiter.Local do
  @moduledoc false
  use Hammer, backend: :ets
end
