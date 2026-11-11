defmodule Zaq.TestSupport.ChannelFileFixtures do
  @moduledoc """
  Private source files and transport connectors for attachment tests.

  Each call creates its own resources. Callers retain permission grants, Record
  retrieval, transport responses and delivery synchronization.
  """

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias Zaq.Engine.ChannelConfig
  alias Zaq.Repo
  alias Zaq.Storage.VolumeConfig
  alias Zaq.TestSupport.{FileDeliverySmtpStub, OpenAIStub}

  @doc "Creates a connector with synthetic credentials for tests that replace the transport boundary."
  def connector!(provider, settings) do
    name = Ecto.UUID.generate()

    config!(provider, name, %{
      name: name,
      url: "https://fixture.invalid",
      token: "synthetic-unused",
      settings: settings
    })
  end

  @doc "Inserts a fresh connector through its changeset, with explicit attribute overrides."
  def config!(provider, namespace, attrs) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(
      Map.merge(
        %{name: "#{provider}-#{namespace}", provider: provider, kind: "retrieval", enabled: true},
        attrs
      )
    )
    |> Repo.insert!()
  end

  @doc "Writes named files in an owned Disk volume and registers directory cleanup; grants no access."
  def disk_files!(namespace, volume, files, attrs \\ %{}) do
    root = Path.join(VolumeConfig.base_path(), namespace)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    for file <- files, do: File.write!(Path.join(root, file.name), file.bytes)

    config =
      config!(
        "disk",
        namespace,
        Map.merge(
          %{
            kind: "data_source",
            settings: %{"volumes" => [%{"name" => volume, "path" => namespace}]}
          },
          attrs
        )
      )

    {config, root}
  end

  @doc "Starts a private HTTP stub and inserts a Mattermost connector using the supplied handler."
  def mattermost!(owner, namespace, handler, attrs) do
    {child, endpoint} = OpenAIStub.server(handler, owner)
    start_supervised!(Supervisor.child_spec(child, id: make_ref()))
    config!("mattermost", namespace, Map.put(attrs, :url, String.trim_trailing(endpoint, "/v1")))
  end

  @doc "Starts a private SMTP capture server and inserts its connector with supplied sender settings."
  def smtp!(owner, namespace, settings, opts \\ []) do
    port = FileDeliverySmtpStub.start!(owner, namespace, opts)

    config!("email:smtp", namespace, %{
      url: "smtp://127.0.0.1",
      token: "synthetic-unused",
      settings:
        Map.merge(
          %{"relay" => "127.0.0.1", "port" => to_string(port), "tls" => "never"},
          settings
        )
    })
  end
end
