defmodule Zaq.People.IdentityPlugTest.StubRouterOk do
  @moduledoc false
  def fetch_profile(_platform, _author_id) do
    {:ok, %{display_name: "Enriched Name", email: "enriched@example.com"}}
  end

  def open_dm_channel(_platform, _author_id), do: {:error, :not_supported}
end

defmodule Zaq.People.IdentityPlugTest.StubRouterError do
  @moduledoc false
  def fetch_profile(_platform, _author_id), do: {:error, :not_found}
  def open_dm_channel(_platform, _author_id), do: {:error, :not_found}
end

defmodule Zaq.People.IdentityPlugTest.StubRouterTimeout do
  @moduledoc false
  def fetch_profile(_platform, _author_id), do: {:error, :timeout}
  def open_dm_channel(_platform, _author_id), do: {:error, :timeout}
end

defmodule Zaq.People.IdentityPlugTest.StubRouterRaise do
  @moduledoc false
  def fetch_profile(_platform, _author_id) do
    raise "channels router should not have been called on the fast path"
  end

  def open_dm_channel(_platform, _author_id), do: {:error, :not_supported}
end

defmodule Zaq.People.IdentityPlugTest.StubRouterStringKeys do
  @moduledoc false
  def fetch_profile(_platform, _author_id) do
    {:ok, %{"display_name" => "String Key Name", "email" => "string@example.com"}}
  end

  def open_dm_channel(_platform, _author_id), do: {:error, :not_supported}
end

defmodule Zaq.People.IdentityPlugTest.StubRouterDmOk do
  @moduledoc false
  def fetch_profile(_platform, _author_id), do: {:error, :not_found}
  def open_dm_channel(_platform, _author_id), do: {:ok, "DM_BACKFILLED"}
end
