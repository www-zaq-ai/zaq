defmodule Zaq.UserPortal.InstallationWorkerTest do
  use Zaq.DataCase, async: false
  use Oban.Testing, repo: Zaq.Repo

  alias Zaq.Engine.ChannelConfig
  alias Zaq.Repo
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

  test "a non-binary installation URL does not modify the Global URL" do
    assert :ok = System.set_global_base_url("https://existing.example.com")

    assert {:cancel, :invalid_installation} =
             perform_job(InstallationWorker, %{
               installation_url: 123,
               deploy_on_own_cluster: false
             })

    assert System.get_global_base_url() == "https://existing.example.com"
  end

  test "a non-boolean cluster flag does not modify the Global URL" do
    assert :ok = System.set_global_base_url("https://existing.example.com")

    assert {:cancel, :invalid_installation} =
             perform_job(InstallationWorker, %{
               installation_url: "https://instance.example.com",
               deploy_on_own_cluster: "false"
             })

    assert System.get_global_base_url() == "https://existing.example.com"
  end

  test "an unavailable Engine makes the Global URL step retryable" do
    supervisor = Zaq.Engine.Supervisor
    pid = Process.whereis(supervisor)
    Process.unregister(supervisor)

    try do
      assert {:error, :global_url} =
               perform_job(InstallationWorker, %{
                 installation_url: "https://instance.example.com",
                 deploy_on_own_cluster: false
               })

      assert System.get_global_base_url() == nil
    after
      Process.register(pid, supervisor)
    end
  end

  @tag :tmp_dir
  test "cluster provisioning creates the destinations and reuses them on retry", %{tmp_dir: root} do
    configure_storage_root(root)

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

  @tag :tmp_dir
  test "a screenshot path that is a file stops cluster setup after saving the Global URL",
       %{tmp_dir: root} do
    configure_storage_root(root)

    screenshot_path = Path.join(root, ".web_browser")
    assert :ok = File.write(screenshot_path, "blocking file")
    assert :ok = System.set_global_base_url("https://existing.example.com")
    screenshot_config_before = System.get_web_browsing_config()
    skills_config_before = System.get_skill_resource_config()

    assert {:error, :screenshot_folder} =
             perform_job(InstallationWorker, %{
               installation_url: "https://cluster.example.com",
               deploy_on_own_cluster: true
             })

    assert System.get_global_base_url() == "https://cluster.example.com"
    assert File.read!(screenshot_path) == "blocking file"
    refute File.exists?(Path.join(root, ".SKILLS"))
    assert config = ChannelConfig.get_by_provider("disk")
    assert config.enabled
    assert config.settings["volumes"] == [%{"name" => "Documents", "path" => "."}]
    assert config.settings["default_volume"] == "Documents"
    assert System.get_web_browsing_config() == screenshot_config_before
    assert System.get_skill_resource_config() == skills_config_before
  end

  @tag :tmp_dir
  test "a rejected skills destination save returns an error after screenshot setup",
       %{tmp_dir: root} do
    configure_storage_root(root)

    assert {:ok, _} =
             System.set_config("system.agent_skills.resources.folder_path", "previous")

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_skills_destination() RETURNS trigger AS $$
    BEGIN
      IF NEW.key = 'system.agent_skills.resources.folder_path' AND NEW.value = '.SKILLS' THEN
        RAISE EXCEPTION 'injected skills destination failure'
          USING ERRCODE = '23505', CONSTRAINT = 'system_configs_key_index';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!(
      "CREATE TRIGGER reject_skills_destination BEFORE INSERT OR UPDATE ON system_configs FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_skills_destination()"
    )

    assert {:error, :skills_destination} =
             perform_job(InstallationWorker, %{
               installation_url: "https://cluster.example.com",
               deploy_on_own_cluster: true
             })

    assert System.get_global_base_url() == "https://cluster.example.com"
    assert File.dir?(Path.join(root, ".SKILLS"))
    assert {:ok, screenshot} = System.get_web_browsing_config()

    assert {screenshot.scope_id, screenshot.folder_path} == {"Documents", ".web_browser"}
    assert System.get_skill_resource_config().folder_path == "previous"
  end

  defp configure_storage_root(root) do
    previous = Application.get_env(:zaq, Zaq.Storage)
    Application.put_env(:zaq, Zaq.Storage, base_path: root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:zaq, Zaq.Storage, previous),
        else: Application.delete_env(:zaq, Zaq.Storage)
    end)
  end
end
