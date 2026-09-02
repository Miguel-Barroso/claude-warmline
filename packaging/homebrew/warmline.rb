class Warmline < Formula
  desc "Make Claude Code's prompt cache state visible: statusline, auditor, keep-warm"
  homepage "https://github.com/Miguel-Barroso/claude-warmline"
  url "https://github.com/Miguel-Barroso/claude-warmline/archive/refs/tags/v2.2.0.tar.gz"
  sha256 "REPLACE_WITH_SHA256_OF_THE_TAGGED_TARBALL"
  license "MIT"
  head "https://github.com/Miguel-Barroso/claude-warmline.git", branch: "main"

  # No build step and no bundled runtime: two bash scripts and one python
  # script, all `#!/usr/bin/env`. python3 is required at runtime and both
  # commands say so plainly if it is missing, which is better than dragging a
  # 60 MB python keg in for scripts that run on the one already on the machine.

  def install
    bin.install "warmline", "warmline-audit"
    # the statusline and the policy text are data, not commands: `warmline
    # setup` copies them into the Claude Code config dir, which is the one
    # place a package must never write to on its own
    pkgshare.install "statusline.py", "keep-warm.md"
    doc.install "README.md", "CHANGELOG.md", "LICENSE"
    doc.install Dir["docs/*.md"]
  end

  def caveats
    <<~EOS
      The commands are installed, but nothing is wired into Claude Code yet.
      A formula does not edit ~/.claude/settings.json behind your back:

        warmline setup            # installs the statusline and wires settings.json
        warmline status           # confirm
        warmline keep-warm on     # optional, off by default

      Re-run `warmline setup` after `brew upgrade warmline` to pick up a new
      statusline. To unwire without uninstalling: `warmline setup --remove`.
    EOS
  end

  test do
    # setup must not touch the real config dir during `brew test`
    ENV["CLAUDE_CONFIG_DIR"] = testpath/"claude"
    assert_match "claude-warmline", shell_output("#{bin}/warmline --help")
    system bin/"warmline", "setup"
    assert_path_exists testpath/"claude/warmline-statusline.py"
    assert_match "warmline-statusline.py", (testpath/"claude/settings.json").read
    payload = <<~JSON
      {"model": {"display_name": "Opus 5"},
       "workspace": {"current_dir": "#{testpath}"},
       "prompt_cache": {"warm": true, "caching_observed": true, "ttl": "1h"}}
    JSON
    assert_match "cache HOT",
      pipe_output("python3 #{testpath}/claude/warmline-statusline.py", payload, 0)
  end
end
