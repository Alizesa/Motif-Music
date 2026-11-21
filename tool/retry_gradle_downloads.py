"""Retry transient Gradle dependency downloads with a bounded backoff."""

import re
import subprocess
import sys
import time


RETRYABLE_NETWORK_ERROR = re.compile(
    r"Received status code (?:429|500|502|503|504)\b"
    r"|(?:Connect|Connection|Read) timed out"
    r"|Connection reset",
    re.IGNORECASE,
)


def run_with_retries(command, delays=(30, 60, 120), sleep=time.sleep):
    for attempt in range(len(delays) + 1):
        print(f"Gradle build attempt {attempt + 1}/{len(delays) + 1}", flush=True)
        retryable = False
        with subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        ) as process:
            for line in process.stdout:
                print(line, end="", flush=True)
                # Flutter can retry internally; classify the final Gradle failure.
                if "FAILURE: Build" in line:
                    retryable = False
                if RETRYABLE_NETWORK_ERROR.search(line):
                    retryable = True
            return_code = process.wait()

        if return_code == 0 or not retryable or attempt == len(delays):
            return return_code
        delay = delays[attempt]
        print(
            f"Transient Gradle download failure; retrying in {delay} seconds.",
            flush=True,
        )
        sleep(delay)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("Usage: retry_gradle_downloads.py command [arguments...]")
    try:
        raise SystemExit(run_with_retries(sys.argv[1:]))
    except OSError as error:
        raise SystemExit("Unable to start the CI build command: " + str(error)) from None
