import XCTest

/// Onboards through a Tailcat pairing link against a real Home Assistant running the Tailcat
/// integration: the app signs in, registers and shows the frontend through the tunnel alone, with no
/// internal or external URL. Skipped unless a pairing link is provided, so neither `fastlane test`
/// nor the nightly E2E workflow runs it:
///
///     TEST_RUNNER_TAILCAT_E2E_PAIRING_LINK='homeassistant://tailcat/pair?…' \
///     TEST_RUNNER_E2E_HOME_ASSISTANT_USERNAME=… TEST_RUNNER_E2E_HOME_ASSISTANT_PASSWORD=… \
///     TEST_RUNNER_TAILCAT_E2E_SCREENSHOTS=/path/to/dir TEST_RUNNER_TAILCAT_E2E_LANGUAGE=pl \
///         xcodebuild test -scheme Tests-UI … -only-testing:Tests-UI/TailcatPairingE2ETests
///
/// `TAILCAT_E2E_LANGUAGE` runs the app in another language (English by default) to check its
/// translations; the flow is driven by accessibility identifiers, so it does not depend on the copy.
/// The app has to start without servers (erase the simulator, or uninstall the app and reset its
/// Keychain), and location must not have been denied to it. The link is a secret: it is never
/// printed, and no screenshot shows it.
final class TailcatPairingE2ETests: XCTestCase {
    private var app: XCUIApplication!
    private var flow: E2EFlow!
    private var pairingLink: URL!
    private var language = "en"

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        let environment = ProcessInfo.processInfo.environment
        guard let link = environment["TAILCAT_E2E_PAIRING_LINK"], !link.isEmpty else {
            throw XCTSkip("TAILCAT_E2E_PAIRING_LINK is not set")
        }
        pairingLink = try XCTUnwrap(Self.linkForThisBuild(link), "The pairing link is not a URL")

        if let requested = environment["TAILCAT_E2E_LANGUAGE"], !requested.isEmpty {
            language = requested
        }

