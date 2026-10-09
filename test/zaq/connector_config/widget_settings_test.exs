defmodule Zaq.ConnectorConfig.WidgetSettingsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.ConnectorConfig.WidgetSettings

  test "authentication and cookie settings have canonical defaults and strict validation" do
    assert WidgetSettings.defaults() == %{
             "identity_issuer" => "zaq_issuer",
             "identity_audience" => "zaq_audience",
             "same_site" => "None"
           }

    for policy <- ["None", "Lax", "Strict"] do
      assert :ok =
               WidgetSettings.validate(Map.put(WidgetSettings.defaults(), "same_site", policy))
    end

    for key <- ["identity_issuer", "identity_audience"],
        value <- [nil, "", " issuer", "issuer ", 12, String.duplicate("a", 256), <<255>>] do
      assert {:error, :invalid_widget_settings} = WidgetSettings.validate(%{key => value})
    end

    for value <- [nil, "", "none", "Invalid", :lax] do
      assert {:error, :invalid_widget_settings} = WidgetSettings.validate(%{"same_site" => value})
    end
  end

  property "arbitrary policy values outside the closed SameSite enum are rejected" do
    check all(value <- term(), value not in ["None", "Lax", "Strict"]) do
      assert {:error, :invalid_widget_settings} = WidgetSettings.validate(%{"same_site" => value})
    end
  end

  test "accepts absent settings and bounded presentation settings" do
    assert :ok = WidgetSettings.validate(%{})

    assert :ok =
             WidgetSettings.validate(%{
               "display_name" => String.duplicate("a", 200),
               "allowed_domains" => List.duplicate("https://parent.example.test", 100)
             })
  end

  test "rejects invalid names, origin policies, persisted stylesheets and malformed settings" do
    for settings <- [
          nil,
          [],
          %{"display_name" => " "},
          %{"display_name" => String.duplicate("a", 201)},
          %{"display_name" => 42},
          %{"allowed_domains" => ["*"]},
          %{"allowed_domains" => List.duplicate("https://parent.example.test", 101)},
          %{"allowed_domains" => "https://parent.example.test"},
          %{"stylesheet_url" => "https://remote.example.test/widget.css"},
          %{"stylesheet_url" => "//remote.example.test/widget.css"},
          %{"stylesheet_url" => "/assets/../private.css"},
          %{"stylesheet_url" => 42}
        ] do
      assert {:error, :invalid_widget_settings} = WidgetSettings.validate(settings)
    end
  end

  test "stylesheets are init-only, including nil and atom-keyed persisted values" do
    for key <- [:stylesheet_url, "stylesheet_url"],
        value <- [nil, "/assets/widget.css", "http://localhost:4000/style.css"] do
      assert {:error, :invalid_widget_settings} = WidgetSettings.validate(%{key => value})
    end
  end

  property "no settings value can replace the connector-derived widget identity" do
    check all(value <- term()) do
      for key <- ["widget_id", :widget_id] do
        assert {:error, :invalid_widget_settings} = WidgetSettings.validate(%{key => value})
      end
    end
  end

  property "origins are exact authorities, never paths, credentials, queries or fragments" do
    check all(host <- string(:alphanumeric, min_length: 1, max_length: 20)) do
      origin = "https://#{host}.example.test"
      assert :ok = WidgetSettings.validate(%{"allowed_domains" => [origin]})

      for forbidden <- [
            origin <> "/",
            origin <> "/path",
            origin <> "?q=1",
            origin <> "#x",
            "https://user@#{host}.example.test"
          ] do
        assert {:error, :invalid_widget_settings} =
                 WidgetSettings.validate(%{"allowed_domains" => [forbidden]})
      end
    end
  end
end
