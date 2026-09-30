import os
import re
import shutil
import signal
import subprocess
import threading
import time
import pytest
from utils import *

# llama-cli, next to the llama-server under test unless LLAMA_CLI_BIN_PATH names it
if "LLAMA_CLI_BIN_PATH" in os.environ:
    CLI_PATH = os.environ["LLAMA_CLI_BIN_PATH"]
elif "LLAMA_SERVER_BIN_PATH" in os.environ:
    CLI_PATH = os.path.join(os.path.dirname(os.environ["LLAMA_SERVER_BIN_PATH"]), "llama-cli")
elif os.name == "nt":
    CLI_PATH = "../../../build/bin/Release/llama-cli.exe"
else:
    CLI_PATH = "../../../build/bin/llama-cli"

LOCAL_MODEL = ["-hf", "ggml-org/test-model-stories260K", "--offline"]  # downloaded by load_all()
TIMEOUT = 60


class CliProcess:
    """llama-cli with piped input; its output is collected by a thread."""

    def __init__(self, args: list[str]):
        env = {**os.environ}
        if "LLAMA_CACHE" not in env:
            env["LLAMA_CACHE"] = "tmp"
        self.proc = subprocess.Popen(
            [CLI_PATH, "--simple-io", "--seed", "42", *args],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env,
        )
        self.output = ""
        self.lock = threading.Lock()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        assert self.proc.stdout is not None
        while True:
            data = self.proc.stdout.read1(4096)  # type: ignore[attr-defined]
            if not data:
                return
            with self.lock:
                self.output += data.decode("utf-8", errors="replace")

    def text(self) -> str:
        with self.lock:
            return self.output

    def wait_for(self, pattern: str, start: int = 0, timeout: float = TIMEOUT) -> re.Match:
        deadline = time.time() + timeout
        while time.time() < deadline:
            match = re.compile(pattern, re.MULTILINE).search(self.text(), start)
            if match:
                return match
            if self.proc.poll() is not None:
                self.reader.join(5)
                match = re.compile(pattern, re.MULTILINE).search(self.text(), start)
                if match:
                    return match
                break
            time.sleep(0.02)
        raise AssertionError(f"'{pattern}' not found in output:\n{self.text()}")

    def send(self, line: str):
        assert self.proc.stdin is not None
        self.proc.stdin.write((line + "\n").encode())
        self.proc.stdin.flush()

    def interrupt(self):
        self.proc.send_signal(signal.SIGINT)

    def finish(self, timeout: float = TIMEOUT) -> int:
        if self.proc.stdin and not self.proc.stdin.closed:
            self.proc.stdin.close()
        code = self.proc.wait(timeout)
        self.reader.join(5)
        return code

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()


@pytest.fixture
def cli_processes():
    started: list[CliProcess] = []
    yield started
    for cli in started:
        cli.kill()


def run_cli(cli_processes, args: list[str]) -> CliProcess:
    cli = CliProcess(args)
    cli_processes.append(cli)
    return cli


def test_cli_local_single_turn(cli_processes):
    cli = run_cli(cli_processes, [*LOCAL_MODEL, "-p", "Once upon a time", "-st", "-n", "16"])
    assert cli.finish() == 0
    out = cli.text()
    assert re.search(r"^model +: .*stories260K", out, re.MULTILINE)
    assert "> Once upon a time" in out
    assert re.search(r"\[ Prompt: [\d.]+ t/s \| Generation: [\d.]+ t/s \]", out)
    assert "Exiting..." in out


@pytest.mark.skipif(shutil.which("lsof") is None or shutil.which("pgrep") is None, reason="needs lsof and pgrep")
def test_cli_local_no_server_nor_child(cli_processes):
    cli = run_cli(cli_processes, [*LOCAL_MODEL, "-n", "8"])
    cli.wait_for(r"available commands")
    pid = str(cli.proc.pid)
    # the model is loaded in this process: no socket, no child process
    sockets = subprocess.run(["lsof", "-a", "-p", pid, "-i"], capture_output=True, text=True)
    assert sockets.stdout.strip() == "", sockets.stdout
    children = subprocess.run(["pgrep", "-P", pid], capture_output=True, text=True)
    assert children.stdout.strip() == "", children.stdout
    cli.send("/exit")
    assert cli.finish() == 0


