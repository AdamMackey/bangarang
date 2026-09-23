# Runs a throwaway `claude --bare` in a pseudo-terminal of a given size, with a test
# status line, and prints the screen it draws (as a terminal emulator sees it).
# usage: venv/bin/python tui-harness.py COLS ROWS SETTINGS_JSON SECONDS [RAWFILE] [KEYS_AT:SECONDS:TEXT ...]
import fcntl, json, os, pty, select, signal, struct, sys, termios, time
import pyte

cols, rows = int(sys.argv[1]), int(sys.argv[2])
settings, seconds = sys.argv[3], float(sys.argv[4])
rawfile = sys.argv[5] if len(sys.argv) > 5 else None
keys = []
for k in sys.argv[6:]:
    at, text = k.split(":", 1)
    keys.append((float(at), text.encode().decode("unicode_escape").encode()))

pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    env = dict(os.environ, TERM="xterm-256color", COLORTERM="truecolor", TERM_PROGRAM="Apple_Terminal", CLAUDE_CODE_SANDBOXED="1", CLAUDE_CODE_NO_FLICKER="1")
    if os.environ.get("HARNESS_TRUST") == "ask":
        env.pop("CLAUDE_CODE_SANDBOXED")   # show the real trust prompt
    if os.environ.get("HARNESS_CWD"):
        os.chdir(os.environ["HARNESS_CWD"])
    extra = json.loads(os.environ.get("HARNESS_ARGS", "[]"))
    os.execvpe("claude", ["claude", "--bare", "--strict-mcp-config", "--settings", settings] + extra, env)

class Screen(pyte.Screen):
    # pyte has no private (DEC) device status reports; ignore those queries
    def report_device_status(self, mode, **kw):
        if not kw.get("private"):
            super().report_device_status(mode)

screen = Screen(cols, rows)
stream = pyte.ByteStream(screen)
# answer the terminal queries pyte knows (cursor position, device attributes)
screen.write_process_input = lambda data: os.write(fd, data.encode())
raw = bytearray()
chunks = []
start = time.time()
while time.time() - start < seconds:
    now = time.time() - start
    while keys and keys[0][0] <= now:
        os.write(fd, keys.pop(0)[1])
    r, _, _ = select.select([fd], [], [], 0.1)
    if r:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        raw += data
        chunks.append((round(time.time() - start, 3), data))
        stream.feed(data)
if rawfile:
    open(rawfile, "wb").write(bytes(raw))
    import pickle
    pickle.dump(chunks, open(rawfile + ".chunks", "wb"))
lines = screen.display
last = max((i for i, l in enumerate(lines) if l.strip()), default=0)
for i, l in enumerate(lines[: last + 1]):
    print(f"{i:02d}|{l.rstrip()}", flush=True)
# Close our end first: a process exiting on a tty waits for its output to drain,
# and nobody is reading any more.
os.close(fd)
os.kill(pid, signal.SIGKILL)
os.waitpid(pid, 0)
