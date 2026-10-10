defmodule Zaq.Engine.Connect.CredentialStatusesTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Connect.CredentialStatuses

  test "returns not found for an invalid credential reference" do
    assert CredentialStatuses.get_person(1, 0) == {:error, :not_found}
  end
end
