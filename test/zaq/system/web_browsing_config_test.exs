defmodule Zaq.System.WebBrowsingConfigTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Api
  alias Zaq.Event
  alias Zaq.System
  alias Zaq.System.WebBrowsingConfig

  test "missing settings are unrestricted but have no screenshot destination" do
    assert {:ok, %WebBrowsingConfig{allowed_domains: "", provider: nil}} =
             System.get_web_browsing_config()
  end

  test "changeset rejects non-map settings" do
    for attrs <- [nil, [], %WebBrowsingConfig{}] do
      changeset = WebBrowsingConfig.changeset(%WebBrowsingConfig{}, attrs)

      refute changeset.valid?
      assert {:base, {"invalid settings", []}} in changeset.errors
    end

    changeset = WebBrowsingConfig.changeset(%WebBrowsingConfig{}, %{allowed_domains: "ZAQ.AI"})
    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :allowed_domains) == "zaq.ai"
  end

  test "domain normalization rejects non-binary input" do
    for input <- [nil, 42, ["zaq.ai"], %{allowed_domains: "zaq.ai"}] do
      assert WebBrowsingConfig.normalize_domains(input) == {:error, :invalid_domains}
    end
  end

  test "domain normalization enforces the total hostname length limit" do
    label = String.duplicate("a", 63)
    host_253 = Enum.join([label, label, label, String.duplicate("a", 61)], ".")
    host_254 = Enum.join([label, label, label, String.duplicate("a", 62)], ".")

    assert byte_size(host_253) == 253
    assert {:ok, ^host_253} = WebBrowsingConfig.normalize_domains(host_253)
    assert byte_size(host_254) == 254
    assert {:error, :invalid_domains} = WebBrowsingConfig.normalize_domains(host_254)

    changeset =
      WebBrowsingConfig.changeset(%WebBrowsingConfig{}, %{allowed_domains: host_254})

    assert {:allowed_domains, {"enter comma-separated hostnames", []}} in changeset.errors
  end

  property "domain normalization rejects generated overlength hostnames" do
    label = String.duplicate("a", 63)

    check all(last_label_length <- integer(62..63), max_runs: 20) do
      host = Enum.join([label, label, label, String.duplicate("a", last_label_length)], ".")

      assert byte_size(host) in 254..255
      assert WebBrowsingConfig.normalize_domains(host) == {:error, :invalid_domains}
    end
  end

  test "normalizes hosts and preserves a configured datasource folder" do
    {:ok, source} =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Screenshots",
        provider: "google_drive",
        kind: "data_source"
      })
      |> Repo.insert()

    attrs = %{
      "allowed_domains" => " ZAQ.AI, www.ZAQ.ai ,zaq.ai ",
      "provider" => "google_drive",
      "config_id" => to_string(source.id),
      "scope_id" => "volume-one",
      "folder_id" => "folder-42",
      "folder_path" => "/screenshots"
    }

    assert {:ok, config} = System.save_web_browsing_config(attrs)
    assert config.allowed_domains == "zaq.ai,www.zaq.ai"
    assert config.config_id == source.id
    assert config.scope_id == "volume-one"
    assert config.folder_id == "folder-42"
    assert {:ok, ^config} = System.get_web_browsing_config()
  end

  test "invalid domains and incomplete destinations cannot alter stored settings" do
    assert {:ok, initial} = System.save_web_browsing_config(%{allowed_domains: "zaq.ai"})

    for invalid <- ["https://zaq.ai", "zaq.ai:443", "*.zaq.ai", "zaq.ai/path", "a..com"] do
      assert {:error, _} = System.save_web_browsing_config(%{allowed_domains: invalid})
      assert {:ok, ^initial} = System.get_web_browsing_config()
    end

    assert {:error, _} = System.save_web_browsing_config(%{provider: "disk"})
    assert {:ok, ^initial} = System.get_web_browsing_config()
  end

  test "rejects disabled or mismatched datasource configurations without persisting the policy" do
    {:ok, source} =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Disabled screenshots",
        provider: "google_drive",
        kind: "data_source",
        enabled: false
      })
      |> Repo.insert()

    assert {:error, :invalid_web_browsing_destination} =
             System.save_web_browsing_config(%{
               allowed_domains: "zaq.ai",
               provider: "google_drive",
               config_id: source.id,
               folder_id: "folder-42"
             })

    assert {:error, :invalid_web_browsing_destination} =
             System.save_web_browsing_config(%{
               allowed_domains: "zaq.ai",
               provider: "sharepoint",
               config_id: source.id,
               folder_id: "folder-42"
             })

    assert {:ok, %WebBrowsingConfig{allowed_domains: ""}} = System.get_web_browsing_config()
  end

  test "partial saves preserve the previously selected destination" do
    {:ok, source} =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Screenshots",
        provider: "google_drive",
        kind: "data_source"
      })
      |> Repo.insert()

    assert {:ok, _} =
             System.save_web_browsing_config(%{
               provider: "google_drive",
               config_id: source.id,
               folder_id: "folder-42"
             })

    assert {:ok, %{provider: "google_drive", folder_id: "folder-42", allowed_domains: "zaq.ai"}} =
             System.save_web_browsing_config(%{allowed_domains: "zaq.ai"})
  end

  test "malformed stored values fail closed" do
    assert {:ok, _} = System.set_config("system.web_browsing.allowed_domains", "https://zaq.ai")
    assert {:error, _} = System.get_web_browsing_config()
  end

  test "a failed later settings write rolls back an earlier allowlist change" do
    assert {:ok, initial} = System.save_web_browsing_config(%{allowed_domains: "zaq.ai"})

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_browser_settings() RETURNS trigger AS $$
    BEGIN
      IF NEW.key = 'system.web_browsing.screenshots.folder_path' THEN
        RAISE EXCEPTION 'injected later row failure' USING ERRCODE = '23505', CONSTRAINT = 'system_configs_key_index';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!(
      "CREATE TRIGGER reject_browser_settings BEFORE INSERT OR UPDATE ON system_configs FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_browser_settings()"
    )

    assert {:error, %Ecto.Changeset{}} =
             System.save_web_browsing_config(%{allowed_domains: "www.zaq.ai"})

    assert {:ok, ^initial} = System.get_web_browsing_config()
  end

  test "Engine events return the grouped settings and reject malformed requests" do
    event = Event.new(%{}, :engine)

    assert %{response: {:ok, %WebBrowsingConfig{}}} =
             Api.handle_event(event, :system_config_get_web_browsing_config, %{})

    assert %{response: {:error, {:invalid_request, _}}} =
             Api.handle_event(event, :system_config_save_web_browsing_config, %{})
  end

  property "domain normalization is idempotent" do
    check all(
            names <-
              uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 16), max_length: 8)
          ) do
      domains = Enum.map_join(names, ",", &(&1 <> ".example"))
      assert {:ok, normalized} = WebBrowsingConfig.normalize_domains(domains)
      assert {:ok, ^normalized} = WebBrowsingConfig.normalize_domains(normalized)
    end
  end
end
