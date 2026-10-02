# Figo

Autocomplete for the terminal: a popup at your cursor that suggests subcommands, options,
files, branches, scripts and so on as you type. A from-scratch homage to Fig's autocomplete,
doing that one thing and nothing else: no account, no telemetry, no AI.

It uses the community completion specs from [withfig/autocomplete](https://github.com/withfig/autocomplete),
so any CLI Fig knew about works here.

- **Terminals:** Terminal.app, iTerm2 and Ghostty are tested. The terminals built into VS Code,
  Cursor and other apps, and tmux, are meant to work but have had little testing.
- **Shells:** zsh, bash, fish.
- **Needs:** macOS 14 or later, on Apple Silicon for the released build.

Figo is not affiliated with or endorsed by Fig, Amazon or Kiro.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/jorgemartins/figo/main/install.sh | sh
```

Then open a new terminal window and type a command.

The script downloads the latest release into `/Applications/Figo.app` and runs `figo install`,
which:

- copies the shell scripts and the wrapper to `~/Library/Application Support/figo`,
- adds two lines to your shell startup files, backing each one up first,
- installs an input method that tells Figo where the text cursor is (it never handles keys),
- starts the menu-bar app.

It also downloads the themes Fig shipped (dracula, nightowl, solarized, …) from
[withfig/themes](https://github.com/withfig/themes) into `~/.config/figo/themes`.

Options go after `sh -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/jorgemartins/figo/main/install.sh | sh -s -- --disable-conflicts
```

| Option | What it does |
| --- | --- |
| `--disable-conflicts` | Comments out the lines Kiro CLI, Amazon Q or Fig added to your startup files, so two popups do not fight. `figo uninstall` restores them. |
| `--shells zsh,fish` | Sets up only these shells. |
| `--no-themes` | Skips downloading Fig's themes. |

Run the same command again to update. `figo doctor` checks every piece, and `figo uninstall`
undoes everything `figo install` did (then drag Figo.app to the Trash).

### With Homebrew

```bash
brew trust --tap jorgemartins/figo
brew tap jorgemartins/figo https://github.com/jorgemartins/figo
brew install --cask figo
figo install
```

The first two lines tell Homebrew about this repository, which carries its own cask, and are
only needed once. `figo install` is the setup step described above, which Homebrew does not run
for you. Then open a new terminal window.

- **Fig's themes** are not part of the Homebrew package. To add them:
  `curl -fsSL https://raw.githubusercontent.com/jorgemartins/figo/main/install.sh | sh -s -- --themes-only`
- **Updating:** `brew upgrade --cask figo`, then `figo install` again.
- **Removing:** `figo uninstall`, then `brew uninstall --cask figo`.

Use one way of installing or the other, not both: the curl script replaces
`/Applications/Figo.app` without telling Homebrew.

### About the "unidentified developer" warning

Figo is not signed with an Apple developer certificate. Installed in either way above, it
opens normally. If you download `Figo.zip` from the releases page with a browser instead,
macOS will refuse to open it until you clear the download flag:

```bash
xattr -dr com.apple.quarantine /Applications/Figo.app
```

Then run `/Applications/Figo.app/Contents/MacOS/figo install`.

## Use

Type a command. The popup follows the cursor.

| Key | Action |
| --- | --- |
| ↑ ↓ (also ⌃P ⌃N, ⇧⇥) | Move the selection |
| ⏎ | Insert the selected suggestion |
| ⇥ | Insert the part all suggestions share |
| ⎋ | Hide until the next command line |
| ⌃K | Move the description between the footer and a side panel |
| ⌃R | Shell history |

Settings (theme, font, sizes, keys) are in the menu-bar item, or `figo settings`. They are
stored in `~/.config/figo/settings.json`.

- **Themes:** `figo theme` lists them. Your own, in Fig's JSON format, go in `~/.config/figo/themes`.
- **Completion specs:** your own go in `~/.config/figo/specs` and take precedence over the bundled ones.

## How it works

```
terminal ⇄ figoterm ⇄ your shell           figoterm: a pty wrapper. Passes everything through,
              │                             learns the command line from the shell integration,
              │ unix socket                 takes over a few keys while the popup is open.
              ▼
           Figo.app ⇄ popup (web page)      The menu-bar app places a transparent window at the
              ▲                             text cursor; the page inside it turns the command
              │                             line into suggestions using the completion specs.
      FigoInputMethod                       Tells the app where the text cursor is on screen.
```

| Path | What |
| --- | --- |
| `Sources/FigoCore` | Socket protocol and file locations shared by every native part |
| `Sources/FigoTermKit`, `Sources/figoterm` | The pty wrapper |
| `Sources/FigoAppKit`, `Sources/FigoApp` | The menu-bar app: sessions, popup window, web bridge, settings |
| `Sources/FigoInputMethod` | The input method helper that reports the caret position |
| `Sources/FigoInstallKit` | Installing the shell integration and the input method |
| `Sources/figo` | The `figo` command |
| `shell/` | Integration scripts for zsh, bash and fish |
| `web/` | The popup: `src/core` (completion engine), `src/ui` (React), `src/bridge` (contract with the app) |
| `specs/` | Builds the completion specs at a pinned commit |
| `Casks/` | The Homebrew cask; this repository doubles as its own tap |

## Build from source

Needs Xcode (Swift 6), Node 22 and pnpm.

```bash
pnpm --dir web install && pnpm --dir specs install
scripts/bundle.sh          # builds build/Figo.app
scripts/dev-install.sh     # copies it to /Applications and runs `figo install`
```

`scripts/bundle.sh --skip-web` rebuilds only the native parts. A build made this way includes
Fig's themes, fetched at build time; that repository has no licence, so they are not kept in
this one.

### Test

```bash
swift test                                         # native unit tests
pnpm --dir web exec vitest run                     # engine and UI
python3 -m unittest discover -s Tests/e2e          # real shells under the wrapper, and the full stack
```

The end-to-end tests start real zsh, bash and fish in pseudo-terminals with an isolated home
directory; they never touch your own configuration. `figoterm --benchmark <file>` reports how
fast the wrapper processes terminal output.

### Release

```bash
scripts/release.sh             # builds build/release/Figo.zip and its checksum
scripts/release.sh --publish   # also creates the GitHub release v<version>
```

The version comes from `Sources/FigoCore/Figo.swift`. `install.sh` always installs the latest
release, and `--publish` also commits and pushes `Casks/figo.rb` pointing at the new version,
so publishing is all it takes to ship an update. A release leaves Fig's themes out;
`install.sh` fetches them on each Mac.

### Debugging

- `figo status` shows what the app knows: sessions, the current command line, what the popup is showing.
- Logs are in `~/Library/Application Support/figo/logs`. `FIGO_LOG_LEVEL=debug` says more.
- `FIGO_TERM_TRACE=<file>` makes a wrapper record everything its shell writes.
- `FIGO_DISABLED=1` starts a shell without the wrapper.

## Licence

[MIT](LICENSE). Third-party work that ships in the app is listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
