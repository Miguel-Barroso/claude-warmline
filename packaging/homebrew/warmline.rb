cask "warmline" do
  version "2.6.1"
  sha256 "c805f1ddd34826908bdfcd93de0a97edaced509398859057a6e5a813e49aa1a6"

  url "https://github.com/Miguel-Barroso/claude-warmline/archive/refs/tags/v#{version}.tar.gz"
  name "claude-warmline"
  desc "Make Claude Code's prompt cache state visible: statusline, auditor, keep-warm"
  homepage "https://github.com/Miguel-Barroso/claude-warmline"

  livecheck do
    url "https://github.com/Miguel-Barroso/claude-warmline.git"
    strategy :git
    regex(/^v?(\d+(?:\.\d+)+)$/i)
  end

  # No build step and no bundled runtime: two bash scripts and one python script,
  # all `#!/usr/bin/env`. python3 is required at runtime and both commands say so
  # plainly if it is missing, which is better than dragging a 60 MB python in for
  # scripts that run on the one already on the machine.
  binary "claude-warmline-#{version}/warmline"
  binary "claude-warmline-#{version}/warmline-audit"

  # A cask, not a formula, for one reason: this is the only way `brew install`
  # can leave you with a working statusline. A formula's post-install hook is
  # sandboxed with no way to declare an exception, so it cannot wire
  # ~/.claude/settings.json -- the user would have to run `warmline setup` by
  # hand, and again after every upgrade. Cask install steps are sandboxed too,
  # but `writable_paths` below names the one directory this touches, and
  # Homebrew grants read and write there. `setup` still refuses to replace a
  # statusLine that isn't warmline's without --force, so this installs warmline;
  # it does not silently take over.
  #
  # brew-setup is a thin wrapper around `warmline setup`: inside the sandbox
  # $HOME is a throwaway directory, so it resolves the account's real home from
  # the password database before wiring anything. See its comment for why.
  postflight_steps do
    run "claude-warmline-#{version}/packaging/homebrew/brew-setup", base: :staged_path,
        must_succeed: false, print_stdout: true,
        writable_paths: [".claude"], writable_base: :home
  end

  # Runs *before* the artifacts are removed, so the command still exists to undo
  # its own wiring. On upgrade both stanzas fire -- unwire, then wire the new
  # version -- which is what keeps an upgraded statusline from going stale.
  uninstall_preflight_steps do
    run "claude-warmline-#{version}/packaging/homebrew/brew-setup", base: :staged_path,
        args: ["--remove"], must_succeed: false, print_stdout: true,
        writable_paths: [".claude"], writable_base: :home
  end

  caveats <<~CAVEATS
    warmline is already wired into Claude Code -- `warmline status` shows what is on,
    and uninstalling unwires it again. Keeping the prompt cache warm through long
    waits is opt-in and stays off until you run `warmline keep-warm on`. AFK mode
    (type `afk`, the cache stays warm until you're back) is opt-in at your own
    account risk: `warmline afk enable` explains it and asks first.
  CAVEATS
end
