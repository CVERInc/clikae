# Homebrew formula for clikae.
#
# 🔴 THIS FILE IS NOT WHAT ANYONE INSTALLS. `brew` reads
# CVERInc/homebrew-clikae/Formula/clikae.rb — a DIFFERENT REPOSITORY. This is a
# copy, and copies drift: it was bumped for 0.28.0, 0.28.1 and 0.28.2 while the
# tap sat at 0.27.0, so three tagged, released, changelogged versions reached
# nobody. The maintainer found out by noticing his own clikae was five releases
# behind while running code that fixed his own bug reports.
#
# So updating this file is not releasing. Releasing is:
#   1. tag + push        (v<x.y.z>)
#   2. download the tarball GitHub actually SERVES, sha256 it, extract it, RUN it
#   3. update THIS copy
#   4. update the TAP's Formula/clikae.rb with the same url + sha256, and push it
#
# Step 4 is the one that ships. If you only did the others, nothing happened.
#
# To submit to homebrew-core (later, once project has traction): see
# https://docs.brew.sh/Adding-Software-to-Homebrew

class Clikae < Formula
  desc "CLI profile switcher — manage multiple accounts/configs for any CLI"
  homepage "https://github.com/CVERInc/clikae"
  url "https://github.com/CVERInc/clikae/archive/refs/tags/v0.28.3.tar.gz"
  sha256 "16dcfbf70e0ce6154c0bb8fca4d7ff07e1304d8c514226e5af73a096d359a10b"
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
