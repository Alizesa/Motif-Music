"""Decode the internal-test keystore into a private runner directory."""

import base64
import binascii
import os
from pathlib import Path


def prepare_test_signing(environment):
    required = ("MOTIF_TEST_KEYSTORE_BASE64", "RUNNER_TEMP", "GITHUB_ENV")
    missing = [name for name in required if not environment.get(name)]
    if missing:
        raise ValueError("Missing test-signing configuration: " + ", ".join(missing))
    try:
        data = base64.b64decode(environment["MOTIF_TEST_KEYSTORE_BASE64"], validate=True)
    except (ValueError, binascii.Error):
        raise ValueError("The internal-test keystore secret is not valid base64") from None
    if not data:
        raise ValueError("The internal-test keystore secret is empty")

    directory = Path(environment["RUNNER_TEMP"]) / "motif-test-signing"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = directory / "test-signing.p12"
    # Exclusive creation prevents silently reusing or overwriting an old key.
    with path.open("xb") as output:
        os.chmod(path, 0o600)
        output.write(data)
    with Path(environment["GITHUB_ENV"]).open("a", encoding="utf-8") as output:
        output.write("MOTIF_TEST_KEYSTORE_PATH=" + str(path) + "\n")
    return path


if __name__ == "__main__":
    try:
        prepare_test_signing(os.environ)
    except (ValueError, OSError) as error:
        raise SystemExit("Test signing setup failed: " + str(error)) from None