        app = XCUIApplication()
        app.launchArguments = Self.launchArguments(language: language)
        app.launch()
        flow = E2EFlow(app: app)
    }

    private static func deepLink(_ host: String) -> URL {
        #if DEBUG
        URL(string: "homeassistant-dev://\(host)")!
        #else
        URL(string: "homeassistant://\(host)")!
        #endif
    }

    /// The shared E2E arguments, in `language` rather than English.
    private static func launchArguments(language: String) -> [String] {
        let locale = language == "en" ? "en_US" : "\(language)_\(language.uppercased())"
        return E2EFlow.launchArguments.map { argument in
            switch argument {
            case "(en)": return "(\(language))"
            case "en_US": return locale
            default: return argument
            }
        }
    }

    /// Debug builds only register the `homeassistant-dev` scheme.
    private static func linkForThisBuild(_ link: String) -> URL? {
        guard var components = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        #if DEBUG
        components.scheme = "homeassistant-dev"
        #endif
        return components.url
    }

    func testOnboardsAndConnectsThroughTheTunnel() {
        // Opened on the welcome screen: onboarding keeps the link and offers it once the user continues.
        app.open(pairingLink)
        flow.tap(app.buttons[.onboardingWelcomeContinue], timeout: E2EFlow.Timeout.screen, "welcome screen")

        let accept = app.buttons[.onboardingInvitationAccept]
        flow.wait(for: accept, timeout: E2EFlow.Timeout.screen, "Tailcat invitation")
        screenshot(1, "invitation")
        accept.tap()

        // The login page is served by Home Assistant through the tunnel's loopback URL.
        let login = flow.webViewShowingLogin(timeout: E2EFlow.Timeout.frontend)
        screenshot(2, "login")
        flow.logIn(in: login)
        flow.nameDevice()
        answerPermissions()
        declineNotifications()

        // The dashboard has rendered once the frontend shows some text; matched by count rather than
        // copy, which follows the app's language.
        let rendered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 3"),
            object: app.webViews.firstMatch.staticTexts
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [rendered], timeout: E2EFlow.Timeout.frontend),
            .completed,
            "Timed out waiting for the frontend dashboard"
        )
        screenshot(3, "dashboard")

        // The app's own settings link rather than the frontend's sidebar, which a first-run banner
        // on the new overview dashboard can cover.
        app.open(Self.deepLink("settings"))
        flow.tap(
            app.descendants(matching: .any)[.settingsServerRow].firstMatch,
            timeout: E2EFlow.Timeout.screen,
            "server row"
        )
        let tailcatRow = app.descendants(matching: .any)[.connectionSettingsTailcat].firstMatch
        flow.wait(for: tailcatRow, timeout: E2EFlow.Timeout.screen, "Tailcat row in the connection settings")
        screenshot(4, "server-details")

        flow.scrollTo(tailcatRow, "Tailcat row")
        tailcatRow.tap()
        let status = app.descendants(matching: .any)[.tailcatSettingsStatus].firstMatch
        let activeConnection = app.descendants(matching: .any)[.tailcatSettingsActiveConnection].firstMatch
        flow.wait(for: activeConnection, timeout: E2EFlow.Timeout.screen, "Tailcat settings screen")
        if language == "en" {
            XCTAssertTrue(status.label.contains("Paired"), "The server is not shown as paired")
        }
        // "Tailcat" is a name and stays untranslated, so this holds in every language.
        XCTAssertTrue(activeConnection.label.contains("Tailcat"), "The app is not connected through the tunnel")
        screenshot(5, "tailcat-screen")

        // With a server set up, opening a link again asks what to do with it: add a new server, use it
        // for each server there is, or cancel, in that order.
        app.open(pairingLink)
        let choice = app.alerts.firstMatch
        flow.wait(for: choice, timeout: E2EFlow.Timeout.screen, "existing server choice")
        XCTAssertEqual(choice.buttons.count, 3, "Expected new server, use for the server, and cancel")
        screenshot(6, "existing-server-alert")
        choice.buttons.element(boundBy: choice.buttons.count - 1).tap()
    }

    /// A server reachable through the tunnel already has a secure remote connection, so onboarding
    /// asks neither about local access nor the home network; only location is left.
    private func answerPermissions() {
        flow.tapIfPresent(
            app.buttons[.onboardingLocalOnlyDisclaimerContinue],
            timeout: E2EFlow.Timeout.optional
        )
        let share = app.buttons[.onboardingLocationShare]
        flow.tap(share, timeout: E2EFlow.Timeout.screen, "location permission screen")
        // A simulator that already granted location (`simctl privacy grant location`) asks nothing.
        flow.answerSystemAlertIfPresent(timeout: E2EFlow.Timeout.optional)
        flow.answerSystemAlertIfPresent(timeout: E2EFlow.Timeout.optional)
        flow.waitUntilGone(share, timeout: E2EFlow.Timeout.screen, "location permission screen")
        XCTAssertFalse(
            app.buttons[.onboardingLocalAccessNext].exists,
            "Onboarding asked about local access for a server reached through Tailcat"
        )
    }

    /// Notifications are beside the point here, and a simulator that answered before shows no system
    /// alert, so the app's own sheet is declined rather than waiting on iOS.
    private func declineNotifications() {
        flow.wait(for: app.webViews.firstMatch, timeout: E2EFlow.Timeout.frontend, "frontend")
        let decline = app.buttons[.notificationPermissionRequestSecondary]
        guard decline.waitForExistence(timeout: E2EFlow.Timeout.screen) else { return }
        flow.dismiss(decline, "notification permission sheet")
        flow.answerSystemAlertIfPresent(timeout: E2EFlow.Timeout.optional)
    }

    /// Saved as `ios-<step>-<name>.png` in English and `ios-<language>-<name>.png` otherwise.
    private func screenshot(_ step: Int, _ name: String) {
        let name = language == "en" ? "ios-\(step)-\(name)" : "ios-\(language)-\(name)"
        // Lets animations settle so the picture shows the screen rather than a transition.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        if let directory = ProcessInfo.processInfo.environment["TAILCAT_E2E_SCREENSHOTS"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            XCTAssertNoThrow(try image.pngRepresentation.write(to: url))
        }
    }
}
