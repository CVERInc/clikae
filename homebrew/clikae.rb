# Homebrew formula template for clikae.
#
# To publish via a tap (recommended for v0.3+):
#   1. Create a separate repo: homebrew-<tapname>  (e.g. homebrew-clikae)
#   2. Copy this file into that repo as Formula/clikae.rb
#   3. Update `url` to a tagged release tarball, run `brew create` for the sha256
#   4. Users install with:  brew install CVERInc/<tapname>/clikae
#
# To submit to homebrew-core (later, once project has traction): see
# https://docs.brew.sh/Adding-Software-to-Homebrew

class Clikae < Formula
  desc "CLI profile switcher — manage multiple accounts/configs for any CLI"
  homepage "https://github.com/CVERInc/clikae"
  url "https://github.com/CVERInc/clikae/archive/refs/tags/v0.22.0.tar.gz"
  sha256 "d782eab8f39f0261ba27bcd8df8acded8ca2a56b9f7ea2c28838cf13ac0b2094"
  license "MIT"
  head "https://github.com/CVERInc/clikae.git", branch: "main"

  def install
    libexec.install "bin", "lib"
    libexec.install "assets" if File.directory?("assets") # welcome-screen logo (logo.txt)
    (bin/"clikae").write <<~SH
      #!/usr/bin/env bash
      exec "#{libexec}/bin/clikae" "$@"
    SH
    chmod 0755, bin/"clikae"

    pkgshare.install "README.md", "CHANGELOG.md", "LICENSE"
  end

  test do
    assert_match "clikae", shell_output("#{bin}/clikae version")
    assert_match "adapters", shell_output("#{bin}/clikae help")
  end
end
