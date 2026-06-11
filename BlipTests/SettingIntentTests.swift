import XCTest
@testable import Blip

@MainActor
final class SettingIntentTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = Fixtures.scratchDefaults("settings")
        AppIntentsEnvironment.defaults = defaults
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: "com.blainemiller.BlipTests.settings")
        AppIntentsEnvironment.defaults = .standard
    }

    // MARK: Catalog

    func testCatalogHasNoSecretsAndNoDuplicates() {
        let keys = BlipSettingDescriptor.catalog.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count)
        // SECRETS RULE: nothing currently exposed may be secret, and nothing
        // secret-ish (tokens, credentials) may be in the catalog at all.
        for d in BlipSettingDescriptor.catalog {
            XCTAssertFalse(d.isSecret)
            for fragment in ["token", "secret", "password", "credential", "key"] {
                XCTAssertFalse(d.key.lowercased().contains(fragment), "\(d.key) looks like a secret")
            }
        }
        // launchAtLogin must NOT be scriptable: toggling the default alone
        // wouldn't (de)register the SMAppService.
        XCTAssertNil(BlipSettingDescriptor.descriptor(for: "launchAtLogin"))
    }

    // MARK: Entity query

    func testQueryResolvesAndMatches() async throws {
        let byID = try await SettingEntityQuery().entities(for: ["pingTarget", "bogus"])
        XCTAssertEqual(byID.map(\.id), ["pingTarget"])

        let suggested = try await SettingEntityQuery().suggestedEntities()
        XCTAssertEqual(suggested.count, BlipSettingDescriptor.catalog.count)

        let matched = try await SettingEntityQuery().entities(matching: "menu bar")
        XCTAssertTrue(matched.map(\.id).contains("menuBarLayout"))
    }

    // MARK: Store logic (pure)

    func testBoolParsing() {
        for t in ["true", "TRUE", "yes", "on", "1"] { XCTAssertEqual(SettingsStore.parseBool(t), true, t) }
        for f in ["false", "no", "OFF", "0"] { XCTAssertEqual(SettingsStore.parseBool(f), false, f) }
        for bad in ["maybe", "", "2"] { XCTAssertNil(SettingsStore.parseBool(bad), bad) }
    }

    func testReadFallsBackToDefaults() {
        let showCPU = BlipSettingDescriptor.descriptor(for: "showCPU")!
        XCTAssertEqual(SettingsStore.read(showCPU, from: defaults), "true")
        defaults.set(false, forKey: "showCPU")
        XCTAssertEqual(SettingsStore.read(showCPU, from: defaults), "false")

        let ping = BlipSettingDescriptor.descriptor(for: "pingTarget")!
        XCTAssertEqual(SettingsStore.read(ping, from: defaults), "1.1.1.1")
        defaults.set("8.8.8.8", forKey: "pingTarget")
        XCTAssertEqual(SettingsStore.read(ping, from: defaults), "8.8.8.8")
    }

    func testNormalizeBoolean() {
        let d = BlipSettingDescriptor.descriptor(for: "showDisk")!
        XCTAssertEqual(SettingsStore.normalize(" Yes ", for: d), .value("true"))
        XCTAssertEqual(SettingsStore.normalize("0", for: d), .value("false"))
        XCTAssertEqual(SettingsStore.normalize("sideways", for: d), .error("must be true or false"))
    }

    func testNormalizeChoice() {
        let d = BlipSettingDescriptor.descriptor(for: "menuBarLayout")!
        XCTAssertEqual(SettingsStore.normalize("Stacked", for: d), .value("stacked"))
        XCTAssertEqual(SettingsStore.normalize("horizontal", for: d), .value("horizontal"))
        if case .error = SettingsStore.normalize("diagonal", for: d) {} else {
            XCTFail("expected error for unknown choice")
        }
    }

    func testNormalizeHost() {
        let d = BlipSettingDescriptor.descriptor(for: "pingTarget")!
        XCTAssertEqual(SettingsStore.normalize("9.9.9.9", for: d), .value("9.9.9.9"))
        XCTAssertEqual(SettingsStore.normalize("", for: d), .value(""))  // clearing is allowed
        if case .error = SettingsStore.normalize("bad host!", for: d) {} else {
            XCTFail("expected error for invalid host")
        }
    }

    func testNormalizeServerURL() {
        let d = BlipSettingDescriptor.descriptor(for: "speedTestOpenSpeedTestURL")!
        XCTAssertEqual(SettingsStore.normalize("192.168.1.50:3000", for: d), .value("192.168.1.50:3000"))
        XCTAssertEqual(SettingsStore.normalize("", for: d), .value(""))  // reverts to public
    }

    // MARK: Intents

    func testGetSettingReadsValue() async throws {
        defaults.set("stacked", forKey: "menuBarLayout")
        let intent = GetSettingIntent()
        intent.setting = SettingEntity(descriptor: BlipSettingDescriptor.descriptor(for: "menuBarLayout")!)
        let result = try await intent.perform()
        XCTAssertEqual(result.value, "stacked")
    }

    func testSetSettingWritesBool() async throws {
        let intent = SetSettingIntent()
        intent.setting = SettingEntity(descriptor: BlipSettingDescriptor.descriptor(for: "showCPU")!)
        intent.value = "no"
        _ = try await intent.perform()
        XCTAssertEqual(defaults.object(forKey: "showCPU") as? Bool, false)
    }

    func testSetSettingWritesValidatedHost() async throws {
        let intent = SetSettingIntent()
        intent.setting = SettingEntity(descriptor: BlipSettingDescriptor.descriptor(for: "tracerouteTarget")!)
        intent.value = "one.one.one.one"
        _ = try await intent.perform()
        XCTAssertEqual(defaults.string(forKey: "tracerouteTarget"), "one.one.one.one")
    }

    func testSetSettingRejectsInvalidValue() async {
        let intent = SetSettingIntent()
        intent.setting = SettingEntity(descriptor: BlipSettingDescriptor.descriptor(for: "pingTarget")!)
        intent.value = "not a host!!"
        do {
            _ = try await intent.perform()
            XCTFail("expected invalidValue")
        } catch let error as SettingIntentError {
            guard case .invalidValue = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertNil(defaults.string(forKey: "pingTarget"), "rejected value must not be written")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
