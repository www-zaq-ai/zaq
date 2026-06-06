defmodule ZaqWeb.Live.BO.System.AddonsLiveTest do
  use ZaqWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Addons.BeamDecryptor
  alias Zaq.Addons.FeatureStore
  alias ZaqWeb.Live.BO.System.AddonsLive

  setup %{conn: conn} do
    user = user_fixture(%{username: "testadmin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = conn |> init_test_session(%{user_id: user.id})

    tmp_dir =
      Path.join(System.tmp_dir!(), "zaq_addons_live_test_") <>
        Integer.to_string(System.unique_integer([:positive]))

    File.mkdir_p!(tmp_dir)

    FeatureStore.clear()

    on_exit(fn ->
      FeatureStore.clear()
      File.rm_rf!(tmp_dir)
    end)

    %{conn: conn, user: user, tmp_dir: tmp_dir}
  end

  describe "no add-ons" do
    test "shows marketing page when no add-on package loaded", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/addons")
      assert html =~ "Unlock the full power of ZAQ"
      assert html =~ "Request Add-ons"
      assert html =~ "Available with Add-ons"
    end

    test "validate event keeps socket/render state unchanged", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/bo/addons")

      assert html =~ "Unlock the full power of ZAQ"
      refute html =~ "No file selected."

      html = render_change(view, "validate", %{})

      assert html =~ "Unlock the full power of ZAQ"
      refute html =~ "No file selected."
      refute html =~ "Could not read add-on package."
    end

    test "submitting without a selected package shows no-file error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/addons")

      view
      |> form("form[phx-submit='upload_addon']")
      |> render_submit()

      html = render(view)

      assert html =~ "No file selected."
    end

    test "shows feature cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/addons")
      assert html =~ "Ontology Management"
      assert html =~ "Knowledge Gap Detection"
      assert html =~ "Knowledge Update"
      assert html =~ "Document Update"
    end

    test "shows contact sales CTA", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/addons")
      assert html =~ "Contact Sales"
      assert html =~ "sales@zaq.ai"
    end
  end

  describe "with add-ons" do
    setup do
      FeatureStore.store(
        %{
          "license_key" => "lic_test_123",
          "company" => %{"name" => "Acme Corp"},
          "expires_at" => DateTime.utc_now() |> DateTime.add(90, :day) |> DateTime.to_iso8601(),
          "features" => [
            %{
              "name" => "Ontology Management",
              "description" => "Knowledge graph management",
              "module_tags" => ["Elixir.Zaq.Paid.Ontology"]
            },
            %{
              "name" => "Knowledge Gap Detection",
              "description" => "Find missing info",
              "module_tags" => ["Elixir.Zaq.Paid.KnowledgeGap"]
            }
          ]
        },
        [Zaq.Paid.Ontology, Zaq.Paid.KnowledgeGap]
      )

      on_exit(fn -> FeatureStore.clear() end)
      :ok
    end

    test "shows add-on info", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/addons")
      assert html =~ "Add-ons Active"
      assert html =~ "lic_test_123"
      assert html =~ "Acme Corp"
    end

    test "shows enabled features", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/addons")
      assert html =~ "Ontology Management"
      assert html =~ "Knowledge Gap Detection"
    end

    test "shows loaded module count", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/addons")
      assert html =~ "Loaded Modules"
      assert html =~ "2"
    end

    test "shows time left", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/addons")
      assert html =~ "Time Left"
    end

    test "shows disabled features for upgrade", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/addons")
      assert html =~ "Available to Enable"
      assert html =~ "Knowledge Update"
      assert html =~ "Document Update"
      assert html =~ "Not Enabled"
    end

    test "hides disabled-features section when all features are enabled", %{conn: conn} do
      FeatureStore.store(
        %{
          "license_key" => "lic_full_789",
          "company" => %{"name" => "Full Corp"},
          "expires_at" => DateTime.utc_now() |> DateTime.add(120, :day) |> DateTime.to_iso8601(),
          "features" => fully_enabled_features()
        },
        [
          Zaq.Paid.Ontology,
          Zaq.Paid.KnowledgeGap,
          Zaq.Paid.KnowledgeUpdate,
          Zaq.Paid.DocumentUpdate
        ]
      )

      {:ok, _view, html} = live(conn, ~p"/bo/addons")
      refute html =~ "Available to Enable"
      refute html =~ "Contact Sales to Upgrade"
    end
  end

  describe "addon package uploads" do
    test "uploading invalid archive copies file and shows extract failure message", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/bo/addons")

      filename = "bad.zaq-license"
      copied_path = uploaded_license_path(filename)
      on_exit(fn -> File.rm(copied_path) end)

      upload =
        file_input(view, "form[phx-submit='upload_addon']", :addon_package, [
          %{name: filename, content: "not-a-tar", type: "application/octet-stream"}
        ])

      assert render_upload(upload, filename)

      capture_log(fn ->
        view
        |> form("form[phx-submit='upload_addon']")
        |> render_submit()
      end)

      html = render(view)

      assert html =~ "Could not read add-on package."
      assert File.exists?(copied_path)
      assert File.read!(copied_path) == "not-a-tar"
    end

    test "successful package upload refreshes add-on state and clears previous error", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/bo/addons")

      view
      |> form("form[phx-submit='upload_addon']")
      |> render_submit()

      assert render(view) =~ "No file selected."

      filename = "success.zaq-license"
      copied_path = uploaded_license_path(filename)
      on_exit(fn -> File.rm(copied_path) end)

      module_name =
        "Elixir.LicenseManager.Paid.LiveViewSuccess#{System.unique_integer([:positive])}"

      archive_bytes =
        build_license_archive_bytes!(tmp_dir,
          payload: %{
            "license_key" => "lic_live_success",
            "company" => %{"name" => "Acme Corp"},
            "expires_at" => DateTime.utc_now() |> DateTime.add(90, :day) |> DateTime.to_iso8601(),
            "features" => [
              %{
                "name" => "ontology",
                "description" => "Knowledge graph management"
              }
            ]
          },
          module_name: module_name
        )

      upload =
        file_input(view, "form[phx-submit='upload_addon']", :addon_package, [
          %{name: filename, content: archive_bytes, type: "application/octet-stream"}
        ])

      assert render_upload(upload, filename)

      capture_log(fn ->
        view
        |> form("form[phx-submit='upload_addon']")
        |> render_submit()
      end)

      html = render(view)

      assert html =~ "Add-ons Active"
      assert html =~ "lic_live_success"
      assert html =~ "Acme Corp"
      assert html =~ "Ontology Management"
      refute html =~ "No file selected."
    end

    test "PubSub addons_updated refreshes rendered state", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/bo/addons")

      assert html =~ "Unlock the full power of ZAQ"

      FeatureStore.store(
        %{
          "license_key" => "lic_broadcast_001",
          "company" => %{"name" => "Broadcast Corp"},
          "expires_at" => DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.to_iso8601(),
          "features" => [
            %{
              "name" => "ontology",
              "description" => "Knowledge graph management"
            }
          ]
        },
        [Zaq.Paid.Ontology]
      )

      Phoenix.PubSub.broadcast(Zaq.PubSub, "addons:updated", :addons_updated)

      html = render(view)

      assert html =~ "Add-ons Active"
      assert html =~ "lic_broadcast_001"
    end
  end

  describe "public helpers" do
    test "public upload_entry_error messages are mapped" do
      assert AddonsLive.upload_entry_error(:too_large) == "File is too large."

      assert AddonsLive.upload_entry_error(:not_accepted) ==
               "Only .zaq-license add-on packages are accepted."

      assert AddonsLive.upload_entry_error(:too_many_files) == "Only one file at a time."
      assert AddonsLive.upload_entry_error(:unknown) == "Upload failed."
    end
  end

  describe "package loader error reasons" do
    test "PackageLoader error reasons render exact upload messages", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      cases = [
        {"expired.zaq-license",
         build_license_archive_bytes!(tmp_dir,
           payload: %{
             "license_key" => "lic_expired",
             "features" => [],
             "expires_at" => DateTime.utc_now() |> DateTime.add(-2, :day) |> DateTime.to_iso8601()
           },
           module_name: "Elixir.LicenseManager.Paid.Expired#{System.unique_integer([:positive])}",
           expiry_module: true
         ), "This add-on package has expired."},
        {"missing_dat.zaq-license",
         build_archive_bytes!(tmp_dir, [{~c"modules/Any.beam.enc", "x"}]),
         "Invalid add-on package: missing package data."},
        {"invalid_format.zaq-license",
         build_archive_bytes!(tmp_dir, [{~c"license.dat", "only-one-part"}]),
         "Invalid add-on package format."},
        {"invalid_json.zaq-license", build_signed_payload_archive_bytes!(tmp_dir, "not-json"),
         "Invalid add-on package: malformed payload."},
        {"missing_exp.zaq-license",
         build_license_archive_bytes!(tmp_dir,
           payload: %{
             "license_key" => "lic_missing_exp",
             "features" => []
           },
           module_name:
             "Elixir.LicenseManager.Paid.MissingExp#{System.unique_integer([:positive])}",
           expiry_module: true
         ), "Failed to load add-on package: :missing_expires_at"}
      ]

      Enum.each(cases, fn {filename, archive_bytes, expected_message} ->
        {:ok, view, _html} = live(conn, ~p"/bo/addons")

        copied_path = uploaded_license_path(filename)
        on_exit(fn -> File.rm(copied_path) end)

        upload =
          file_input(view, "form[phx-submit='upload_addon']", :addon_package, [
            %{name: filename, content: archive_bytes, type: "application/octet-stream"}
          ])

        assert render_upload(upload, filename)

        capture_log(fn ->
          view
          |> form("form[phx-submit='upload_addon']")
          |> render_submit()
        end)

        html = render(view)
        assert html =~ expected_message
      end)
    end
  end

  describe "expired add-on package" do
    setup do
      FeatureStore.store(
        %{
          "license_key" => "lic_expired_456",
          "company_name" => "Expired Corp",
          "expires_at" => DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.to_iso8601(),
          "features" => [
            %{
              "name" => "Ontology Management",
              "description" => "Knowledge graph",
              "module_tags" => []
            }
          ]
        },
        []
      )

      on_exit(fn -> FeatureStore.clear() end)
      :ok
    end

    test "shows red days left for expired add-on package", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/addons")
      assert html =~ "text-red-600"
    end
  end

  describe "date formatting and time-left branches" do
    setup do
      on_exit(fn -> FeatureStore.clear() end)
      :ok
    end

    test "renders nil expiration with neutral class", %{conn: conn} do
      store_addon(nil)

      {:ok, _view, html} = live(conn, ~p"/bo/addons")

      assert html =~ "—"
      assert html =~ ~r/Time Left.*?text-black/s
    end

    test "renders invalid expiration string with neutral class", %{conn: conn} do
      store_addon("not-a-date")

      {:ok, _view, html} = live(conn, ~p"/bo/addons")

      assert html =~ "not-a-date"
      assert html =~ ~r/Time Left.*?text-black/s
    end

    test "renders amber class for medium-term expiration", %{conn: conn} do
      store_addon(DateTime.utc_now() |> DateTime.add(45, :day) |> DateTime.to_iso8601())

      {:ok, _view, html} = live(conn, ~p"/bo/addons")

      assert html =~ ~r/Time Left.*?text-amber-600/s
    end

    test "renders green class for long-term expiration", %{conn: conn} do
      store_addon(DateTime.utc_now() |> DateTime.add(140, :day) |> DateTime.to_iso8601())

      {:ok, _view, html} = live(conn, ~p"/bo/addons")

      assert html =~ ~r/Time Left.*?text-emerald-600/s
    end
  end

  defp store_addon(expires_at) do
    FeatureStore.store(
      %{
        "license_key" => "lic_date_coverage",
        "company" => %{"name" => "Date Corp"},
        "expires_at" => expires_at,
        "features" => [
          %{
            "name" => "Ontology Management",
            "description" => "Knowledge graph management",
            "module_tags" => ["Elixir.Zaq.Paid.Ontology"]
          }
        ]
      },
      [Zaq.Paid.Ontology]
    )
  end

  defp build_signed_payload_archive_bytes!(tmp_dir, payload) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])

    build_archive_bytes!(tmp_dir, [
      {~c"license.dat", Base.encode64(payload) <> "." <> Base.encode64(signature)},
      {~c"public.key", Base.encode64(pub)}
    ])
  end

  defp build_license_archive_bytes!(tmp_dir, opts) do
    payload = Keyword.fetch!(opts, :payload) |> Jason.encode!()
    module_name = Keyword.fetch!(opts, :module_name)
    expiry_module = Keyword.get(opts, :expiry_module, false)

    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])

    module_entry =
      if expiry_module do
        expiry_check_module_entry!(payload)
      else
        generic_module_entry!(module_name, payload)
      end

    build_archive_bytes!(tmp_dir, [
      {~c"license.dat", Base.encode64(payload) <> "." <> Base.encode64(signature)},
      {~c"public.key", Base.encode64(pub)},
      module_entry
    ])
  end

  defp build_archive_bytes!(tmp_dir, entries) do
    archive_path = Path.join(tmp_dir, "archive_#{System.unique_integer([:positive])}.zaq-license")
    :ok = :erl_tar.create(String.to_charlist(archive_path), entries, [:compressed])
    File.read!(archive_path)
  end

  defp expiry_check_module_entry!(payload) do
    module_source = """
    defmodule LicenseManager.Paid.License do
      def check_expiry(addon_data) do
        case Map.fetch(addon_data, "expires_at") do
          :error -> {:error, :missing_expires_at}

          {:ok, expires_at_str} ->
            with {:ok, expires_at, _} <- DateTime.from_iso8601(expires_at_str),
                 :gt <- DateTime.compare(expires_at, DateTime.utc_now()) do
              :ok
            else
              _ -> {:error, :license_expired}
            end
        end
      end
    end
    """

    [{_module, beam_binary}] = Code.compile_string(module_source)
    encrypt_module_entry!("Elixir.LicenseManager.Paid.License", beam_binary, payload)
  end

  defp generic_module_entry!(module_name, payload) do
    module_source = """
    defmodule #{module_name} do
      def enabled?, do: true
    end
    """

    [{_module, beam_binary}] = Code.compile_string(module_source)
    encrypt_module_entry!(module_name, beam_binary, payload)
  end

  defp encrypt_module_entry!(module_name, beam_binary, payload) do
    key = BeamDecryptor.derive_key(payload)
    nonce = <<System.unique_integer([:positive])::96>>

    {encrypted, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, beam_binary, "zaq-beam-v1", 16, true)

    {String.to_charlist("modules/#{module_name}.beam.enc"), nonce <> tag <> encrypted}
  end

  defp uploaded_license_path(filename) do
    Application.app_dir(:zaq, "priv/licenses/#{filename}")
  end

  defp fully_enabled_features do
    [
      "ontology",
      "knowledge_gap",
      "knowledge_update",
      "document_update"
    ]
    |> Enum.map(fn name ->
      %{
        "name" => name,
        "description" => "Included in enterprise plan",
        "module_tags" => []
      }
    end)
  end
end