def test_cli_local_multi_turn_and_output_file(cli_processes, tmp_path):
    out_file = tmp_path / "chat.txt"
    cli = run_cli(cli_processes, [*LOCAL_MODEL, "-n", "8", "-o", str(out_file)])
    cli.wait_for(r"available commands")
    for line in ["Hello", "Tell me more", "/regen", "/clear", "Again", "/exit"]:
        cli.send(line)
    assert cli.finish() == 0
    out = cli.text()
    assert len(re.findall(r"\[ Prompt: ", out)) == 4
    assert "Chat history cleared." in out
    written = out_file.read_text()
    assert written.count("User:\n") == 3
    assert written.count("Assistant:\n") == 4


def test_cli_local_interrupt_then_new_request(cli_processes):
    # a generation of 8192 tokens at most: long enough to be interrupted
    cli = run_cli(cli_processes, [*LOCAL_MODEL, "-c", "8192", "-n", "-1", "--ignore-eos"])
    start = cli.wait_for(r"available commands").end()
    cli.send("Tell me a long story")
    first = cli.wait_for(r"> \S", start)  # piped input is not echoed: generated text
    time.sleep(0.2)
    t0 = time.time()
    cli.interrupt()
    timings = cli.wait_for(r"\[ Prompt: [\d.]+ t/s \| Generation: [\d.]+ t/s \]", first.end(), timeout=10)
    assert time.time() - t0 < 5, "the generation was not interrupted"
    # the session goes on: a new request is answered
    cli.send("Another one")
    cli.wait_for(r"\[ Prompt: ", timings.end())
    cli.send("/exit")
    assert cli.finish() == 0


def test_cli_local_model_errors(cli_processes, tmp_path):
    missing = run_cli(cli_processes, ["-m", str(tmp_path / "missing.gguf"), "-p", "hi", "-st"])
    assert missing.finish() == 1
    assert "Error: failed to load the model" in missing.text()

    not_cached = run_cli(cli_processes, ["-hf", "ggml-org/non-existent-model-for-cli-test", "--offline", "-p", "hi", "-st"])
    assert not_cached.finish() == 1
    assert "Error: failed to load the model" in not_cached.text()

    no_model = run_cli(cli_processes, ["-p", "hi", "-st"])
    assert no_model.finish() == 1
    assert "Error: no model specified" in no_model.text()


def test_cli_remote_single_model(cli_processes):
    server = ServerPreset.tinyllama2()
    server.start()
    cli = run_cli(cli_processes, ["--server-base", f"http://{server.server_host}:{server.server_port}",
                                  "-p", "Once upon a time", "-st"])
    assert cli.finish() == 0
    out = cli.text()
    assert re.search(r"^model +: tinyllama-2$", out, re.MULTILINE)
    assert re.search(r"\[ Prompt: [\d.]+ t/s \| Generation: [\d.]+ t/s \]", out)


def test_cli_remote_router(cli_processes):
    server = ServerPreset.router()
    server.start()
    cli = run_cli(cli_processes, ["--server-base", f"http://{server.server_host}:{server.server_port}", "-n", "8"])
    cli.wait_for(r"Select model by number: ")
    match = re.search(r"^ +(\d+)\. (ggml-org/test-model-stories260K(:\S+)?)( |$)", cli.text(), re.MULTILINE)
    assert match, cli.text()
    cli.send(match.group(1))
    start = cli.wait_for(r"available commands").end()
    assert f"Selected model: {match.group(2)}" in cli.text()
    cli.send("Hello")
    cli.wait_for(r"\[ Prompt: [\d.]+ t/s \| Generation: [\d.]+ t/s \]", start)
    cli.send("/exit")
    assert cli.finish() == 0


def test_cli_remote_errors(cli_processes):
    # nothing listens on this port
    unreachable = run_cli(cli_processes, ["--server-base", "http://127.0.0.1:9", "-p", "hi", "-st"])
    assert unreachable.finish() == 1
    assert "Error: failed to connect to http://127.0.0.1:9" in unreachable.text()

    # an HTTP error during the chat is shown, the session goes on
    server = ServerPreset.bert_bge_small()
    server.start()
    cli = run_cli(cli_processes, ["--server-base", f"http://{server.server_host}:{server.server_port}"])
    start = cli.wait_for(r"available commands").end()
    cli.send("Hello")
    cli.wait_for(r"Error: ", start)
    cli.send("/exit")
    assert cli.finish() == 0
