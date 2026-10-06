import XCTest

// UI regressions for bugs these tests exposed (each fixed in its own commit).

final class SpeedServerRegressionTests: XCTestCase {
    /// Bug: the Speed tab read the self-hosted server address straight from UserDefaults in
    /// its body without observing it, so after entering an address in Settings and going
    /// back, the source menu still said "My server (not set)" and Configure still said
    /// "Set server…" until something unrelated re-rendered the screen.
    func testServerEnteredInSettingsShowsInSourceMenu() {
        let app = launchBlip(.seeded, ["-blip.route", "speed"])
        wait(app.el("speed.sourceMenu")).tap()
        wait(app.buttons["My server"]).tap()
        tap(app.el("speed.configure"), expecting: app.navigationBars["Settings"])
        let field = wait(app.el("settings.speedServer"))
        field.tap()
        field.typeText("192.0.2.50:3000")
        goBack(from: "Settings", to: "Speed", in: app)
        waitLabel(app.el("speed.sourceMenu"), contains: "192.0.2.50:3000")
        waitLabel(app.el("speed.configure"), contains: "Configure")
        app.el("speed.run").tap()
        waitLabel(app.el("speed.phase"), equals: "Mbps · down", 15)
        waitLabel(app.el("speed.result.down"), contains: "905 Mbps")
    }

}
