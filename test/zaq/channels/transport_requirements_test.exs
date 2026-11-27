defmodule Zaq.Channels.TransportRequirementsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.TransportRequirements

  test "declares exactly the attachment transport fields and their defaults" do
    assert TransportRequirements.__struct__() == %{
             __struct__: TransportRequirements,
             transfer_mode: nil,
             max_attachments_per_message: nil,
             failure_policy: :continue,
             max_attachment_bytes: :unresolved,
             max_attachment_bytes_per_message: :unresolved,
             max_encoded_message_bytes: :unresolved,
             max_upload_request_bytes: :unresolved,
             supports_threads: false,
             supports_attachment_edits: false
           }
  end

  test "construction needs only the transfer mode and attachment count" do
    requirements = %TransportRequirements{
      transfer_mode: :upload_then_publish,
      max_attachments_per_message: 1
    }

    assert requirements.transfer_mode == :upload_then_publish
    assert requirements.max_attachments_per_message == 1
    assert requirements.failure_policy == :continue
    assert requirements.max_attachment_bytes == :unresolved
    assert requirements.max_attachment_bytes_per_message == :unresolved
    assert requirements.max_encoded_message_bytes == :unresolved
    assert requirements.max_upload_request_bytes == :unresolved
    assert requirements.supports_threads == false
    assert requirements.supports_attachment_edits == false
  end

  test "all declared fields accept explicit transport requirements" do
    attributes = %{
      transfer_mode: :send_with_attachments,
      max_attachments_per_message: 4,
      failure_policy: :abort,
      max_attachment_bytes: 1_024,
      max_attachment_bytes_per_message: 4_096,
      max_encoded_message_bytes: :not_applicable,
      max_upload_request_bytes: 8_192,
      supports_threads: true,
      supports_attachment_edits: true
    }

    requirements = struct!(TransportRequirements, attributes)

    assert Map.from_struct(requirements) == attributes
  end

  for {description, attributes} <- [
        {"both required keys", []},
        {"the transfer mode", [max_attachments_per_message: 1]},
        {"the attachment count", [transfer_mode: :upload_then_publish]}
      ] do
    test "construction rejects omission of #{description}" do
      attributes = unquote(Macro.escape(attributes))

      assert_raise ArgumentError, ~r/keys must also be given/, fn ->
        struct!(TransportRequirements, attributes)
      end

      declaration =
        quote do
          %unquote(TransportRequirements){unquote_splicing(attributes)}
        end

      assert_raise ArgumentError, ~r/keys must also be given/, fn ->
        Code.eval_quoted(declaration)
      end
    end
  end

  test "required keys enforce presence without validating their values" do
    assert %TransportRequirements{
             transfer_mode: nil,
             max_attachments_per_message: nil
           } ==
             struct!(TransportRequirements, transfer_mode: nil, max_attachments_per_message: nil)
  end

  defp snapshot(support \\ :native) do
    %{
      resolved: %{file: support, threads: :fallback, edit_messages: :native},
      file_delivery: %{
        transfer_mode: :upload_then_publish,
        supports_attachment_edits: false,
        limits: %{
          max_attachment_bytes: %{value: 5_000_000, configurable: true, required: false},
          max_encoded_message_bytes: %{
            value: :not_applicable,
            configurable: false,
            required: false
          },
          max_upload_request_bytes: %{value: :unresolved, configurable: false, required: false},
          max_attachments_per_message: %{value: 10, configurable: true, required: true}
        }
      }
    }
  end

  defp connection(settings \\ %{}), do: %{id: 42, settings: %{"file_delivery" => settings}}

  test "derives known facts, preserves unknown limits and separates policy from capabilities" do
    for support <- [:native, :fallback] do
      assert {:ok, requirements} =
               TransportRequirements.resolve(snapshot(support), connection())

      assert requirements == %TransportRequirements{
               transfer_mode: :upload_then_publish,
               max_attachments_per_message: 10,
               max_attachment_bytes: 5_000_000,
               max_encoded_message_bytes: :not_applicable,
               supports_threads: true
             }
    end
  end

  test "rejects data-source snapshots and selected data-source connections" do
    for kind <- [:data_source, "data_source"] do
      assert {:error, :unsupported} =
               TransportRequirements.resolve(
                 Map.put(snapshot(), :kind, kind),
                 connection()
               )

      assert {:error, :unsupported} =
               TransportRequirements.resolve(
                 snapshot(),
                 Map.put(connection(), :kind, kind)
               )
    end
  end

  test "configured limits lower ceilings and explicit false means abort" do
    config =
      connection(%{
        "max_attachment_bytes" => 1_000_001,
        "max_attachments_per_message" => 2,
        "send_on_file_failure" => false
      })

    assert {:ok, result} = TransportRequirements.resolve(snapshot(), config)
    assert result.max_attachment_bytes == 1_000_001
    assert result.max_attachments_per_message == 2
    assert result.failure_policy == :abort
    assert {:ok, ^result} = TransportRequirements.resolve(snapshot(), config)
  end

  test "resolver enforces the same declared numeric rules as file configuration" do
    caps =
      put_in(snapshot(), [:file_delivery, :limits, :max_attachment_bytes, :validation], %{
        less_than_or_equal_to: 100
      })

    assert {:ok, result} =
             TransportRequirements.resolve(caps, connection(%{"max_attachment_bytes" => 100}))

    assert result.max_attachment_bytes == 100

    assert {:error, {:invalid_configuration, %{"max_attachment_bytes" => _}}} =
             TransportRequirements.resolve(caps, connection(%{"max_attachment_bytes" => 101}))
  end

  test "rejects unsupported or unavailable capabilities without assuming unlimited limits" do
    for support <- [:unsupported, false, nil] do
      assert {:error, :unsupported} =
               TransportRequirements.resolve(snapshot(support), connection())
    end

    assert {:error, :capabilities_unavailable} =
             TransportRequirements.resolve(nil, connection())

    assert {:error, :capabilities_unavailable} =
             TransportRequirements.resolve(%{resolved: %{file: :native}}, connection())
  end

  test "required unresolved constraints and malformed overrides return field errors" do
    caps =
      put_in(
        snapshot(),
        [:file_delivery, :limits, :max_attachments_per_message, :value],
        :unresolved
      )

    assert {:error, {:invalid_configuration, %{"max_attachments_per_message" => _}}} =
             TransportRequirements.resolve(caps, connection())

    for settings <- [
          %{"max_attachment_bytes" => 5_000_001},
          %{"max_attachment_bytes" => "100"},
          %{"max_attachments_per_message" => 0},
          %{"max_encoded_message_bytes" => 1}
        ] do
      assert {:error, {:invalid_configuration, errors}} =
               TransportRequirements.resolve(snapshot(), connection(settings))

      assert map_size(errors) > 0
    end
  end

  test "requires a declared transfer mode and explicit attachment-edit support" do
    caps = put_in(snapshot(), [:file_delivery, :transfer_mode], :unresolved)

    assert {:error, {:unresolved_capabilities, [:transfer_mode]}} =
             TransportRequirements.resolve(caps, connection())

    caps =
      snapshot()
      |> put_in([:file_delivery, :transfer_mode], :send_with_attachments)
      |> put_in([:file_delivery, :supports_attachment_edits], true)

    assert {:ok, result} = TransportRequirements.resolve(caps, connection())
    assert result.transfer_mode == :send_with_attachments
    assert result.supports_attachment_edits
  end

  test "malformed transport declarations fail closed instead of crashing or becoming unlimited" do
    for metadata <- [
          %{limits: %{max_attachment_bytes: "invalid"}},
          %{limits: %{max_attachment_bytes: %{value: 0, configurable: true}}},
          %{limits: %{max_attachment_bytes: %{value: 100, configurable: "yes"}}},
          %{limits: %{}, supports_attachment_edits: "yes"}
        ] do
      assert {:error, :capabilities_unavailable} =
               TransportRequirements.resolve(
                 %{snapshot() | file_delivery: metadata},
                 connection()
               )
    end
  end

  property "a configurable override can never raise the declared transport ceiling" do
    check all(ceiling <- integer(1..1_000_000_000), delta <- integer(1..1_000_000)) do
      caps = put_in(snapshot(), [:file_delivery, :limits, :max_attachment_bytes, :value], ceiling)

      assert {:error, {:invalid_configuration, %{"max_attachment_bytes" => _}}} =
               TransportRequirements.resolve(
                 caps,
                 connection(%{"max_attachment_bytes" => ceiling + delta})
               )

      assert {:ok, result} =
               TransportRequirements.resolve(
                 caps,
                 connection(%{"max_attachment_bytes" => ceiling})
               )

      assert result.max_attachment_bytes == ceiling
    end
  end
end
