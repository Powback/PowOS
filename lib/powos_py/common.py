"""powos_py.common - the helpers every PowOS Python tool used to paste for itself (docs/CLEANUP.md, item 1): the owner
config and the device's SpacetimeDB identity. Stdlib only.

Installed wherever lib/ is: the x86 image (Containerfile `COPY lib/ /usr/lib/powos/`), the phone (powos-core's
self_phone_apply copies all of lib/; the rooted deploy installs it next to its tools, targets/android/rooted), the Mac
(the repo). A tool finds it next to its own directory:

    HERE = os.path.dirname(os.path.realpath(__file__))
    sys.path.append(next((d for d in (HERE, os.path.dirname(HERE), os.path.dirname(os.path.dirname(HERE)))
                          if os.path.isdir(os.path.join(d, "powos_py"))), "/usr/lib/powos"))
    from powos_py.common import owner_conf  # noqa: E402

(lib/apps/x and lib/devices/x: one level up; lib/ai/agents/x: two; a tool copied out on its own, like
tools/agents/board-sweep.sh's CLI, gets a powos_py/ beside it.)
"""
import os

OWNER_CONF_PATHS = ("/etc/powos/owner.conf", "~/.config/powos/owner.conf")
SPACETIME_CLI_TOML = "~/.config/spacetime/cli.toml"


def owner_conf(key):
    """One setting of the owner's devices: $KEY, else KEY=value in the owner config - $POWOS_OWNER_CONF, else
    /etc/powos/owner.conf, else ~/.config/powos/owner.conf (the first that exists; powos-deviced owner_apply writes it
    when the device pairs with the owner's hub and removes it on unpair). As a shell sourcing it would read it: the
    last setting wins, surrounding quotes go. A fresh device has none: "" = not configured."""
    if os.environ.get(key):
        return os.environ[key]
    p = os.environ.get("POWOS_OWNER_CONF")
    for path in [p] if p is not None else [os.path.expanduser(x) for x in OWNER_CONF_PATHS]:
        try:
            with open(path) as f:
                lines = f.read().splitlines()
        except OSError:
            continue
        val = ""
        for line in lines:
            k, sep, v = line.strip().partition("=")
            if sep and k.strip() == key:
                val = v.strip()
        return val[1:-1] if len(val) > 1 and val[0] == val[-1] and val[0] in "\"'" else val
    return ""


def token():
    """This device's SpacetimeDB identity token (the spacetime CLI's login, ~/.config/spacetime/cli.toml), or None."""
    try:
        with open(os.path.expanduser(SPACETIME_CLI_TOML)) as f:
            for line in f:
                k, _, v = line.partition("=")
                if k.strip() == "spacetimedb_token":
                    return v.strip().strip('"')
    except OSError:
        pass
    return None
