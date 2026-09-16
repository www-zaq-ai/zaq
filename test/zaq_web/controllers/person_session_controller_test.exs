defmodule ZaqWeb.PersonSessionControllerTest do
  use ZaqWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.Static

  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissions, PersonLoginChallenge}
  alias Zaq.Channels.{PeopleAuthDeliveryMock, PeopleAuthRateLimiter}
  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.Repo
  alias Zaq.TestSupport.{PeopleAuthClock, PeopleAuthDelivery}
  alias ZaqWeb.Live.People.AuthHook
  import Mox

  setup :verify_on_exit!

  setup do
    {:ok, person} = People.create_person(%{full_name: "Profile visitor"})
    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    # Existing HTTP replacement scenarios begin after the initial issuance minute.
    PeopleAuthClock.put(DateTime.add(DateTime.utc_now(:second), -60))

    {:ok, challenge} =
      PeopleAuth.issue_challenge(person, {0, 0, 0, 0, 0, 0, 9, rem(person.id, 65_536)},
        clock: PeopleAuthClock
      )

    %{person: person, challenge: challenge}
  end

  test "verification sets only the Person credential, profile mounts and logout preserves BO", %{
    conn: conn,
    challenge: c
  } do
    conn =
      conn
      |> init_test_session(%{user_id: 123})
      |> post("/people/session", %{"challenge_id" => c.challenge_id, "code" => c.code})

    assert redirected_to(conn) == "/people/profile"
    token = get_session(conn, :person_session_token)
    assert is_binary(token)
    assert get_session(conn, :user_id) == 123
    {:ok, view, html} = live(recycle(conn), "/people/profile")
    assert html =~ "Profile visitor"
    refute html =~ token

    for signed <-
          html
          |> LazyHTML.from_fragment()
          |> LazyHTML.query("[data-phx-session]")
          |> LazyHTML.attribute("data-phx-session") do
      assert {:ok, signed_payload} = Static.verify_token(@endpoint, signed)
      refute inspect(signed_payload, limit: :infinity) =~ token
    end

    refute render(view) =~ "Message history"
    conn = conn |> recycle() |> delete("/people/session")
    assert get_session(conn, :person_session_token) == nil
    assert get_session(conn, :user_id) == 123
    assert {:error, :invalid_session} = PeopleAuth.authenticate(token)
  end

  test "wrong code retains OTP screen without retaining the submitted code", %{
    conn: conn,
    challenge: c
  } do
    conn =
      post(conn, "/people/session", %{"challenge_id" => c.challenge_id, "code" => "wrong-secret"})

    assert redirected_to(conn) == "/people/login"
    {:ok, _, html} = live(recycle(conn), "/people/login")
    assert html =~ "One-time code"
    refute html =~ "wrong-secret"
    assert get_session(conn, :person_session_token) == nil
  end

  test "BO logout preserves Person credential", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{user_id: 123, person_session_token: "person-token"})
      |> delete("/bo/session")

    assert get_session(conn, :user_id) == nil
    assert get_session(conn, :person_session_token) == "person-token"
  end

  test "email POST sends before showing OTP; resend replaces only through Engine", %{
    conn: conn,
    person: person
  } do
    PeopleAuthDelivery.setup()
    {:ok, person} = People.update_person(person, %{email: "http-login@example.test"})
    send(Zaq.Channels.PeopleAuthRateLimiter.Config, :refresh)
    _ = :sys.get_state(Zaq.Channels.PeopleAuthRateLimiter.Config)
    expect(PeopleAuthDeliveryMock, :send_reply, 2, fn _, _ -> :ok end)
    conn = post(conn, "/people/challenge", %{"email" => person.email})
    first = get_session(conn, :person_login_challenge)
    assert first.expires_at
    {:ok, _, html} = live(recycle(conn), "/people/login")
    assert html =~ "One-time code"
    assert html =~ "inputmode=\"numeric\""
    assert first.resend_available_at
    assert html =~ "data-resend-available-at"
    assert html =~ "form=\"people-resend-form\""
    assert html =~ "id=\"people-code-row\""
    assert html =~ "aria-describedby=\"people-resend-caption\""
    assert html =~ "Resend in"
    document = LazyHTML.from_fragment(html)
    assert LazyHTML.query(document, "form form") |> Enum.count() == 0

    assert LazyHTML.query(document, "#people-resend-form input[name=_csrf_token]") |> Enum.count() ==
             1

    denied = conn |> recycle() |> post("/people/challenge", %{})
    assert get_session(denied, :person_login_challenge) == first

    assert Phoenix.Flash.get(denied.assigns.flash, :error) ==
             "Please wait before requesting another code."

    # Advance only this sandbox challenge; HTTP continues to use the real clock.
    Repo.get!(PersonLoginChallenge, first.challenge_id)
    |> PersonLoginChallenge.changeset(%{
      inserted_at: DateTime.add(DateTime.utc_now(:second), -60)
    })
    |> Repo.update!()

    conn = conn |> recycle() |> post("/people/challenge", %{})
    second = get_session(conn, :person_login_challenge)
    refute second.challenge_id == first.challenge_id
    assert {:error, :invalid_challenge} = PeopleAuth.challenge_status(first.challenge_id)
    assert {:ok, _} = PeopleAuth.challenge_status(second.challenge_id)
  end

  test "unknown login stays on email stage with generic error and ignores forwarded IP headers",
       %{conn: conn} do
    {:ok, _} = Zaq.System.save_people_access_config(%{unknown_email_attempt_limit: 1})
    send(Zaq.Channels.PeopleAuthRateLimiter.Config, :refresh)
    _ = :sys.get_state(Zaq.Channels.PeopleAuthRateLimiter.Config)
    conn = %{conn | remote_ip: {127, 0, 8, 10}}

    conn =
      conn
      |> put_req_header("x-forwarded-for", "10.10.10.10")
      |> post("/people/challenge", %{"email" => "unknown-http@example.test"})

    assert get_session(conn, :person_login_challenge) == nil
    {:ok, _, html} = live(recycle(conn), "/people/login")

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "We couldn't start the authentication process for this address."

    assert html =~ "Email address"
    refute html =~ "One-time code"

    assert {:error, {:rate_limited, _}} =
             PeopleAuthRateLimiter.check_identification({127, 0, 8, 10})

    assert :ok = PeopleAuthRateLimiter.check_identification({10, 10, 10, 10})

    limited =
      conn |> recycle() |> post("/people/challenge", %{"email" => "unknown-http@example.test"})

    assert redirected_to(limited) == "/people/login"

    assert Phoenix.Flash.get(limited.assigns.flash, :error) ==
             "Unable to send a sign-in code. Please try again later."
  end

  for {category, ip_suffix} <- [unknown: 1, inactive: 2, no_grant: 3] do
    @tag category: category
    test "#{category} request and resend share a safe start error without issuance", %{
      conn: conn,
      person: person,
      challenge: challenge,
      category: category
    } do
      PeopleAuthDelivery.setup()
      {:ok, person} = People.update_person(person, %{email: "start-error@example.test"})

      email =
        case category do
          :unknown ->
            "unknown-start@example.test"

          :inactive ->
            {:ok, _} = People.update_person(person, %{status: "inactive"})
            person.email

          :no_grant ->
            {:ok, _} = PeoplePermissions.revoke(:all_people, :access_profile)
            person.email
        end

      send(Zaq.Channels.PeopleAuthRateLimiter.Config, :refresh)
      _ = :sys.get_state(Zaq.Channels.PeopleAuthRateLimiter.Config)
      expect(PeopleAuthDeliveryMock, :send_reply, 0, fn _, _ -> :ok end)
      challenge_count = Repo.aggregate(PersonLoginChallenge, :count)
      notification_count = Repo.aggregate(NotificationLog, :count)
      descriptor = Map.take(challenge, [:challenge_id, :expires_at])

      for {params, session} <- [
            {%{"email" => email}, %{}},
            {%{}, %{person_login_email: email, person_login_challenge: descriptor}}
          ] do
        failed =
          conn
          |> recycle()
          |> Map.put(:remote_ip, {127, 0, 9, unquote(ip_suffix)})
          |> init_test_session(session)
          |> post("/people/challenge", params)

        assert failed.status == 302
        assert redirected_to(failed) == "/people/login"

        assert Phoenix.Flash.get(failed.assigns.flash, :error) ==
                 "We couldn't start the authentication process for this address."

        assert get_session(failed, :person_login_challenge) == session[:person_login_challenge]
        assert get_session(failed, :person_session_token) == nil
        assert Repo.aggregate(PersonLoginChallenge, :count) == challenge_count
        assert Repo.aggregate(NotificationLog, :count) == notification_count
      end
    end
  end

  test "delivery failure uses send error for request and resend and retains pending descriptor",
       %{
         conn: conn,
         person: person,
         challenge: challenge
       } do
    PeopleAuthDelivery.setup()
    {:ok, person} = People.update_person(person, %{email: "send-error@example.test"})
    send(Zaq.Channels.PeopleAuthRateLimiter.Config, :refresh)
    _ = :sys.get_state(Zaq.Channels.PeopleAuthRateLimiter.Config)

    expect(PeopleAuthDeliveryMock, :send_reply, 2, fn _, _ ->
      {:error, :private_transport_reason}
    end)

    descriptor = Map.take(challenge, [:challenge_id, :expires_at])

    for {params, session} <- [
          {%{"email" => person.email}, %{}},
          {%{}, %{person_login_email: person.email, person_login_challenge: descriptor}}
        ] do
      failed =
        conn
        |> recycle()
        |> init_test_session(session)
        |> post("/people/challenge", params)

      assert redirected_to(failed) == "/people/login"

      assert Phoenix.Flash.get(failed.assigns.flash, :error) ==
               "We couldn't send your verification code. Please try again later."

      assert get_session(failed, :person_login_challenge) == session[:person_login_challenge]
      assert :ok = PeopleAuthRateLimiter.check_identification(failed.remote_ip)
    end
  end

  test "issuance unavailable and limiter unavailable retain generic retry error", %{
    conn: conn,
    person: person
  } do
    PeopleAuthDelivery.setup()
    {:ok, person} = People.update_person(person, %{email: "unavailable@example.test"})
    send(Zaq.Channels.PeopleAuthRateLimiter.Config, :refresh)
    _ = :sys.get_state(Zaq.Channels.PeopleAuthRateLimiter.Config)
    Zaq.System.set_config("people_access.otp_validity_seconds", "broken")
    expect(PeopleAuthDeliveryMock, :send_reply, 0, fn _, _ -> :ok end)

    for _ <- 1..2 do
      failed = conn |> recycle() |> post("/people/challenge", %{"email" => person.email})
      assert redirected_to(failed) == "/people/login"

      assert Phoenix.Flash.get(failed.assigns.flash, :error) ==
               "Unable to send a sign-in code. Please try again later."

      assert get_session(failed, :person_login_challenge) == nil
      send(Zaq.Channels.PeopleAuthRateLimiter.Config, :refresh)
      _ = :sys.get_state(Zaq.Channels.PeopleAuthRateLimiter.Config)
    end
  end

  test "protected HTTP and LiveView deny missing or newly revoked authority", %{
    conn: conn,
    challenge: c
  } do
    assert conn |> get("/people/profile") |> redirected_to() == "/people/login"
    {:ok, %{token: token}} = PeopleAuth.verify_challenge(c.challenge_id, c.code)
    conn = conn |> recycle() |> init_test_session(%{person_session_token: token})
    {:ok, view, _} = live(conn, "/people/profile")
    {:ok, _} = PeoplePermissions.revoke(:all_people, :access_profile)
    render_hook(view, "sensitive_event", %{})
    assert_redirect(view, "/people/login")
    assert conn |> recycle() |> get("/people/profile") |> redirected_to() == "/people/login"
    assert {:error, {:redirect, %{to: "/people/login"}}} = live(conn, "/people/profile")
  end

  test "invalid BO user cleanup preserves the Person session", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{user_id: -1, person_session_token: "independent"})
      |> get("/bo/profile")

    assert get_session(conn, :user_id) == nil
    assert get_session(conn, :person_session_token) == "independent"
  end

  test "session cookie preserves baseline browser-session lifetime with HttpOnly and SameSite Lax",
       %{
         conn: conn,
         challenge: c
       } do
    conn = post(conn, "/people/session", %{"challenge_id" => c.challenge_id, "code" => c.code})
    cookie = conn.resp_cookies["_zaq_key"]
    assert cookie.http_only
    assert cookie.same_site == "Lax"
    refute Map.has_key?(cookie, :max_age)
    refute Map.has_key?(cookie, :expires)
    refute Enum.any?(get_resp_header(conn, "set-cookie"), &String.contains?(&1, "max-age="))
    refute Map.get(cookie, :secure, false)
  end

  test "actual HTTP parameter logging filters submitted OTP and bearer values", %{
    conn: conn,
    challenge: c
  } do
    {:ok, %{token: token}} = PeopleAuth.verify_challenge(c.challenge_id, c.code)
    marker = "otp-log-marker-" <> Ecto.UUID.generate()
    control = "visible-control-" <> Ecto.UUID.generate()
    modules = [Phoenix.Logger]
    previous_levels = Logger.get_module_level(modules)
    Logger.put_module_level(modules, :debug)

    try do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          conn
          |> init_test_session(%{person_session_token: token})
          |> post("/people/session", %{
            "challenge_id" => c.challenge_id,
            "code" => marker,
            "person_session_token" => token,
            "audit_marker" => control
          })
        end)

      assert log =~ control
      assert log =~ "[FILTERED]"
      refute log =~ marker
      refute log =~ token
    after
      Logger.delete_module_level(modules)
      Enum.each(previous_levels, fn {module, level} -> Logger.put_module_level(module, level) end)
    end
  end

  test "LiveView mount diagnostics never dump People bearers on People or BO pages", %{
    conn: conn,
    challenge: c
  } do
    {:ok, %{token: token}} = PeopleAuth.verify_challenge(c.challenge_id, c.code)
    Zaq.PortalStubs.stub_portal_reachable()
    user = Zaq.AccountsFixtures.user_fixture()
    {:ok, user} = Zaq.Accounts.change_password(user, %{password: "StrongPass1!"})
    modules = [Phoenix.LiveView.Logger]
    previous_levels = Logger.get_module_level(modules)
    Logger.put_module_level(modules, :debug)

    try do
      for path <- ["/people/profile", "/bo/profile"] do
        log =
          ExUnit.CaptureLog.capture_log([level: :debug], fn ->
            {:ok, view, _} =
              conn
              |> init_test_session(%{person_session_token: token, user_id: user.id})
              |> live(path)

            assert render(view) =~ "Profile"
          end)

        # Mount-stop diagnostics remain enabled; only the raw session dump is purged.
        assert log =~ "Replied in"
        refute log =~ "Session:"
        refute log =~ token
      end
    after
      Logger.delete_module_level(modules)
      Enum.each(previous_levels, fn {module, level} -> Logger.put_module_level(module, level) end)
    end
  end

  test "CSRF protection rejects verify and logout without a token", %{conn: conn} do
    for {method, path} <- [
          {:post, "/people/session"},
          {:delete, "/people/session"},
          {:post, "/people/challenge"}
        ] do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        conn
        |> recycle()
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> dispatch(@endpoint, method, path, %{})
      end
    end
  end

  test "malformed verify input and anonymous logout never grant a session", %{conn: conn} do
    for params <- [%{}, %{"challenge_id" => "not-a-uuid"}, %{"challenge_id" => ["invalid"]}] do
      failed = conn |> recycle() |> post("/people/session", params)
      assert redirected_to(failed) == "/people/login"
      assert get_session(failed, :person_session_token) == nil
      assert get_session(failed, :person_login_challenge) == nil
    end

    assert conn |> recycle() |> delete("/people/session") |> redirected_to() == "/people/login"
  end

  test "logout clears local credentials and explains when Engine revocation is unavailable", %{
    conn: conn,
    challenge: c
  } do
    {:ok, %{token: token}} = PeopleAuth.verify_challenge(c.challenge_id, c.code)
    conn = conn |> init_test_session(%{person_session_token: token, user_id: 123})
    # Exercise actual NodeRouter discovery failure without restarting unrelated
    # Engine subsystems (Collector currently cannot reattach its telemetry id).
    engine = Process.whereis(Zaq.Engine.Supervisor)
    Process.unregister(Zaq.Engine.Supervisor)

    try do
      conn = delete(conn, "/people/session")
      assert get_session(conn, :person_session_token) == nil
      assert get_session(conn, :user_id) == 123
      {:ok, _, html} = live(recycle(conn), "/people/login")
      assert html =~ "Server revocation could not be confirmed"
    after
      Process.register(engine, Zaq.Engine.Supervisor)
    end

    assert {:ok, _} = PeopleAuth.authenticate(token)
  end

  test "failed verification retains the server-issued expiration", %{conn: conn, challenge: c} do
    descriptor = Map.take(c, [:challenge_id, :expires_at, :resend_available_at])

    conn =
      conn
      |> init_test_session(%{person_login_challenge: descriptor})
      |> post("/people/session", %{"challenge_id" => c.challenge_id, "code" => "invalid"})

    assert get_session(conn, :person_login_challenge) == descriptor
  end

  test "new email POST cannot bypass cooldown or acquire another browser's descriptor", %{
    conn: conn,
    person: person
  } do
    {:ok, person} = People.update_person(person, %{email: "held@example.test"})
    {:ok, issued} = PeopleAuth.issue_challenge(person, {127, 0, 1, 98})
    send(Zaq.Channels.PeopleAuthRateLimiter.Config, :refresh)
    _ = :sys.get_state(Zaq.Channels.PeopleAuthRateLimiter.Config)
    before = Repo.get!(PersonLoginChallenge, issued.challenge_id)
    failed = post(conn, "/people/challenge", %{"email" => person.email})
    assert get_session(failed, :person_login_challenge) == nil

    assert Phoenix.Flash.get(failed.assigns.flash, :error) ==
             "Unable to send a sign-in code. Please try again later."

    {:ok, _, html} = live(recycle(failed), "/people/login")
    refute html =~ "One-time code"
    assert Repo.get!(PersonLoginChallenge, issued.challenge_id) == before
    assert {:ok, _} = PeopleAuth.verify_challenge(issued.challenge_id, issued.code)
  end

  test "legacy descriptor renders enabled resend and unrelated verify cannot copy deadlines", %{
    conn: conn,
    challenge: c
  } do
    legacy = Map.take(c, [:challenge_id, :expires_at])
    conn = init_test_session(conn, %{person_login_challenge: legacy})
    {:ok, _, html} = live(conn, "/people/login")
    document = LazyHTML.from_fragment(html)
    assert LazyHTML.query(document, "#people-resend[disabled]") |> Enum.count() == 0
    assert html =~ "Resend code"
    id = Ecto.UUID.generate()

    failed =
      post(conn, "/people/session", %{
        "challenge_id" => id,
        "code" => "wrong",
        "expires_at" => "2090-01-01T00:00:00Z",
        "resend_available_at" => "2090-01-01T00:00:00Z"
      })

    assert get_session(failed, :person_login_challenge) == %{challenge_id: id, expires_at: nil}
  end

  test "public and protected People routes require Channels role", %{conn: conn} do
    previous = System.get_env("ROLES")
    System.put_env("ROLES", "bo")

    on_exit(fn ->
      if previous, do: System.put_env("ROLES", previous), else: System.delete_env("ROLES")
    end)

    assert conn |> get("/people/login") |> response(404) == "Not Found"
    assert conn |> recycle() |> get("/people/profile") |> response(404) == "Not Found"
    assert conn |> recycle() |> post("/people/challenge", %{}) |> response(404) == "Not Found"
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    assert {:halt, _} = AuthHook.on_mount(:public, %{}, %{}, socket)
    assert {:halt, _} = AuthHook.on_mount(:default, %{}, %{}, socket)
  end
end
