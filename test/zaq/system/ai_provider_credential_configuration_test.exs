defmodule Zaq.System.AIProviderCredentialConfigurationTest do
  use Zaq.DataCase, async: true

  alias Zaq.System.AIProviderCredentialConfiguration

  test "save rejects non-map configuration and metadata" do
    assert {:error, :invalid_configuration} =
             AIProviderCredentialConfiguration.save(nil, [], [])

    assert {:error, :invalid_configuration} =
             AIProviderCredentialConfiguration.save(nil, nil, [])
  end
end
