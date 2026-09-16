defmodule ZaqWeb.PersonConversationResourceControllerTest do
  use ZaqWeb.ConnCase, async: true
  use ExUnitProperties
  import Mox
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Storage.Materializers.DiskDocument
  alias Zaq.TestSupport.PersonResourceConfig
  alias ZaqWeb.PersonConversationResourceController
  setup :verify_on_exit!

  setup do
    # Config.get/4 probes exported callbacks without loading optional modules.
    # Load this explicit test provider before asking that real boundary to use it.
    Code.ensure_loaded!(PersonResourceConfig)
    :ok
  end

  for failure <- [:invalid_session, :raise, :exit] do
    @tag failure: failure
    test "#{failure}: late revocation or transport failure never sends private bytes", %{
      conn: conn,
      failure: failure
    } do
      conn =
        conn
        |> init_test_session(%{person_session_token: "server-secret"})
        |> assign(:config, PersonResourceConfig)

      params = %{
        "id" => Ecto.UUID.generate(),
        "message_id" => Ecto.UUID.generate(),
        "artifact_id" => Ecto.UUID.generate()
      }

      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        assert event.request.op == :artifact
        assert event.request.token == "server-secret"
        assert event.opts[:confidential]
        assert event.opts[:action] == :people_conversations

        transport_failure(failure, event)
      end)

      result = PersonConversationResourceController.show(conn, params)

      if failure == :invalid_session do
        assert redirected_to(result) == "/people/login"
      else
        assert response(result, 404) == "Resource not found"
      end

      refute result.resp_body =~ "private transport data"
      refute result.resp_body =~ "server-secret"
    end
  end

  test "source handles redeem directly against Storage with authoritative actor and private headers",
       %{conn: conn} do
    {:ok, handle} =
      DiskDocument.issue("source", %{"config_id" => "config"})

    actor = %{person: %{id: 42}}

    for {content, attrs, name, mime, expected} <- [
          {"raw", %{}, "../source\".txt", "text/plain", "raw"},
          {Base.encode64("decoded"), %{"encoding" => "base64"}, nil, nil, "decoded"},
          {"!", %{"encoding" => "base64"}, nil, nil, nil},
          {nil, %{}, nil, nil, nil}
        ] do
      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        assert event.opts[:action] == :people_conversations
        assert event.request.op == :source
        assert event.opts[:confidential]

        %{
          event
          | response:
              {:ok,
               %{
                 kind: :source,
                 document_reference: "data_source/disk/config/source",
                 actor: actor,
                 name: "fallback.txt",
                 mime_type: "application/octet-stream"
               }}
        }
      end)

      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        assert event.next_hop.destination == :channels
        assert event.opts[:action] == :data_source_get_file

        assert event.request == %{
                 provider: "disk",
                 params: %{"config_id" => "config", "file_id" => "source"}
               }

        assert event.actor == actor
        refute event.opts[:skip_permissions]

        {:ok, record} =
          Provenance.seal(%Record{
            id: "source",
            kind: :file,
            name: "fallback.txt",
            mime_type: "application/octet-stream",
            materialization_handle: handle
          })

        %{event | response: {:ok, %{record: record}}}
      end)

      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        assert event.next_hop.destination == :storage
        assert event.opts[:action] == :materialize_document
        assert event.actor == actor
        refute event.opts[:skip_permissions]

        %{
          event
          | response:
              {:ok,
               %{
                 record: %Zaq.Contracts.Record{
                   id: "source",
                   kind: :file,
                   content: content,
                   attributes: attrs,
                   name: name,
                   mime_type: mime
                 }
               }}
        }
      end)

      result =
        conn
        |> init_test_session(%{person_session_token: "server-secret"})
        |> assign(:config, PersonResourceConfig)
        |> PersonConversationResourceController.show(%{
          "id" => Ecto.UUID.generate(),
          "message_id" => Ecto.UUID.generate(),
          "source" => "source"
        })

      if expected do
        assert response(result, 200) == expected
        assert get_resp_header(result, "cache-control") == ["private, no-store"]
        assert get_resp_header(result, "x-content-type-options") == ["nosniff"]
        assert get_resp_header(result, "content-security-policy") == ["sandbox"]
        assert get_resp_header(result, "content-type") == [mime || "application/octet-stream"]

        assert get_resp_header(result, "content-disposition") == [
                 if(name,
                   do: ~s(inline; filename="source_.txt"),
                   else: ~s(attachment; filename="fallback.txt")
                 )
               ]
      else
        assert response(result, 404) == "Resource not found"
      end

      refute result.resp_body =~ handle
    end
  end

  test "denied and malformed source references never dispatch redemption", %{conn: conn} do
    for reply <- [
          {:error, :not_found},
          {:ok,
           %{
             kind: :source,
             document_reference: "tampered",
             actor: %{person: %{id: 42}},
             name: "source",
             mime_type: "text/plain"
           }}
        ] do
      expect(Zaq.NodeRouterMock, :dispatch, fn event -> %{event | response: reply} end)

      result =
        conn
        |> init_test_session(%{})
        |> assign(:config, PersonResourceConfig)
        |> PersonConversationResourceController.show(%{"source" => "source"})

      assert response(result, 404) == "Resource not found"
    end
  end

  test "owner errors and transport failures return a generic source 404", %{conn: conn} do
    {:ok, handle} = DiskDocument.issue("source")

    for failure <- [:error, :raise, :exit] do
      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        %{
          event
          | response:
              {:ok,
               %{
                 kind: :source,
                 document_reference: "data_source/disk/config/source",
                 actor: %{person: %{id: 42}},
                 name: "source",
                 mime_type: "text/plain"
               }}
        }
      end)

      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        assert event.opts[:action] == :data_source_get_file

        {:ok, record} =
          Provenance.seal(%Record{id: "source", kind: :file, materialization_handle: handle})

        %{event | response: {:ok, %{record: record}}}
      end)

      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        assert event.next_hop.destination == :storage

        if failure == :error,
          do: %{event | response: {:error, :not_found}},
          else: transport_failure(failure, event)
      end)

      result =
        conn
        |> init_test_session(%{})
        |> assign(:config, PersonResourceConfig)
        |> PersonConversationResourceController.show(%{"source" => "source"})

      assert response(result, 404) == "Resource not found"
    end
  end

  defp transport_failure(:invalid_session, event),
    do: %{event | response: {:error, :invalid_session}}

  defp transport_failure(:raise, _event), do: raise("private transport data")
  defp transport_failure(:exit, _event), do: exit("private transport data")

  property "canonical references preserve opaque document IDs including slashes and percent sequences" do
    check all(segment <- string(:alphanumeric, min_length: 1, max_length: 24)) do
      id = "folder/#{segment}/file%2Fname.txt"
      source = "data_source/disk/123/#{id}"
      actor = %{person: %{id: 42}}

      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        %{event | response: {:ok, %{kind: :source, document_reference: source, actor: actor}}}
      end)

      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        assert event.request == %{
                 provider: "disk",
                 params: %{"config_id" => "123", "file_id" => id}
               }

        {:ok, record} =
          Provenance.seal(%Record{
            id: id,
            kind: :file,
            content: "Already materialized",
            name: "file.txt",
            mime_type: "text/plain"
          })

        %{event | response: {:ok, %{record: record}}}
      end)

      result =
        Phoenix.ConnTest.build_conn()
        |> init_test_session(%{})
        |> assign(:config, PersonResourceConfig)
        |> PersonConversationResourceController.show(%{"source" => source})

      assert response(result, 200) == "Already materialized"
    end
  end

  test "incomplete Records and mismatched descriptors never send source bytes", %{conn: conn} do
    actor = %{person: %{id: 42}}

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      %{event | response: {:ok, %{kind: :record, record: %{content: "private"}, actor: actor}}}
    end)

    result =
      conn
      |> init_test_session(%{})
      |> assign(:config, PersonResourceConfig)
      |> PersonConversationResourceController.show(%{"source" => "ignored"})

    assert response(result, 404) == "Resource not found"

    {:ok, unmaterialized} = Provenance.seal(%Record{id: "source", kind: :file})

    for payload <- [%{}, %{record: unmaterialized}] do
      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        %{
          event
          | response:
              {:ok,
               %{kind: :source, document_reference: "data_source/disk/123/source", actor: actor}}
        }
      end)

      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        assert event.opts[:action] == :data_source_get_file
        %{event | response: {:ok, payload}}
      end)

      result =
        conn
        |> init_test_session(%{})
        |> assign(:config, PersonResourceConfig)
        |> PersonConversationResourceController.show(%{"source" => "ignored"})

      assert response(result, 404) == "Resource not found"
    end
  end

  test "malformed authoritative sources and unattributed artifacts fail before GetDocument", %{
    conn: conn
  } do
    for reference <- [
          "profile.txt",
          "data_source//123/file",
          "data_source/disk//file",
          "data_source/disk/123/",
          "data_source/disk",
          nil
        ] do
      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        %{
          event
          | response:
              {:ok, %{kind: :source, document_reference: reference, actor: %{person: %{id: 42}}}}
        }
      end)

      result =
        conn
        |> init_test_session(%{})
        |> assign(:config, PersonResourceConfig)
        |> PersonConversationResourceController.show(%{"source" => "ignored"})

      assert response(result, 404) == "Resource not found"
    end

    for metadata <- [
          %{},
          %{
            "provenance_ref" => "tampered",
            "attributes" => %{"source_type" => "communication_media"}
          },
          %{
            "attributes" => %{
              "provider" => "disk",
              "config_id" => "123",
              "provider_record_id" => "file",
              "source_type" => "communication_media"
            }
          }
        ] do
      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        %{
          event
          | response:
              {:ok,
               %{
                 kind: :record,
                 record: %{content: "private"},
                 document_reference: metadata,
                 actor: %{person: %{id: 42}}
               }}
        }
      end)

      result =
        conn
        |> init_test_session(%{})
        |> assign(:config, PersonResourceConfig)
        |> PersonConversationResourceController.show(%{"artifact_id" => "artifact"})

      assert response(result, 404) == "Resource not found"
    end
  end
end
