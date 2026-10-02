cask "figo" do
  # `version` and `sha256` are updated by scripts/release.sh --publish.
  version "0.1.0"
  sha256 "fa07a3a35eec6f73b0e27f55987e8cbdcf37169d564fd37b96ca879b3ef829bd"

  url "https://github.com/jorgemartins/figo/releases/download/v#{version}/Figo.zip"
  name "Figo"
  desc "Autocomplete popup for the terminal"
  homepage "https://github.com/jorgemartins/figo"

  # The released build is arm64-only; Intel Macs build from source instead.
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Figo.app"
  binary "#{appdir}/Figo.app/Contents/MacOS/figo"

  # Figo is not signed with an Apple developer certificate, so macOS would refuse to open a
  # copy that carries the "downloaded" flag. Clear it on every install and upgrade.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Figo.app"]
  end

  # Quit the running app before Homebrew replaces or removes the bundle.
  uninstall quit: "dev.figo.Figo"

  zap trash: [
    "~/.config/figo",
    "~/Library/Application Support/figo",
    "~/Library/Preferences/dev.figo.Figo.plist",
  ]

  caveats <<~EOS
    To finish, set up your shells and the input method, then open a new terminal window:
      figo install

    Run `figo install` again after every `brew upgrade --cask figo`.
    Run `figo uninstall` before `brew uninstall --cask figo`, so your shell startup
    files are restored first.
  EOS
end
