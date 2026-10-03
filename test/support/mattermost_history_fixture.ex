defmodule Zaq.TestSupport.MattermostHistoryFixture do
  @moduledoc "Real Mattermost adapter frames and HTTP responses for Shared history regressions."

  alias Jido.Chat.Mattermost.WebSocket.Client
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

  def post(config, root_author, mention?) do
    root = if root_author, do: "root-#{root_author}", else: ""

    post = %{
      "id" => "incoming-post",
      "user_id" => "alice",
      "channel_id" => "shared-room",
      "message" => if(mention?, do: "@zaq history question", else: "history note"),
      "root_id" => root,
      "create_at" => 1_700_000_000_000
    }

    frame =
      {:text,
       Jason.encode!(%{
         "event" => "posted",
         "data" => %{
           "channel_type" => "O",
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

  defp username("bot"), do: "zaq"
  defp username(id), do: id

  defp email("alice"), do: "alice@example.com"
  defp email(_id), do: nil
end
