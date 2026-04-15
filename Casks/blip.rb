cask "blip" do
  version "1.0.0"
  sha256 :no_check # Updated per release

  url "https://github.com/blaineam/blip/releases/download/v#{version}/Blip.dmg"
  name "Blip"
  desc "Featherlight macOS menu bar system monitor"
  homepage "https://github.com/blaineam/blip"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Blip.app"

  zap trash: [
    "~/Library/Preferences/com.blainemiller.Blip.plist",
    "~/Library/Saved Application State/com.blainemiller.Blip.savedState",
  ]
end
