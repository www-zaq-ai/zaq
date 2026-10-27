defmodule Zaq.TestSupport.MattermostHistoryFixture do
  @moduledoc "Mattermost adapter frames, history responses and outgoing HTTP delivery captures."

  alias Jido.Chat.Mattermost.WebSocket.Client
  alias Plug.Conn.Utils
  alias Zaq.Channels.JidoChatBridge

  def scenarios do
    [
      {"channel without mention", nil, false, false},
      {"channel with mention", nil, true, true},
      {"bot root without mention", "bot", false, true},
      {"bot root with mention", "bot", true, true},
      {"human root without mention", "human", false, false},
      {"human root with mention", "human", true, true}
    ]
  end

  def post(config, root_author, mention?, attrs \\ %{}) do
    post_frame(config, root_author, mention?, attrs, "O")
  end

  def direct_post(config, attrs \\ %{}) do
    post_frame(config, nil, false, Map.put_new(attrs, "channel_id", "alice-dm"), "D")
  end

  defp post_frame(config, root_author, mention?, attrs, channel_type) do
    root = if root_author, do: "root-#{root_author}", else: ""

    post =
      Map.merge(
        %{
          "id" => "incoming-post",
          "user_id" => "alice",
          "channel_id" => "shared-room",
          "message" => if(mention?, do: "@zaq history question", else: "history note"),
          "root_id" => root,
          "create_at" => 1_700_000_000_000
        },
        attrs
      )

    frame =
      {:text,
       Jason.encode!(%{
         "event" => "posted",
         "data" => %{
           "channel_type" => channel_type,
           "post" => Jason.encode!(post),
           "mentions" => Jason.encode!(if(mention?, do: ["bot"], else: []))
         }
       })}

    state = %{
      token: "test-token",
      url: config.url,
      bot_user_id: "bot",
      bot_name: "zaq",
      channel_ids: :all,
      bridge_id: "mattermost_#{config.id}",
      sink_mfa: {JidoChatBridge, :from_listener, [config]},
      sink_opts: [bridge_id: "mattermost_#{config.id}"]
    }

    {Client.handle_in(frame, state), post}
  end

  def http(conn, body, owner) do
    case {conn.method, conn.request_path} do
      {"GET", "/api/v4/users/" <> id} ->
        {200,
         %{
           "id" => id,
           "username" => username(id),
           "first_name" => "Alice",
           "email" => email(id)
         }}

      {"POST", "/api/v4/channels/direct"} ->
        {201, %{"id" => "alice-dm", "type" => "D"}}

      {_, "/v1/responses"} ->
        send(owner, {:history_llm, Jason.decode!(body)})
        delta = Jason.encode!(%{"delta" => "History answer"})

        done =
          Jason.encode!(%{
            "response" => %{
              "id" => "history-response",
              "model" => "gpt-4.1-mini",
              "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
            }
          })

        {200,
         "event: response.output_text.delta\ndata: #{delta}\n\nevent: response.completed\ndata: #{done}\n\n"}

      {"GET", "/api/v4/posts/root-" <> author} ->
        {200,
         %{
           "id" => "root-#{author}",
           "user_id" => author,
           "channel_id" => "shared-room",
           "message" => "Root message",
           "root_id" => "",
           "create_at" => 1_699_999_999_000
         }}

      {"POST", "/api/v4/posts"} ->
        payload = Jason.decode!(body)
        send(owner, {:history_post, payload})
        {201, Map.merge(payload, %{"id" => "bot-response", "create_at" => 1_700_000_000_001})}

      {"PUT", "/api/v4/posts/" <> id} ->
        payload = Jason.decode!(body)
        send(owner, {:history_update, payload})
        {200, Map.merge(payload, %{"id" => id, "update_at" => 1_700_000_000_002})}

      {_, "/api/v4/users/me/typing"} ->
        {200, %{}}

      other ->
        send(owner, {:unexpected_history_http, other})
        {500, %{"error" => "unexpected mock request"}}
    end
  end

  @doc "Captures real adapter HTTP uploads/posts at a private delivery boundary."
  def delivery_http(conn, body, owner, namespace) do
    case {conn.method, conn.request_path} do
      {"POST", "/api/v4/files"} ->
        [content_type] = Plug.Conn.get_req_header(conn, "content-type")
        {:ok, _, _, params} = Utils.media_type(content_type)
        parts = multipart_parts(body, params["boundary"])

        {[{file_headers, bytes}], [{channel_headers, channel_id}]} =
          Enum.split_with(parts, fn {headers, _} -> headers =~ ~s(name="files") end)

        true = channel_headers =~ ~s(name="channel_id")

        [_, filename] = Regex.run(~r/filename="([^"]+)"/, file_headers)
        [_, mime_type] = Regex.run(~r/content-type:\s*([^\r\n]+)/i, file_headers)

        send(
          owner,
          {:delivery_upload, namespace,
           %{
             channel_id: channel_id,
             filename: filename,
             mime_type: mime_type,
             bytes: bytes,
             authorization: Plug.Conn.get_req_header(conn, "authorization")
           }}
        )

        {201,
         %{
           "file_infos" => [
             %{
               "id" => "file-#{namespace}",
               "name" => filename,
               "mime_type" => mime_type,
               "size" => byte_size(bytes)
             }
           ]
         }}

      {"POST", "/api/v4/posts"} ->
        payload = Jason.decode!(body)

        send(
          owner,
          {:delivery_boundary, namespace, self(),
           %{post: payload, authorization: Plug.Conn.get_req_header(conn, "authorization")}}
        )

        receive do
          :accept_delivery ->
            {201, Map.put(payload, "id", "post-#{namespace}")}
        after
          15_000 -> {504, %{"error" => "delivery boundary was not released"}}
        end

      _ ->
        http(conn, body, owner)
    end
  end

  defp multipart_parts(body, boundary) do
    body
    |> :binary.split("--" <> boundary, [:global])
    |> Enum.flat_map(fn
      "\r\n" <> part ->
        [headers, content] = :binary.split(part, "\r\n\r\n")
        size = byte_size(content) - 2
        <<bytes::binary-size(^size), "\r\n">> = content
        [{headers, bytes}]

      _ ->
        []
    end)
  end

  defp username("bot"), do: "zaq"
  defp username(id), do: id

  defp email("alice"), do: "alice@example.com"
  defp email(_id), do: nil
end
