<!-- LOGO -->
<h1>
<p align="center">
  <img src="images/newicon/icon_1024.png" alt="ExGhostty" width="160">
  <br>ExGhostty
</h1>
<p align="center">
  <b>A brand-new SSH tool based on Ghostty.</b>
</p>
<p align="center">
   <b>English</b> · <a href="README_zh.md">简体中文</a>
</p>

---

## Why ExGhostty?

ExGhostty was born out of a genuine love for [Ghostty](https://ghostty.org) —
a fast, native, beautiful terminal emulator. But as much as we love Ghostty,
it was never designed to be a traditional **SSH tool**:

- **Ghostty doesn't fit the SSH-tool workflow.** Managing many remote hosts,
  jumping between them, transferring files, and keeping port forwards alive are
  things a plain terminal emulator simply doesn't help you with.
- **Ghostty's configuration is intimidating.** Everything is done by editing a
  text configuration file, which is a real barrier for newcomers who just want
  to connect to a server and get work done.
- **Terminals are falling behind the AI era.** With the rise of large language
  models, a traditional terminal that only echoes text can no longer keep up
  with how people actually want to work.

ExGhostty is **not** an attempt to build a bloated, do-everything tool. It
focuses on doing **SSH really well**, adds a small set of commonly needed
capabilities around it, and keeps a close, practical integration with **AI
 models**.

It is **free and open source** — no subscriptions, no ads, ever. The goal is
simply to offer another option, so that people who love Ghostty have one more
choice that fits the way they work.

---

## Features

### Core: SSH made easy
- **SSH connection manager** — organize hosts in groups, with password or
  key-based authentication, jump-host (bastion) support, per-host encoding,
  timeouts and keep-alive.
- **One-click connect** — double-click a host to open a session. Passwords are
  stored **AES-encrypted**, never in plain text.
- **Connection testing** — verify reachability and authentication before saving.
- **Local terminal** — a full Ghostty terminal is always one click away.

### SFTP file manager
- Browse remote directories alongside the terminal (follows `cd` in the shell).
- Upload / download files and folders with **rsync**, with **resume support**
  for unstable networks.
- Task window with per-task progress, pause / resume / cancel, and error
  details you can copy.

### Port forwarding
- Create **local (-L)**, **remote (-R)** and **dynamic (-D)** forwards.
- Start / stop with one click, automatic keep-alive and restart.
- Port-conflict detection with an option to kill the occupying process.

### Session reuse
- Attach to existing **tmux** and **zellij** sessions, create new ones, or
  detach — on both local and remote hosts.

### Code snippets
- Save frequently used shell / Python snippets in groups.
- Run a snippet in the current terminal with a double-click.

### System monitor
- Live CPU / memory / disk / network / GPU cards for local and remote hosts,
  powered by [xtop](https://github.com/rarnu/xtop).

### Docker management
- Browse containers, images, volumes and networks on remote hosts.
- Start / stop / restart / remove containers, view logs, remove images.

### Port usage
- See which process listens on which port — on the local Mac or on a remote
  host over SSH.

### AI assistant
- Chat with an LLM (OpenAI-compatible endpoint) with your **current terminal
  context** (directory, SSH host, title) included automatically.
- Commands and scripts in replies are shown in runnable blocks — copy them into
  the terminal with one click.

### And more
- **Quick Terminal** — a drop-down terminal summoned with a global hotkey.
- **Command Palette** and **split panes** for everyday terminal work.
- **Settings window** — configure everything through a native GUI (no hand
  editing of config files), including themes with previews and keybindings.
- **iCloud sync** — synchronize configuration, SSH hosts, port-forward rules
  and code snippets across your Macs via iCloud Drive.
- Built on the fast, native **Ghostty** terminal engine.

---

## ExGhostty for iPad

ExGhostty also runs on iPad. Since iOS has no system `ssh` binary, the iPad
version embeds the [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
terminal engine and the
[swift-nio-ssh](https://github.com/apple/swift-nio-ssh) SSH stack directly in
the app:

- **SSH connection manager** — password / private-key authentication, jump
  hosts, and automatic reconnect after the iPad locks or the app returns from
  the background.
- **Tabs** — multiple sessions side by side, including a built-in browser tab
  to open pages exposed by port-forward rules.
- **The same tool panels as the Mac version** — SFTP file manager, port
  forwarding (-L / -R / -D), tmux / zellij session reuse, Docker management,
  system monitor, port usage and the AI assistant.
- **574 built-in Ghostty / iTerm2 themes** and 5 built-in monospace fonts.
- Passwords and private keys are stored in the **iOS Keychain**.

### Physical keyboard support

The iPad version is built to work well with hardware keyboards (Magic
Keyboard, Bluetooth or USB-C):

- When a physical keyboard is connected, the on-screen Esc / Ctrl accessory
  bar **hides itself automatically** so the terminal uses the full screen;
  it comes back as soon as the keyboard disconnects.
- **Full IME support** — the candidate window for Chinese / Japanese / Korean
  input is anchored at the terminal cursor, just like on a desktop terminal.
- An **input-mode badge** on the toolbar always shows the active input method
  (中 / 繁 / EN / あ / 한 …).

### Installing on iPad with iLoader

The iPad app is not on the App Store; a pre-built IPA is provided on the
[Releases](https://github.com/rarnu/ExGhostty/releases) page. Sideload it
with [iLoader](https://github.com/nab138/iloader) (free and open source, runs
on Windows / macOS / Linux):

1. Download `ExGhostty.ipa` from
   [Releases](https://github.com/rarnu/ExGhostty/releases) onto your
   computer.
2. Connect the iPad to your computer with a USB cable and open **iLoader**.
3. Sign in with your Apple ID in iLoader, then pick the downloaded
   `ExGhostty.ipa` — iLoader signs it with your account and installs it on
   the device.
4. On the iPad, go to **Settings → General → VPN & Device Management** and
   trust your developer certificate; enable **Developer Mode** if prompted.

A free Apple ID signature is valid for **7 days** — re-sign with iLoader when
it expires (iLoader can also install SideStore for on-device refreshing). A
paid Apple Developer account signs for one year.

---

## Requirements

### macOS app
- macOS
- [Zig](https://ziglang.org) **0.15.2**
- Xcode (for building the macOS app)

### iPad app
- iPad running **iPadOS 26** or later
- Xcode (for building the iPad app) — project at
  `ipad/App/ExGhostty_iPad.xcodeproj`, scheme `ExGhostty_iPad`; dependencies
  resolve through local Swift packages, no extra setup needed

## Build

```bash
./release.sh
```

The release app bundle is produced at `zig-out/ExGhostty.app`.

For the iPad app, a pre-built IPA is available on
[Releases](https://github.com/rarnu/ExGhostty/releases) — see
[Installing on iPad with iLoader](#installing-on-ipad-with-iloader). To build
it from source instead, open `ipad/App/ExGhostty_iPad.xcodeproj` in Xcode and
build the `ExGhostty_iPad` scheme.

## Usage

1. Launch **ExGhostty**.
2. Use the **left sidebar** to create and manage SSH connections and local
   terminals.
3. Use the **right sidebar** to open the tools: SFTP, port forwarding, session
   reuse, system monitor, code snippets, and the AI assistant.
4. Open **Settings** to adjust appearance, themes, keybindings, sync and
   language — no config file editing required.

---

## License

ExGhostty is free and open source. See the repository for license details.