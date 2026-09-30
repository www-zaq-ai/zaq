defmodule Zaq.Agent.Tools.Web.BrowsingTest do
  # async: false — mutates global env vars (AGENT_BROWSER_BIN,
  # AGENT_BROWSER_ALLOWED_DOMAINS, AGENT_BROWSER_TIMEOUT_MS); parallel tests
  # would collide on them.
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  alias Jido.Action.Schema
  alias Zaq.Agent.Tools.Web.Browsing
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.System.Command

  setup do
    assert {:ok, _} = Zaq.System.save_web_browsing_config(%{})
    prev_bin = System.get_env("AGENT_BROWSER_BIN")
    prev_domains = System.get_env("AGENT_BROWSER_ALLOWED_DOMAINS")
    prev_timeout = System.get_env("AGENT_BROWSER_TIMEOUT_MS")

    on_exit(fn ->
      restore("AGENT_BROWSER_BIN", prev_bin)
      restore("AGENT_BROWSER_ALLOWED_DOMAINS", prev_domains)
      restore("AGENT_BROWSER_TIMEOUT_MS", prev_timeout)
    end)

    :ok
  end

  defp restore(var, nil), do: System.delete_env(var)
  defp restore(var, value), do: System.put_env(var, value)

  defp fake_bin(body) do
    path =
      Path.join(System.tmp_dir!(), "agent_browser_fake_#{System.unique_integer([:positive])}")

    File.write!(path, body)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf(path) end)
    System.put_env("AGENT_BROWSER_BIN", path)
    path
  end

  # Echoes each received argument on its own line so tests can assert the exact
  # argv the CLI was invoked with, end-to-end through the Port.
  defp echo_args_bin, do: fake_bin(~s(#!/bin/sh\nfor a in "$@"; do echo "$a"; done\n))

  defp argv({:ok, %{output: output}}), do: String.split(output, "\n", trim: true)

  defp stub_screenshot_destination do
    {:ok, folder} = Provenance.seal(%Record{id: "folder-1", kind: :folder, name: "example.org"})

    Mox.stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      case event.opts[:action] do
        :system_config_get_web_browsing_config ->
          %{
            event
            | response:
                {:ok,
                 %Zaq.System.WebBrowsingConfig{
                   provider: "google_drive",
                   config_id: 12,
                   folder_id: "parent-17"
                 }}
          }

        :data_source_list_files ->
          %{event | response: {:ok, %{records: [folder]}}}

        other ->
          flunk("unexpected action #{inspect(other)}")
      end
    end)

    %{node_router: Zaq.NodeRouterMock}
  end

  describe "schema/0 and output_schema/0" do
    test "declares Zoi schemas and excludes model-controlled policy and screenshot path" do
      assert Schema.schema_type(Browsing.schema()) == :zoi
      assert Schema.schema_type(Browsing.output_schema()) == :zoi
      assert :ok = Schema.validate_config_schema(Browsing.schema())
      assert :ok = Schema.validate_config_schema(Browsing.output_schema())

      input = Schema.to_json_schema(Browsing.schema())
      assert "screenshot" in get_in(input, [:properties, :command, :enum])
      refute Map.has_key?(input.properties, :allowed_domains)
      refute Map.has_key?(input.properties, :path)

      output = Schema.to_json_schema(Browsing.output_schema())
      assert Map.has_key?(output.properties, :record)
      refute Map.has_key?(output.properties, :document_id)
    end

    test "validates command-specific inputs, positive timeout, and Record output" do
      assert {:error, _} = Zoi.parse(Browsing.schema(), %{command: "eval"})
      assert {:error, _} = Zoi.parse(Browsing.schema(), %{command: "fill", selector: "@e1"})
      assert {:error, _} = Zoi.parse(Browsing.schema(), %{command: "snapshot", timeout_ms: 0})

      assert {:ok, %{command: "snapshot", timeout_ms: 1234}} =
               Zoi.parse(Browsing.schema(), %{command: "snapshot", timeout_ms: 1234})

      assert {:ok, _} = Zoi.parse(Browsing.schema(), %{command: "open"})

      assert {:error, _} =
               Zoi.parse(Browsing.output_schema(), %{
                 command: "screenshot",
                 output: "Screenshot saved"
               })

      assert {:error, _} =
               Zoi.parse(Browsing.output_schema(), %{
                 command: "screenshot",
                 output: "Screenshot saved",
                 record: %Record{id: "unsigned", kind: :file}
               })

      assert {:ok, _} =
               Zoi.parse(Browsing.output_schema(), %{command: "snapshot", output: "page"})

      {:ok, record} = Provenance.seal(%Record{id: "capture-1", kind: :file})

      assert {:ok, %{record: %Record{id: "capture-1"}}} =
               Zoi.parse(Browsing.output_schema(), %{
                 command: "screenshot",
                 output: "Screenshot saved",
                 record: record |> Jason.encode!() |> Jason.decode!()
               })

      assert {:error, _} =
               Zoi.parse(Browsing.output_schema(), %{
                 command: "screenshot",
                 output: "Screenshot saved",
                 record: %{record | id: "tampered"}
               })
    end

    test "validated execution rejects unknown or malformed input before spawning" do
      System.put_env("AGENT_BROWSER_BIN", "/nonexistent/should-not-run")

      for params <- [
            %{command: "eval"},
            %{command: "fill", selector: "@e1"},
            %{command: "snapshot", timeout_ms: -1},
            %{command: "snapshot", allowed_domains: "attacker.test"},
            %{command: "screenshot", path: "/tmp/attacker.png"}
          ] do
        assert {:error, _} = Jido.Exec.run(Browsing, params, %{})
      end
    end

    test "declares a react per-tool timeout above its per-command self-timeout" do
      # Per-command self-timeout (shared default) + 30s headroom. Derived from
      # Command.default_timeout_ms/0 so this doesn't break if that default moves.
      assert Browsing.tool_timeout_ms() == Command.default_timeout_ms() + 30_000
    end
  end

  describe "run/2 argument building" do
    setup do
      echo_args_bin()
      :ok
    end

    test "open passes the url and a session derived from the run id" do
      args = argv(Browsing.run(%{command: "open", url: "https://acme.test"}, %{run_id: "r1"}))

      # subcommand + positional url come first, in order (agent-browser expects
      # `subcommand [args...] [flags...]`), then the session flag.
      assert Enum.take(args, 2) == ["open", "https://acme.test"]
      assert "--session" in args
      assert "r1" in args
    end

    test "open without a url still launches" do
      args = argv(Browsing.run(%{command: "open"}, %{}))
      assert "open" in args
      refute Enum.any?(args, &String.starts_with?(&1, "http"))
    end

    test "snapshot requests the ref-annotated tree and default session" do
      args = argv(Browsing.run(%{command: "snapshot"}, %{}))
      assert Enum.take(args, 2) == ["snapshot", "-i"]
      # default session when no run id present
      assert "zaq" in args
    end

    test "fill passes selector and text as separate args" do
      args =
        argv(
          Browsing.run(%{command: "fill", selector: "@e2", text: "me@acme.test"}, %{run_id: "r"})
        )

      assert Enum.take(args, 3) == ["fill", "@e2", "me@acme.test"]
    end

    test "press passes the key (form submit via Enter)" do
      args = argv(Browsing.run(%{command: "press", key: "Enter"}, %{}))
      assert Enum.take(args, 2) == ["press", "Enter"]
    end

    test "select passes selector and value" do
      args = argv(Browsing.run(%{command: "select", selector: "#country", value: "FR"}, %{}))
      assert ["select", "#country", "FR" | _] = args
    end

    test "an explicit session param overrides the context id" do
      args = argv(Browsing.run(%{command: "snapshot", session: "custom"}, %{run_id: "r1"}))
      assert "custom" in args
      refute "r1" in args
    end

    test "model-supplied domains cannot override administrator policy" do
      assert {:ok, _} =
               Zaq.System.save_web_browsing_config(%{allowed_domains: "acme.test"})

      args =
        argv(
          Browsing.run(
            %{command: "open", url: "https://acme.test", allowed_domains: "attacker.test"},
            %{}
          )
        )

      assert "--allowed-domains" in args
      assert "acme.test" in args
      refute "attacker.test" in args
    end

    test "administrator policy takes precedence over the legacy environment variable" do
      System.put_env("AGENT_BROWSER_ALLOWED_DOMAINS", "env.test")
      assert {:ok, _} = Zaq.System.save_web_browsing_config(%{allowed_domains: "admin.test"})
      args = argv(Browsing.run(%{command: "snapshot"}, %{}))
      assert "--allowed-domains" in args
      assert "admin.test" in args
      refute "env.test" in args
    end

    test "blank policy explicitly overrides inherited domain restriction" do
      System.put_env("AGENT_BROWSER_ALLOWED_DOMAINS", "env.test")
      args = argv(Browsing.run(%{command: "snapshot"}, %{}))
      assert "--allowed-domains" in args
      refute "env.test" in args
    end

    test "blank policy is passed as an actual empty argv value" do
      fake_bin(~s(#!/bin/sh\nfor a in "$@"; do printf '[%s]\\n' "$a"; done\n))
      System.put_env("AGENT_BROWSER_ALLOWED_DOMAINS", "env.test")

      assert {:ok, %{output: output}} = Browsing.run(%{command: "snapshot"}, %{})
      assert output =~ "[--allowed-domains]\n[]"
    end

    test "wait passes a selector-or-milliseconds value" do
      args = argv(Browsing.run(%{command: "wait", wait_for: "3000"}, %{}))
      assert ["wait", "3000" | _] = args
    end

    test "text maps to the CLI `get text <selector>`" do
      args = argv(Browsing.run(%{command: "text", selector: "body"}, %{}))
      assert ["get", "text", "body" | _] = args
    end

    test "uncheck passes the selector" do
      args = argv(Browsing.run(%{command: "uncheck", selector: "#agree"}, %{}))
      assert ["uncheck", "#agree" | _] = args
    end

    test "url maps to the CLI `get url` (for verifying navigation)" do
      args = argv(Browsing.run(%{command: "url"}, %{}))
      assert ["get", "url" | _] = args
    end

    test "scrollintoview passes the selector" do
      args = argv(Browsing.run(%{command: "scrollintoview", selector: "@e5"}, %{}))
      assert ["scrollintoview", "@e5" | _] = args
    end

    test "type passes selector and text" do
      args =
        argv(Browsing.run(%{command: "type", selector: "@e3", text: "hello world"}, %{}))

      assert ["type", "@e3", "hello world" | _] = args
    end

    test "check passes the selector" do
      args = argv(Browsing.run(%{command: "check", selector: "#agree"}, %{}))
      assert ["check", "#agree" | _] = args
    end

    test "close builds the close command" do
      args = argv(Browsing.run(%{command: "close"}, %{}))
      assert "close" in args
    end

    test "an integer run id is stringified into the session" do
      args = argv(Browsing.run(%{command: "snapshot"}, %{run_id: 42}))
      assert "42" in args
    end

    test "a string-keyed run id in the context is honored" do
      args = argv(Browsing.run(%{command: "snapshot"}, %{"run_id" => "str-key"}))
      assert "str-key" in args
    end

    test "form-value text with shell metacharacters is passed intact" do
      injection = "a'; drop table; --"
      args = argv(Browsing.run(%{command: "fill", selector: "@e2", text: injection}, %{}))
      assert injection in args
    end
  end

  describe "run/2 validation" do
    test "captures the current redirected page to its hostname folder and never returns bytes or local path" do
      fake_bin(~S(#!/bin/sh
if [ "$1" = "get" ]; then
  printf 'https://final.example.org/Reports/Q3?secret=yes\n'
elif [ "$1" = "screenshot" ]; then
  printf '\211PNG\r\n\032\nDATA' > "$2"
  echo "screenshot saved $2"
fi
))

      {:ok, folder} =
        Provenance.seal(%Record{
          id: "canonical-folder-99",
          kind: :folder,
          name: "final.example.org"
        })

      {:ok, document} = Provenance.seal(%Record{id: "saved-100", kind: :file})
      test_pid = self()

      Mox.stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
        case event.opts[:action] do
          :system_config_get_web_browsing_config ->
            %{
              event
              | response:
                  {:ok,
                   %Zaq.System.WebBrowsingConfig{
                     provider: "google_drive",
                     config_id: 12,
                     folder_id: "parent-17",
                     allowed_domains: ""
                   }}
            }

          :data_source_list_files ->
            %{event | response: {:ok, %{records: [folder]}}}

          :data_source_create_file ->
            params = event.request.params
            send(test_pid, {:screenshot_upload, params, event.actor})
            %{event | response: {:ok, %{record: document}}}

          other ->
            flunk("unexpected action #{inspect(other)}")
        end
      end)

      assert {:ok, %{record: %Record{id: "saved-100"} = saved, output: "Screenshot saved"}} =
               Jido.Exec.run(Browsing, %{command: "screenshot"}, %{
                 node_router: Zaq.NodeRouterMock
               })

      assert saved.provenance_ref == document.provenance_ref

      assert_received {:screenshot_upload,
                       %{
                         "parent_id" => "canonical-folder-99",
                         "config_id" => "12",
                         "content" => content,
                         "name" => name,
                         "mime_type" => "image/png"
                       }, _actor}

      assert content == <<137, 80, 78, 71, 13, 10, 26, 10, 68, 65, 84, 65>>
      assert name =~ ~r/^reports-q3--\d{8}T\d{9}Z--[a-f0-9]{24}\.png$/
      refute name =~ "secret"

      assert {:ok, %{record: %Record{id: "saved-100"}}} =
               Browsing.run(%{command: "screenshot"}, %{node_router: Zaq.NodeRouterMock})

      assert_received {:screenshot_upload, %{"name" => second_name}, _actor}
      refute second_name == name
      refute Path.wildcard(Path.join(System.tmp_dir!(), "zaq-browser-*.png")) |> Enum.any?()
    end

    test "screenshot without destination never invokes the CLI" do
      System.put_env("AGENT_BROWSER_BIN", "/nonexistent/should-not-run")

      assert {:error, "Screenshot destination is not configured"} =
               Browsing.run(%{command: "screenshot"}, %{})
    end

    test "rejects a non-web current page without creating a folder or screenshot" do
      fake_bin(~S(#!/bin/sh
if [ "$1" = "get" ]; then echo 'about:blank'; else exit 14; fi
))

      Mox.stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
        assert event.opts[:action] == :system_config_get_web_browsing_config

        %{
          event
          | response:
              {:ok,
               %Zaq.System.WebBrowsingConfig{
                 provider: "disk",
                 config_id: 2,
                 folder_path: "volume-a/Captures"
               }}
        }
      end)

      assert {:error, "Screenshot requires a current HTTP(S) page"} =
               Browsing.run(%{command: "screenshot"}, %{node_router: Zaq.NodeRouterMock})
    end

    test "rejects an HTTP scheme without a host without listing or capturing" do
      fake_bin(~S(#!/bin/sh
if [ "$1" = "get" ]; then echo 'https:relative'; else exit 14; fi
))
      before = Path.wildcard(Path.join(System.tmp_dir!(), "zaq-browser-*.png"))

      Mox.stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
        assert event.opts[:action] == :system_config_get_web_browsing_config

        %{
          event
          | response:
              {:ok,
               %Zaq.System.WebBrowsingConfig{
                 provider: "disk",
                 config_id: 2,
                 folder_path: "volume-a/Captures"
               }}
        }
      end)

      assert {:error, "Screenshot requires a current HTTP(S) page"} =
               Browsing.run(%{command: "screenshot"}, %{node_router: Zaq.NodeRouterMock})

      assert Path.wildcard(Path.join(System.tmp_dir!(), "zaq-browser-*.png")) == before
    end

    test "fails closed when the destination folder cannot be listed" do
      fake_bin(~S(#!/bin/sh
if [ "$1" = "get" ]; then echo 'https://example.org/'; else exit 14; fi
))
      before = Path.wildcard(Path.join(System.tmp_dir!(), "zaq-browser-*.png"))

      Mox.stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
        case event.opts[:action] do
          :system_config_get_web_browsing_config ->
            %{
              event
              | response:
                  {:ok,
                   %Zaq.System.WebBrowsingConfig{
                     provider: "disk",
                     config_id: 2,
                     folder_path: "volume-a/Captures"
                   }}
            }

          :data_source_list_files ->
            assert event.request.provider == "disk"
            assert event.request.params["config_id"] == 2
            assert event.request.params["filters"]["parent"] == "volume-a/Captures"
            %{event | response: {:error, :unavailable}}

          other ->
            flunk("unexpected action #{inspect(other)}")
        end
      end)

      assert {:error, "Screenshot destination folder could not be listed"} =
               Browsing.run(%{command: "screenshot"}, %{node_router: Zaq.NodeRouterMock})

      assert Path.wildcard(Path.join(System.tmp_dir!(), "zaq-browser-*.png")) == before
    end

    test "recovers a concurrent folder creation from the canonical second listing" do
      fake_bin(~S(#!/bin/sh
if [ "$1" = "get" ]; then
  echo 'https://example.org/'
elif [ "$1" = "screenshot" ]; then
  printf '\211PNG\r\n\032\nDATA' > "$2"
else
  exit 14
fi
))

      {:ok, raced_folder} =
        Provenance.seal(%Record{id: "race-folder-42", kind: :folder, name: "example.org"})

      {:ok, saved_record} = Provenance.seal(%Record{id: "saved-race-43", kind: :file})
      counter = start_supervised!({Agent, fn -> 0 end})
      test_pid = self()

      Mox.stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
        case event.opts[:action] do
          :system_config_get_web_browsing_config ->
            %{
              event
              | response:
                  {:ok,
                   %Zaq.System.WebBrowsingConfig{
                     provider: "google_drive",
                     config_id: 12,
                     folder_id: "parent-17"
                   }}
            }

          :data_source_list_files ->
            params = event.request.params
            assert event.request.provider == "google_drive"
            assert params["config_id"] == 12
            assert params["filters"]["parent"] == "parent-17"

            case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
              0 ->
                send(test_pid, :race_initial_listing)
                %{event | response: {:ok, %{records: []}}}

              1 ->
                send(test_pid, :race_relisting)
                %{event | response: {:ok, %{records: [raced_folder]}}}

              n ->
                flunk("unexpected listing number #{n + 1}")
            end

          :data_source_create_file ->
            params = event.request.params

            case params["kind"] do
              "folder" ->
                send(test_pid, {:race_folder_create, params})
                assert params["parent_id"] == "parent-17"
                assert params["name"] == "example.org"
                %{event | response: {:error, :already_exists}}

              nil ->
                send(test_pid, {:race_upload, params})
                %{event | response: {:ok, %{record: saved_record}}}

              kind ->
                flunk("unexpected create kind #{inspect(kind)}")
            end

          other ->
            flunk("unexpected action #{inspect(other)}")
        end
      end)

      before = Path.wildcard(Path.join(System.tmp_dir!(), "zaq-browser-*.png"))

      assert {:ok, %{record: %Record{id: "saved-race-43"}, output: "Screenshot saved"} = result} =
               Jido.Exec.run(Browsing, %{command: "screenshot"}, %{
                 node_router: Zaq.NodeRouterMock
               })

      assert result == %{command: "screenshot", record: saved_record, output: "Screenshot saved"}
      assert_received :race_initial_listing
      assert_received {:race_folder_create, %{"kind" => "folder"}}
      assert_received :race_relisting

      assert_received {:race_upload,
                       %{
                         "parent_id" => "race-folder-42",
                         "content" => content,
                         "name" => name,
                         "mime_type" => "image/png"
                       }}

      assert content == <<137, 80, 78, 71, 13, 10, 26, 10, 68, 65, 84, 65>>
      assert name =~ ~r/^home--\d{8}T\d{9}Z--[a-f0-9]{24}\.png$/
      response = Jason.encode!(result)
      refute response =~ Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10, 68, 65, 84, 65>>)
      refute response =~ <<137, 80, 78, 71, 13, 10, 26, 10, 68, 65, 84, 65>>
      refute response =~ System.tmp_dir!()
      refute_received :race_initial_listing
      refute_received :race_relisting
      refute_received {:race_folder_create, _}
      refute_received {:race_upload, _}
      assert Agent.get(counter, & &1) == 2
      assert Path.wildcard(Path.join(System.tmp_dir!(), "zaq-browser-*.png")) == before
    end

    test "does not accept a same-name file as the concurrently created folder" do
      fake_bin(~S(#!/bin/sh
if [ "$1" = "get" ]; then echo 'https://example.org/'; else exit 14; fi
))

      {:ok, same_name_file} =
        Provenance.seal(%Record{id: "not-a-folder", kind: :file, name: "example.org"})

      counter = start_supervised!({Agent, fn -> 0 end})
      before = Path.wildcard(Path.join(System.tmp_dir!(), "zaq-browser-*.png"))

      Mox.stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
        case event.opts[:action] do
          :system_config_get_web_browsing_config ->
            %{
              event
              | response:
                  {:ok,
                   %Zaq.System.WebBrowsingConfig{
                     provider: "google_drive",
                     config_id: 12,
                     folder_id: "parent-17"
                   }}
            }

          :data_source_list_files ->
            assert event.request.provider == "google_drive"
            assert event.request.params["config_id"] == 12
            assert event.request.params["filters"]["parent"] == "parent-17"

            case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
              0 -> %{event | response: {:ok, %{records: []}}}
              1 -> %{event | response: {:ok, %{records: [same_name_file]}}}
              n -> flunk("unexpected listing number #{n + 1}")
            end

          :data_source_create_file ->
            assert event.request.params["kind"] == "folder"
            assert event.request.provider == "google_drive"
            assert event.request.params["config_id"] == "12"
            assert event.request.params["parent_id"] == "parent-17"
            assert event.request.params["name"] == "example.org"
            %{event | response: {:error, :already_exists}}

          other ->
            flunk("unexpected action #{inspect(other)}")
        end
      end)

      assert {:error, "Screenshot destination folder could not be created"} =
               Browsing.run(%{command: "screenshot"}, %{node_router: Zaq.NodeRouterMock})

      assert Agent.get(counter, & &1) == 2
      assert Path.wildcard(Path.join(System.tmp_dir!(), "zaq-browser-*.png")) == before
    end

    test "missing PNG fails without reporting storage success and cleans its owned file" do
      fake_bin(~S(#!/bin/sh
if [ "$1" = "get" ]; then echo 'https://example.org/'; else echo 'ok'; fi
))

      {:ok, folder} = Provenance.seal(%Record{id: "folder-1", kind: :folder, name: "example.org"})

      Mox.stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
        case event.opts[:action] do
          :system_config_get_web_browsing_config ->
            %{
              event
              | response:
                  {:ok,
                   %Zaq.System.WebBrowsingConfig{
                     provider: "google_drive",
                     config_id: 12,
                     folder_id: "parent-17"
                   }}
            }

          :data_source_list_files ->
            %{event | response: {:ok, %{records: [folder]}}}

          other ->
            flunk("unexpected action #{inspect(other)}")
        end
      end)

      assert {:error, "Screenshot file missing, too large or not a valid PNG"} =
               Browsing.run(%{command: "screenshot"}, %{node_router: Zaq.NodeRouterMock})

      assert Path.wildcard(Path.join(System.tmp_dir!(), "zaq-browser-*.png")) == []
    end

    test "oversized PNG is rejected before upload and its temporary file is removed" do
      fake_bin(~S(#!/bin/sh
if [ "$1" = "get" ]; then
  echo 'https://example.org/'
elif [ "$1" = "screenshot" ]; then
  printf '\211PNG\r\n\032\n' > "$2"
  dd if=/dev/zero bs=1048576 count=11 >> "$2" 2>/dev/null
fi
))

      {:ok, folder} = Provenance.seal(%Record{id: "folder-1", kind: :folder, name: "example.org"})

      Mox.stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
        case event.opts[:action] do
          :system_config_get_web_browsing_config ->
            %{
              event
              | response:
                  {:ok,
                   %Zaq.System.WebBrowsingConfig{
                     provider: "google_drive",
                     config_id: 12,
                     folder_id: "parent-17"
                   }}
            }

          :data_source_list_files ->
            %{event | response: {:ok, %{records: [folder]}}}

          other ->
            flunk("unexpected action #{inspect(other)}")
        end
      end)

      assert {:error, "Screenshot file missing, too large or not a valid PNG"} =
               Browsing.run(%{command: "screenshot"}, %{node_router: Zaq.NodeRouterMock})

      assert Path.wildcard(Path.join(System.tmp_dir!(), "zaq-browser-*.png")) == []
    end

    test "incomplete folder listing stops capture rather than creating a duplicate" do
      fake_bin(~S(#!/bin/sh
if [ "$1" = "get" ]; then echo 'https://example.org/'; else exit 37; fi
))

      Mox.stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
        case event.opts[:action] do
          :system_config_get_web_browsing_config ->
            %{
              event
              | response:
                  {:ok,
                   %Zaq.System.WebBrowsingConfig{
                     provider: "google_drive",
                     config_id: 12,
                     folder_id: "parent-17"
                   }}
            }

          :data_source_list_files ->
            %{
              event
              | response: {:ok, %{records: [], pagination: %{has_more?: true, cursor: "next"}}}
            }

          other ->
            flunk("unexpected action #{inspect(other)}")
        end
      end)

      assert {:error, "Screenshot destination folder listing is incomplete"} =
               Browsing.run(%{command: "screenshot"}, %{node_router: Zaq.NodeRouterMock})
    end

    test "creates a hostname folder, uses its canonical ID and does not claim success on upload failure" do
      fake_bin(~S(#!/bin/sh
if [ "$1" = "get" ]; then
  echo 'https://example.org/'
elif [ "$1" = "screenshot" ]; then
  printf '\211PNG\r\n\032\nDATA' > "$2"
fi
))

      {:ok, folder} =
        Provenance.seal(%Record{id: "created-folder-77", kind: :folder, name: "example.org"})

      test_pid = self()

      Mox.stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
        case event.opts[:action] do
          :system_config_get_web_browsing_config ->
            %{
              event
              | response:
                  {:ok,
                   %Zaq.System.WebBrowsingConfig{
                     provider: "google_drive",
                     config_id: 12,
                     folder_id: "root-folder"
                   }}
            }

          :data_source_list_files ->
            %{event | response: {:ok, %{records: []}}}

          :data_source_create_file ->
            params = event.request.params
            send(test_pid, {:screenshot_create, params})

            response =
              if params["kind"] == "folder",
                do: {:ok, %{record: folder}},
                else: {:error, :permission_denied}

            %{event | response: response}
        end
      end)

      assert {:error, "Screenshot could not be saved to the configured destination"} =
               Browsing.run(%{command: "screenshot"}, %{node_router: Zaq.NodeRouterMock})

      assert_received {:screenshot_create,
                       %{
                         "parent_id" => "root-folder",
                         "name" => "example.org",
                         "kind" => "folder"
                       }}

      assert_received {:screenshot_create, %{"parent_id" => "created-folder-77", "name" => name}}
      assert name =~ ~r/^home--.*\.png$/
      assert Path.wildcard(Path.join(System.tmp_dir!(), "zaq-browser-*.png")) == []
    end

    test "fails closed when the Engine cannot supply an administrator policy" do
      Mox.stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
        %Zaq.Event{event | response: {:error, :unavailable}}
      end)

      System.put_env("AGENT_BROWSER_BIN", "/nonexistent/should-not-run")

      assert {:error, "Web browsing policy unavailable; browser command not executed"} =
               Browsing.run(%{command: "snapshot"}, %{node_router: Zaq.NodeRouterMock})
    end

    test "rejects a command outside the allowlist without spawning" do
      # No fake bin set — a spawn would fail with :enoent; validation must short-circuit.
      System.put_env("AGENT_BROWSER_BIN", "/nonexistent/should-not-run")

      assert {:error, message} = Browsing.run(%{command: "eval"}, %{})
      assert message =~ "unsupported command: eval"
      assert message =~ "Allowed:"
    end

    test "reports a missing required argument" do
      System.put_env("AGENT_BROWSER_BIN", "/nonexistent/should-not-run")

      assert {:error, "fill requires: text"} =
               Browsing.run(%{command: "fill", selector: "@e2"}, %{})

      assert {:error, "click requires: selector"} = Browsing.run(%{command: "click"}, %{})
    end

    test "reports each missing required argument per command" do
      System.put_env("AGENT_BROWSER_BIN", "/nonexistent/should-not-run")

      assert {:error, "type requires: text"} =
               Browsing.run(%{command: "type", selector: "@e2"}, %{})

      assert {:error, "select requires: value"} =
               Browsing.run(%{command: "select", selector: "#c"}, %{})

      assert {:error, "press requires: key"} = Browsing.run(%{command: "press"}, %{})
      assert {:error, "check requires: selector"} = Browsing.run(%{command: "check"}, %{})
      assert {:error, "wait requires: wait_for"} = Browsing.run(%{command: "wait"}, %{})
      assert {:error, "text requires: selector"} = Browsing.run(%{command: "text"}, %{})

      assert {:error, "scrollintoview requires: selector"} =
               Browsing.run(%{command: "scrollintoview"}, %{})
    end

    test "a blank string argument is treated as missing" do
      System.put_env("AGENT_BROWSER_BIN", "/nonexistent/should-not-run")

      assert {:error, "click requires: selector"} =
               Browsing.run(%{command: "click", selector: "   "}, %{})
    end
  end

  describe "run/2 error mapping" do
    test "maps a binary removed after reading the page URL to the screenshot install hint" do
      path = fake_bin(~S(#!/bin/sh
if [ "$1" = "get" ]; then
  echo 'https://example.org/'
  rm -f "$0"
else
  exit 14
fi
))
      before = Path.wildcard(Path.join(System.tmp_dir!(), "zaq-browser-*.png"))

      assert {:error, "Screenshot capture failed: agent-browser not installed"} =
               Browsing.run(%{command: "screenshot"}, stub_screenshot_destination())

      refute File.exists?(path)
      assert Path.wildcard(Path.join(System.tmp_dir!(), "zaq-browser-*.png")) == before
    end

    test "screenshot CLI failure retains bounded diagnostics without leaking local path or page URL" do
      fake_bin(~S(#!/bin/sh
if [ "$1" = "get" ]; then
  echo 'https://example.org/page?secret=do-not-log'
else
  echo "Capture denied at $2 for https://example.org/private?token=do-not-log" >&2
  exit 42
fi
))

      assert {:error, message} =
               Browsing.run(%{command: "screenshot"}, stub_screenshot_destination())

      assert message =~ "Screenshot capture failed (exit 42)"
      assert message =~ "Capture denied"
      refute message =~ "do-not-log"
      refute message =~ "example.org"
      refute message =~ System.tmp_dir!()
      assert String.length(message) <= 400
      assert Path.wildcard(Path.join(System.tmp_dir!(), "zaq-browser-*.png")) == []
    end

    test "screenshot timeout is distinguished from a CLI failure" do
      fake_bin(~S(#!/bin/sh
if [ "$1" = "get" ]; then echo 'https://example.org/'; else sleep 5; fi
))

      assert {:error, "Screenshot capture timed out"} =
               Browsing.run(
                 %{command: "screenshot", timeout_ms: 800},
                 stub_screenshot_destination()
               )
    end

    test "maps a CLI non-zero exit to a descriptive error" do
      fake_bin("#!/bin/sh\necho 'element not found'\nexit 4\n")

      assert {:error, message} = Browsing.run(%{command: "click", selector: "@e9"}, %{})
      assert message =~ "click failed (exit 4)"
      assert message =~ "element not found"
    end

    test "maps a missing binary to an install hint" do
      System.put_env("AGENT_BROWSER_BIN", "/nonexistent/agent-browser")

      assert {:error, message} = Browsing.run(%{command: "snapshot"}, %{})
      assert message =~ "agent-browser not installed"
    end

    test "maps a timeout" do
      fake_bin(~s(#!/bin/sh\nsleep 5\n))

      assert {:error, "open timed out"} =
               Browsing.run(%{command: "open", url: "https://slow.test", timeout_ms: 50}, %{})
    end

    test "honors AGENT_BROWSER_TIMEOUT_MS as the default timeout" do
      System.put_env("AGENT_BROWSER_TIMEOUT_MS", "60")
      fake_bin(~s(#!/bin/sh\nsleep 5\n))

      # No per-call timeout_ms → the env-derived default applies.
      assert {:error, "snapshot timed out"} = Browsing.run(%{command: "snapshot"}, %{})
    end
  end
end
