defmodule Zaq.E2EPw.BO do
  @moduledoc """
  Port of `test/e2e/support/bo.js`: back-office helpers for the Playwright journeys.
  """

  alias Playwright.{APIRequestContext, APIResponse, BrowserContext, Expect, Locator, Page}

  @flash_observer_path Path.expand("../../e2e/support/flash-observer.js", __DIR__)
  @external_resource @flash_observer_path
  # The JS file is a CommonJS module; the installer is its first function declaration.
  @flash_observer_fn @flash_observer_path
                     |> File.read!()
                     |> String.replace(~r/\nmodule\.exports.*\z/s, "\n")
                     |> then(&("(() => {" <> &1 <> " return installFlashObserver })()"))

  defp default_base_url, do: System.get_env("E2E_BASE_URL") || "http://localhost:4002"
  defp default_admin_username, do: System.get_env("E2E_ADMIN_USERNAME") || "e2e_admin"
  defp default_admin_password, do: System.get_env("E2E_ADMIN_PASSWORD") || "StrongPass1!"

  def ci?, do: System.get_env("CI") not in [nil, "", "false"]
  def expect_timeout, do: if(ci?(), do: 20_000, else: 15_000)

  def normalize_base_url(base_url \\ nil),
    do: (base_url || default_base_url()) |> String.replace(~r/\/+$/, "")

  # --- flash observer -----------------------------------------------------------------------

  @doc "Observes rendered notifications while `action` runs (expectFlashDuringAction)."
  def expect_flash_during_action(page, text, action, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, expect_timeout())
    exact = Keyword.get(opts, :exact, false)

    # The spec's WeakSet of pages. addInitScript(fn) calls fn; a string is sent as is.
    unless Process.get({:flash_observer_page, page}) do
      Page.add_init_script!(page, "(#{@flash_observer_fn})()")
      Process.put({:flash_observer_page, page}, true)
    end

    Page.evaluate!(page, "(#{@flash_observer_fn})()")
    Page.evaluate!(page, "() => window.__e2eArmFlashes()")
    action.()

    Page.wait_for_function!(
      page,
      """
      ({ text, exact }) => window.__e2eFlashes?.some(message => exact ? message === text : message.includes(text))
      """,
      %{text: text, exact: exact},
      timeout: timeout
    )
  end

  # --- LiveView -----------------------------------------------------------------------------

  def wait_for_live_view_connected(page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 15_000)

    page
    |> Page.locator("[data-phx-main]")
    |> Locator.first()
    |> Expect.to_be_visible!(timeout: timeout)

    Page.wait_for_function!(
      page,
      """
      () => {
        const liveRoot = document.querySelector("[data-phx-main]");
        if (!liveRoot) return false;
        const socket = window.liveSocket;
        const socketConnected = socket && typeof socket.isConnected === "function" && socket.isConnected();
        // phx-connected means the LiveView channel has joined; a connected socket alone still
        // drops phx-click events fired before the join.
        return liveRoot.classList.contains("phx-connected") && socketConnected === true;
      }
      """,
      nil,
      timeout: timeout
    )
  end

  def wait_for_live_view_settled(page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    Page.wait_for_function!(
      page,
      """
      () => {
        const loading = document.querySelectorAll(
          ".phx-change-loading, .phx-click-loading, .phx-submit-loading, .phx-disconnected"
        );
        return loading.length === 0;
      }
      """,
      nil,
      timeout: timeout
    )
  end

  def goto_back_office_live(page, path, opts \\ []) do
    # Cancel the outgoing view's recovery reload before starting a full navigation.
    Page.evaluate!(page, """
    () => new Promise(resolve => {
      if (typeof window.liveSocket?.disconnect === "function") {
        window.liveSocket.disconnect(resolve);
      } else {
        resolve();
      }
    })
    """)

    # `:goto` replaces Page.goto!/2 for the navigation test, where the spec wraps page.goto.
    Keyword.get(opts, :goto, &Page.goto!/2).(page, path)

    if Keyword.get(opts, :ensure_connected, true) do
      wait_for_live_view_connected(page, opts)
    end
  end

  # --- login ------------------------------------------------------------------------------------

  @doc """
  Authenticates the page against the BO.

  Every context starts from the storage state the global setup saved after logging in through
  the form (`Zaq.E2EPw.GlobalSetup`). This just navigates to the requested BO route and falls
  back to the real form if a destructive test invalidated the cached session.

  The form is always used when the caller supplies a `:password` or sets `real_login: true`.
  That keeps login/onboarding journeys under test and avoids cached e2e_admin auth leaking into
  tests that intentionally log in as another user.

  `:return_to` lands directly on the page under test.
  """
  def login_to_back_office(page, opts \\ []) do
    use_form = opts[:real_login] == true or is_binary(opts[:password])

    if use_form do
      page |> Page.context() |> BrowserContext.clear_cookies!()
      login_via_form(page, opts)
    else
      login_with_storage_state(page, opts)
    end

    :ok
  end

  defp login_with_storage_state(page, opts) do
    return_to = opts[:return_to] || "/bo/dashboard"
    Page.goto!(page, return_to)

    cond do
      Regex.match?(~r{/bo/login(?:$|[?#])}, URI.parse(Page.url(page)).path || "") ->
        login_via_form(page, Keyword.put(opts, :return_to, return_to))
        auth_state_path = Playwright.Test.config()[:storage_state]
        page |> Page.context() |> BrowserContext.storage_state!(path: auth_state_path)

      Keyword.get(opts, :ensure_connected, true) ->
        wait_for_live_view_connected(page, opts)

      true ->
        :ok
    end
  end

  def login_via_form(page, opts \\ []) do
    username = opts[:username] || default_admin_username()
    password = opts[:password] || default_admin_password()
    max_attempts = opts[:max_attempts] || 4

    goto_back_office_live(page, "/bo/login", opts)
    login_attempts(page, username, password, opts, 0, max_attempts)
  end

  defp login_attempts(page, username, password, opts, attempt, max_attempts)
       when attempt < max_attempts do
    # Wait for LiveView to attach BEFORE touching the form: .fill() fires a phx-change that
    # the channel is not yet listening for.
    wait_for_live_view_connected(page, opts)

    user_field = Page.locator(page, ~s|input[name="username"]|)
    pass_field = Page.locator(page, ~s|input[name="password"]|)

    Expect.to_be_visible!(user_field, timeout: 5_000)
    Locator.fill!(user_field, username)
    Locator.fill!(pass_field, password)
    page |> Page.get_by_role(:button, name: "Sign In to Dashboard") |> Locator.click!()

    try do
      Expect.to_have_url!(page, ~r{/bo/(dashboard|change-password)},
        timeout: 7_000 + attempt * 2_000
      )

      wait_for_live_view_connected(page, opts)
      maybe_navigate_after_login(page, opts)
    rescue
      _ ->
        # Exponential-ish backoff: 0, 500, 1000, 1500 ms
        Page.wait_for_timeout!(page, attempt * 500)
        goto_back_office_live(page, "/bo/login", opts)
        login_attempts(page, username, password, opts, attempt + 1, max_attempts)
    end
  end

  defp login_attempts(page, _username, _password, opts, _attempt, _max_attempts) do
    # Final assertion gives a clean failure message if all retries fell through.
    Expect.to_have_url!(page, ~r{/bo/(dashboard|change-password)})
    wait_for_live_view_connected(page, opts)
    maybe_navigate_after_login(page, opts)
  end

  defp maybe_navigate_after_login(page, opts) do
    return_to = opts[:return_to]

    if return_to && return_to != "/bo/dashboard" &&
         not Regex.match?(~r{/bo/change-password}, Page.url(page)) do
      goto_back_office_live(page, return_to, opts)
    end

    :ok
  end

  # Dismisses any visible flash toast so the NEXT test does not match a leftover message.
  def dismiss_flash(page) do
    flash =
      page |> Page.locator("#ingest-toast, [id^='flash-']") |> Locator.filter(has_text: ~r/./)

    count = Locator.count!(flash)

    if count > 0 do
      for i <- 0..(count - 1), do: flash |> Locator.nth(i) |> close_flash()
      # Errors ignored, as the spec's .catch(() => {}).
      Expect.to_have_count(flash, 0, timeout: 5_000)
    end

    :ok
  end

  defp close_flash(item) do
    close = Locator.get_by_role(item, :button, name: ~r/close|dismiss/i)
    if Locator.count!(close) > 0, do: close |> Locator.first() |> Locator.click()
  end

  def wait_for_server_round_trip(page) do
    wait_for_live_view_connected(page)
    wait_for_live_view_settled(page)
  end

  # ZaqWeb.Select uses the same hook with search disabled; searchable callers keep filtering.
  def pick_searchable_select(page, container_sel, option_label, opts \\ []) do
    searchable = Keyword.get(opts, :searchable, true)
    trigger = Page.locator(page, "#{container_sel} [data-select-trigger]")
    panel = Page.locator(page, "#{container_sel} [data-select-panel]")
    search = Page.locator(page, "#{container_sel} [data-select-search]")
    option = Page.locator(page, ~s|#{container_sel} [data-select-option="#{option_label}"]|)

    Expect.to_be_visible!(trigger)

    # LiveView can patch/remount this hook while dependent fields update: retry opening.
    opened =
      Enum.any?(1..5, fn _ ->
        Locator.click!(trigger, force: true)

        try do
          Expect.to_be_visible!(panel, timeout: 600)
          if searchable, do: Expect.to_be_visible!(search, timeout: 600)
          true
        rescue
          _ ->
            Page.wait_for_timeout!(page, 120)
            false
        end
      end)

    unless opened, do: raise("select panel did not open")
    if searchable, do: Locator.fill!(search, option_label)
    Expect.to_be_visible!(option, timeout: if(ci?(), do: 10_000, else: 5_000))
    Locator.click!(option)
  end

  # Creates an AI credential via the System Config AI Credentials tab.
  def create_ai_credential(page, overrides \\ %{}) do
    overrides = Map.new(overrides)
    unique = "#{System.system_time(:millisecond)}-#{:rand.uniform(10_000) - 1}"

    credential = %{
      name: overrides[:name] || "E2E Credential #{unique}",
      provider: overrides[:provider] || "Custom",
      endpoint: overrides[:endpoint],
      api_key:
        if(Map.has_key?(overrides, :api_key), do: overrides.api_key, else: "e2e-key-#{unique}"),
      personal_credential_policy: overrides[:personal_credential_policy] || "disabled",
      sovereign: overrides[:sovereign] || false,
      description: overrides[:description] || "E2E credential"
    }

    Expect.to_pass!(
      fn ->
        page |> Page.locator(~s|[phx-value-tab="ai_credentials"]|) |> Locator.click!()
        Expect.to_have_url!(page, ~r/tab=ai_credentials/, timeout: 2_000)

        page
        |> Page.locator(~s|[phx-click="new_ai_credential"]|)
        |> Expect.to_be_visible!(timeout: 2_000)
      end,
      timeout: expect_timeout()
    )

    Expect.to_pass!(
      fn ->
        page |> Page.locator(~s|[phx-click="new_ai_credential"]|) |> Locator.click!()
        page |> Page.locator("#ai-credential-form") |> Expect.to_be_visible!(timeout: 2_000)
      end,
      timeout: expect_timeout()
    )

    page |> Page.locator(~s|input[name="ai_credential[name]"]|) |> Locator.fill!(credential.name)
    pick_searchable_select(page, "#ai-credential-provider-select", credential.provider)

    if credential.endpoint != nil do
      page
      |> Page.locator(~s|input[name="ai_credential[endpoint]"]|)
      |> Locator.fill!(credential.endpoint)
    end

    page |> Page.locator("#ai-credential-api-key-input") |> Locator.fill!(credential.api_key)

    page
    |> Page.locator(~s|[name="ai_credential[personal_credential_policy]"]|)
    |> Locator.select_option!(credential.personal_credential_policy)

    if credential.sovereign do
      page
      |> Page.locator(~s|label:has(input[name="ai_credential[sovereign]"][type="checkbox"])|)
      |> Locator.click!()
    end

    page
    |> Page.locator(~s|textarea[name="ai_credential[description]"]|)
    |> Locator.fill!(credential.description)

    page
    |> Page.locator("#ai-credential-modal")
    |> Locator.get_by_role(:button, name: "Save credential")
    |> Locator.click!()

    page |> Page.get_by_text("AI credential saved.") |> Expect.to_be_visible!()
    page |> Page.locator("#ai-credential-form") |> Expect.not_() |> Expect.to_be_visible!()
    wait_for_live_view_settled(page)

    credential
  end

  # --- /e2e/* seeding endpoints -------------------------------------------------------------------

  defp ok!(response, path) do
    unless APIResponse.ok(response) do
      raise "#{path} returned #{APIResponse.status(response)} #{APIResponse.text!(response)}"
    end

    response
  end

  defp post_json!(request, path, data, opts) do
    base = normalize_base_url(opts[:base_url])
    post_opts = if data == nil, do: [], else: [data: data]
    response = APIRequestContext.post!(request, base <> path, post_opts) |> ok!(path)
    APIResponse.json!(response)
  end

  @doc "POST /e2e/reset: return the server to the baseline state."
  def reset_e2e_state(request, opts \\ []) do
    base = normalize_base_url(opts[:base_url])
    APIRequestContext.post!(request, base <> "/e2e/reset") |> ok!("/e2e/reset")
    :ok
  end

  def seed_e2e_people_connectors(request, opts \\ []),
    do: post_json!(request, "/e2e/people-connectors", nil, opts)

  def select_person_channel_connector(page, platform, connector_id) do
    page |> Page.locator(~s|select[name="channel[platform]"]|) |> Locator.select_option!(platform)
    connector = Page.locator(page, ~s|select[name="channel[channel_config_id]"]|)

    connector
    |> Locator.locator(~s|option[value="#{connector_id}"]|)
    |> Expect.to_have_count!(1)

    Locator.select_option!(connector, to_string(connector_id))
    Expect.to_have_value!(connector, to_string(connector_id))
    wait_for_live_view_settled(page)
  end

  def seed_e2e_llm_performance(request, mode \\ "seed", opts \\ []),
    do: post_json!(request, "/e2e/telemetry/llm-performance", %{mode: mode}, opts)

  def create_e2e_addon_package(request, attrs, opts \\ []),
    do: post_json!(request, "/e2e/addon-package", attrs, opts)

  def set_e2e_system_config(request, key, value, opts \\ []) do
    post_json!(request, "/e2e/system-config", %{key: key, value: value}, opts)
    :ok
  end

  def touch_e2e_file(request, relative_path, opts \\ []) do
    base = normalize_base_url(opts[:base_url])

    APIRequestContext.post!(request, base <> "/e2e/ingestion/touch_file",
      params: %{path: relative_path}
    )
    |> ok!("/e2e/ingestion/touch_file")

    :ok
  end

  def write_e2e_file(request, relative_path, content, opts \\ []) do
    post_json!(
      request,
      "/e2e/ingestion/write_file",
      %{path: relative_path, content: content},
      opts
    )

    :ok
  end

  # Requires a page that has already completed the BO login. page.request keeps the CSRF token
  # and the Phoenix session cookie in one context.
  def create_e2e_ai_credential(page, attrs, opts \\ []) do
    base = normalize_base_url(opts[:base_url])

    csrf =
      page
      |> Page.locator(~s|meta[name="csrf-token"]|)
      |> Locator.get_attribute!("content")

    unless csrf, do: raise("Authenticated BO page did not expose a CSRF token.")

    response =
      APIRequestContext.post!(Page.request(page), base <> "/e2e/ai-credentials",
        data: attrs,
        headers: %{"x-csrf-token" => csrf}
      )
      |> ok!("/e2e/ai-credentials")

    APIResponse.json!(response)
  end

  def create_e2e_mcp_endpoint(request, attrs, opts \\ []),
    do: post_json!(request, "/e2e/mcp-endpoints", attrs, opts)

  def create_e2e_agent(request, attrs, opts \\ []),
    do: post_json!(request, "/e2e/agents", attrs, opts)

  # Answering journeys opt in explicitly; the reset baseline must remain unconfigured.
  def create_e2e_answering_agent(page) do
    credential =
      create_e2e_ai_credential(page, %{
        name: "E2E Chat Credential #{System.system_time(:millisecond)}",
        provider: "custom",
        endpoint: "#{normalize_base_url()}/e2e/llm/v1",
        api_key: "e2e-fake-key"
      })

    create_e2e_agent(Page.request(page), %{
      name: "E2E Chat Agent #{System.system_time(:millisecond)}",
      job:
        "Search the knowledge base before answering. Cite returned documents with [[source:path]].",
      credential_id: credential["id"],
      model: "e2e-fake",
      model_max_context_tokens: 128_000,
      enabled_tool_keys: ["answering.search_knowledge_base"],
      conversation_enabled: true,
      active: true,
      advanced_options: %{stream: true}
    })
  end

  def select_e2e_chat_agent(page, agent) do
    pick_searchable_select(page, "#chat-agent-select", agent["name"], searchable: false)
    wait_for_live_view_settled(page)
  end

  def create_e2e_conversation(request, attrs, opts \\ []),
    do: post_json!(request, "/e2e/conversations", attrs, opts)

  def seed_e2e_channel_history(request, opts \\ []),
    do: post_json!(request, "/e2e/channel-history", nil, opts)

  def create_e2e_bootstrap_admin(request, opts \\ []) do
    post_json!(request, "/e2e/bootstrap-admin", nil, opts)
    :ok
  end

  def create_e2e_onboarding_user(request, attrs \\ %{}, opts \\ []),
    do: post_json!(request, "/e2e/onboarding-user", attrs, opts)

  def create_e2e_declined_portal_user(request, attrs \\ %{}, opts \\ []),
    do: post_json!(request, "/e2e/declined-portal-user", attrs, opts)

  def register_e2e_portal_conflict(request, attrs \\ %{}, opts \\ []),
    do: post_json!(request, "/e2e/portal/conflicts", attrs, opts)

  def set_e2e_portal_offline(request, offline \\ true, opts \\ []),
    do: post_json!(request, "/e2e/portal/offline", %{offline: offline}, opts)

  def get_e2e_zaq_router_credential(request, opts \\ []) do
    base = normalize_base_url(opts[:base_url])
    params = if opts[:with_api_key], do: %{with_api_key: "true"}, else: %{}

    response =
      APIRequestContext.get!(request, base <> "/e2e/zaq-router-credential", params: params)

    if not APIResponse.ok(response) and APIResponse.status(response) != 404 do
      raise "/e2e/zaq-router-credential returned #{APIResponse.status(response)} #{APIResponse.text!(response)}"
    end

    APIResponse.json!(response)
  end

  def seed_e2e_prompt_template_defaults(request) do
    response =
      APIRequestContext.post!(request, default_base_url() <> "/e2e/prompt-template-defaults")

    unless APIResponse.ok(response), do: raise("prompt template defaults request failed")
    APIResponse.json!(response)
  end

  def publish_e2e_prompt_template_defaults(request, body) do
    response =
      APIRequestContext.post!(
        request,
        default_base_url() <> "/e2e/prompt-template-defaults/publish",
        data: %{body: body}
      )

    unless APIResponse.ok(response), do: raise("prompt template defaults request failed")
    :ok
  end

  def open_prompt_template(page, slug) do
    goto_back_office_live(page, "/bo/prompt-templates")
    page |> Page.locator("#prompt-tab-#{slug}") |> Locator.click!()
    wait_for_live_view_settled(page)
    Page.locator(page, ~s|textarea[name="prompt_template[body]"]|)
  end
end
