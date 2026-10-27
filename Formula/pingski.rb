class Pingski < Formula
  desc "Lightweight macOS notification daemon with an HTTP + OpenAPI interface"
  homepage "https://github.com/looskis/pingski"
  url "https://github.com/looskis/pingski/releases/download/v0.1.0/pingski-0.1.0-macos-universal.tar.gz"
  # Filled in by the Release workflow (sha256 of the universal tarball it builds).
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/looskis/pingski.git", branch: "main"

  depends_on macos: :ventura

  def install
    if build.head?
      # Build from source: needs a Swift 5.9+ toolchain (Xcode or Command Line Tools).
      system "make", "install", "PREFIX=#{prefix}", "SWIFT_FLAGS=--disable-sandbox"
    else
      # Prebuilt universal (arm64 + x86_64) Pingski.app plus a launcher that resolves its own location.
      prefix.install "Pingski.app"
      bin.install "bin/pingski"
    end
  end

  def post_install_steps
    # Register the bundle with LaunchServices so macOS can show the permission prompt and route clicks.
    lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework" \
                 "/Support/lsregister"
    system lsregister, "-f", prefix/"Pingski.app" if File.exist?(lsregister)
  end

  def caveats
    <<~EOS
      The first time pingski delivers a notification macOS asks for permission.
      Click "Allow" in the prompt. If you dismissed it, enable Pingski under
      System Settings > Notifications. Use `pingski --provisional` for quiet,
      prompt-free delivery to Notification Center.

      Run as a background service (user LaunchAgent):
        brew services start pingski
      Change the port or add a token with environment variables in
        #{etc}/pingski.env  (PINGSKI_PORT, PINGSKI_HOST, PINGSKI_TOKEN, PINGSKI_WEBHOOK)
      or run it yourself: pingski --port 8080
    EOS
  end

  service do
    run [opt_bin/"pingski"]
    keep_alive true
    environment_variables PINGSKI_ENV_FILE: etc/"pingski.env"
    log_path var/"log/pingski.log"
    error_log_path var/"log/pingski.log"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/pingski --version")
    assert_match "openapi", shell_output("#{bin}/pingski openapi")
    assert_path_exists prefix/"Pingski.app/Contents/Info.plist"
  end
end
