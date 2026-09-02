cask "warmline" do
  version "2.2.1"
  sha256 "fe675d8d5fbb8f5508674c7c71aaa69a2e8aaf007d5b2d75fb23eabc99556a84"

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
  # can leave you with a working statusline. A formula's post_install runs under
  # a sandbox that denies reading $HOME at all, so it cannot wire
  # ~/.claude/settings.json -- the user would have to run `warmline setup` by
  # hand, and again after every upgrade. Cask flight blocks are not sandboxed.
  # `setup` still refuses to replace someone else's statusline without --force,
  # so this installs warmline; it does not silently take over.
  postflight do
    system_command "#{staged_path}/claude-warmline-#{version}/warmline",
                   args: ["setup"], must_succeed: false, print_stdout: true
  end

  # Runs *before* the artifacts are removed, so the command still exists to undo
  # its own wiring. On upgrade both blocks fire -- unwire, then wire the new
  # version -- which is what keeps an upgraded statusline from going stale.
  uninstall_preflight do
    system_command "#{staged_path}/claude-warmline-#{version}/warmline",
                   args: ["setup", "--remove"], must_succeed: false, print_stdout: true
  end

  caveats <<~CAVEATS
    warmline is already wired into Claude Code -- `warmline status` shows what is on,
    and uninstalling unwires it again. Keeping the prompt cache warm through long
    waits is opt-in and stays off until you run `warmline keep-warm on`.
  CAVEATS
end
