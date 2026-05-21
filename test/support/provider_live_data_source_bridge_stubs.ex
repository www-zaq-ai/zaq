defmodule Zaq.Test.ProviderLiveDataSourceBridgeStubs do
  @moduledoc false

  alias Zaq.Contracts.{Record, RecordPage}

  def put_bridge(provider, bridge_module) do
    channels = Application.get_env(:zaq, :channels, %{})
    provider_config = Map.get(channels, provider, %{})

    Application.put_env(
      :zaq,
      :channels,
      Map.put(channels, provider, Map.put(provider_config, :bridge, bridge_module))
    )
  end

  def record(id, name, kind \\ :folder) do
    %Record{id: id, name: name, kind: kind, permissions: []}
  end

  def page(records, cursor) do
    %RecordPage{
      resource_type: :folder,
      records: records,
      pagination: %{cursor: cursor}
    }
  end
end

defmodule Zaq.Test.ProviderLiveDataSourceBridgeStubs.UnexpectedResponse do
  @moduledoc false

  def list_files(_config, _params), do: :unexpected
end

defmodule Zaq.Test.ProviderLiveDataSourceBridgeStubs.ContinuationThenHalt do
  @moduledoc false

  alias Zaq.Test.ProviderLiveDataSourceBridgeStubs, as: Stubs

  def list_files(_config, %{"page_token" => "next-1"}) do
    {:ok,
     Stubs.page(
       [
         Stubs.record("folder-b", "Bravo"),
         Stubs.record("folder-a", "Alpha"),
         Stubs.record("folder-b", "Bravo"),
         :not_a_record
       ],
       nil
     )}
  end

  def list_files(_config, _params) do
    {:ok, Stubs.page([Stubs.record("folder-z", "Zulu")], "next-1")}
  end
end

defmodule Zaq.Test.ProviderLiveDataSourceBridgeStubs.StillMore do
  @moduledoc false

  alias Zaq.Test.ProviderLiveDataSourceBridgeStubs, as: Stubs

  def list_files(_config, _params) do
    {:ok, Stubs.page([Stubs.record("folder-one", "Only One")], "still-more")}
  end
end

defmodule Zaq.Test.ProviderLiveDataSourceBridgeStubs.DisplayMessageError do
  @moduledoc false

  def list_files(_config, _params) do
    {:error,
     %{
       message: "raw",
       display_message: "friendly",
       code: "E42",
       provider: "google_drive",
       status: 503
     }}
  end
end

defmodule Zaq.Test.ProviderLiveDataSourceBridgeStubs.NilError do
  @moduledoc false

  def list_files(_config, _params), do: {:error, nil}
end

defmodule Zaq.Test.ProviderLiveDataSourceBridgeStubs.NilIdDuplicate do
  @moduledoc false

  alias Zaq.Test.ProviderLiveDataSourceBridgeStubs, as: Stubs

  def list_files(_config, _params) do
    record = Stubs.record(nil, "Shared Folder")

    {:ok, Stubs.page([record, record], nil)}
  end
end

defmodule Zaq.Test.ProviderLiveDataSourceBridgeStubs.NonListRecordsPage do
  @moduledoc false

  alias Zaq.Test.ProviderLiveDataSourceBridgeStubs, as: Stubs

  def list_files(_config, _params) do
    {:ok, Stubs.page(:not_a_list, nil)}
  end
end
