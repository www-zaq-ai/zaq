"""Bootstrap only disposable provider services; never reads user credentials."""

import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid


def mapped_port(project, compose_file, service, port):
    address = subprocess.check_output(
        ["docker", "compose", "-p", project, "-f", compose_file, "port", service, str(port)],
        text=True,
    ).strip()
    return int(address.rsplit(":", 1)[1])


def ready(url):
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=5) as response:
                if response.status == 200:
                    return
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            pass
        # Bounded external service readiness, never test-journey synchronization.
        time.sleep(0.5)
    raise RuntimeError("disposable provider did not become ready within 300 seconds")


def main():
    project, compose_file, destination = sys.argv[1:]
    mm_url = f"http://127.0.0.1:{mapped_port(project, compose_file, 'mattermost', 8065)}"
    mailpit_url = f"http://127.0.0.1:{mapped_port(project, compose_file, 'mailpit', 8025)}"
    smtp_port = mapped_port(project, compose_file, "mailpit", 1025)
    # Reuse the real-server API/readiness helpers shipped by the locked adapter.
    repository = pathlib.Path(__file__).resolve().parents[3]
    upstream = repository / "deps/jido_chat_mattermost/.github/scripts/bootstrap_mattermost.py"
    spec = importlib.util.spec_from_file_location("zaq_mattermost_bootstrap", upstream)
    mattermost = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mattermost)
    mattermost.wait_ready(mm_url, 300)
    ready(mailpit_url + "/api/v1/info")
    username = "admin-" + uuid.uuid4().hex[:12]
    password = "Synthetic-" + uuid.uuid4().hex + "-123!"
    mattermost.request(mm_url, "/users", data={
        "username": username, "email": username + "@example.test", "password": password
    })
    _, headers = mattermost.request(mm_url, "/users/login", data={"login_id": username, "password": password})
    token = headers["Token"]

    services = {
        "mattermost_url": mm_url,
        "mattermost_admin_token": token,
        "smtp_host": "127.0.0.1",
        "smtp_port": smtp_port,
        "mailpit_url": mailpit_url,
    }
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(services, output)
    print("Disposable Mattermost and SMTP receiver ready; private runtime file created.")


if __name__ == "__main__":
    main()
