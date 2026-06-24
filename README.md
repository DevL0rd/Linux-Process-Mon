# Linux-Process-Mon

A native KDE Plasma 6 widget: a **searchable, sortable process tree** with
per-process **CPU**, **RAM** and **GPU** usage, styled to match the rest of the
suite (Router-Monitor, Log-Monitor, App Portal).

Processes nest under their parent and collapse; click a column header to sort,
type to filter.

## How it works (and why it's light)

A single resident helper (`bin/procmon-collect`) does all the work, exactly like
the router/log collectors:

* **One systemd `--user` service** (`linux-process-mon.service`) samples `/proc`
  and the GPU once per interval and writes a JSON snapshot to
  `$XDG_RUNTIME_DIR/Linux-Process-Mon/data.json`.
* **Pinned to the E-cores** (`CPUAffinity` from `bin/procmon-ecores`) and
  `Nice=19`, so it stays out of the way of foreground work.
* **The widget reads the snapshot in-process** via `file://` XHR (needs
  `QML_XHR_ALLOW_FILE_READ=1`, set by `install.sh` via `environment.d`) -- no
  process is spawned per refresh.

GPU usage is **per-process NVIDIA SM utilisation** from `nvidia-smi pmon`
(shows `0` on machines without an NVIDIA GPU, or for processes not using it).

## Install

Clone **with submodules** — the shared QML components live in the
[Linux-Plasma-Shared](https://github.com/DevL0rd/Linux-Plasma-Shared) submodule:

```sh
git clone --recurse-submodules https://github.com/DevL0rd/Linux-Process-Mon.git
cd Linux-Process-Mon
# already cloned without it?  git submodule update --init --recursive
./install.sh
```

Then add **Process Monitor** from *Add Widgets*. Uninstall with `./uninstall.sh`.

## Settings

Widget (right-click → Configure): panel icon, refresh interval, show kernel
threads, colorize CPU/GPU usage, GPU column.

Collector sampling rate: `poll_interval` (seconds) in
`~/.config/Linux-Process-Mon/config.json`.
