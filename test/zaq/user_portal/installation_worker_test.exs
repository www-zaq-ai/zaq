defmodule Zaq.UserPortal.InstallationWorkerTest do
  use Zaq.DataCase, async: false
  use Oban.Testing, repo: Zaq.Repo

  alias Zaq.Engine.ChannelConfig
  alias Zaq.System
  alias Zaq.UserPortal.InstallationWorker

  test "hosted provisioning saves only the Global URL" do
    assert :ok =
             perform_job(InstallationWorker, %{
               installation_url: "https://instance.example.com",
               deploy_on_own_cluster: false
             })

    assert System.get_global_base_url() == "https://instance.example.com"
    assert ChannelConfig.get_any_by_provider("disk") == nil
  end

  test "invalid installation arguments do not modify the Global URL" do
    assert {:cancel, :invalid_installation} =
             perform_job(InstallationWorker, %{
               installation_url: "file:///mnt/zaq",
               deploy_on_own_cluster: false
             })

    assert System.get_global_base_url() == nil
  end

  @tag :tmp_dir
  test "cluster provisioning creates the destinations and reuses them on retry", %{tmp_dir: root} do
    previous = Application.get_env(:zaq, Zaq.Storage)
    Application.put_env(:zaq, Zaq.Storage, base_path: root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:zaq, Zaq.Storage, previous),
        else: Application.delete_env(:zaq, Zaq.Storage)
    end)

    args = %{installation_url: "https://cluster.example.com", deploy_on_own_cluster: true}

    assert :ok = perform_job(InstallationWorker, args)
    assert :ok = perform_job(InstallationWorker, args)

    assert config = ChannelConfig.get_by_provider("disk")
    assert config.enabled
    assert config.settings["volumes"] == [%{"name" => "Documents", "path" => "."}]
    assert config.settings["default_volume"] == "Documents"

    assert File.dir?(Path.join(root, ".web_browser"))
    assert File.dir?(Path.join(root, ".SKILLS"))
    assert {:ok, screenshot} = System.get_web_browsing_config()
    skills = System.get_skill_resource_config()

    assert {screenshot.config_id, screenshot.scope_id, screenshot.folder_path} ==
             {config.id, "Documents", ".web_browser"}

    assert {skills.config_id, skills.scope_id, skills.folder_path} ==
             {config.id, "Documents", ".SKILLS"}

    assert is_binary(screenshot.folder_id)
    assert is_binary(skills.folder_id)
  end
end
