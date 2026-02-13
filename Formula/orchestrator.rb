class Orchestrator < Formula
  desc "Multi-agent task orchestrator for AI coding agents (claude, codex, opencode)"
  homepage "https://github.com/gabrielkoerich/orchestrator"
  url "https://github.com/gabrielkoerich/orchestrator/archive/refs/tags/v0.2.1.tar.gz"
  sha256 "5a13474861665d7e37783b950571185c3db4347173c8734309e6552cdf4b8112"
  head "https://github.com/gabrielkoerich/orchestrator.git", branch: "main"
  license "MIT"

  depends_on "yq"
  depends_on "jq"
  depends_on "just"
  depends_on "python@3"

  def install
    libexec.install "scripts", "prompts", "justfile"
    libexec.install Dir["*.example.yml"]
    libexec.install "tests" if (buildpath/"tests").exist?

    (bin/"orchestrator").write <<~EOS
      #!/usr/bin/env bash
      set -euo pipefail

      export PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
      export ORCH_HOME="${ORCH_HOME:-$HOME/.orchestrator}"

      mkdir -p "$ORCH_HOME"

      # State paths (persistent in user home)
      export TASKS_PATH="${TASKS_PATH:-$ORCH_HOME/tasks.yml}"
      export JOBS_PATH="${JOBS_PATH:-$ORCH_HOME/jobs.yml}"
      export CONFIG_PATH="${CONFIG_PATH:-$ORCH_HOME/config.yml}"
      export STATE_DIR="${STATE_DIR:-$ORCH_HOME/.orchestrator}"
      export CONTEXTS_DIR="${CONTEXTS_DIR:-$ORCH_HOME/contexts}"
      export LOCK_PATH="${LOCK_PATH:-$TASKS_PATH.lock}"

      # Code lives in Homebrew libexec
      cd "#{libexec}"
      exec just "$@"
    EOS
  end

  service do
    run [opt_bin/"orchestrator", "serve"]
    keep_alive true
    log_path var/"log/orchestrator.log"
    error_log_path var/"log/orchestrator.error.log"
  end

  def caveats
    <<~EOS
      To get started:
        cd ~/your-project
        orchestrator init         # configure project
        orchestrator add "title"  # add a task
        orchestrator serve        # start the server

      Background service (auto-start on login):
        brew services start orchestrator

      Required agent CLIs (install at least one):
        brew install --cask claude-code   # Claude
        brew install --cask codex         # Codex
        brew install opencode             # OpenCode

      Optional for GitHub sync:
        brew install gh && gh auth login
    EOS
  end

  test do
    assert_match "orchestrator", shell_output("#{bin}/orchestrator 2>&1", 0)
  end
end
