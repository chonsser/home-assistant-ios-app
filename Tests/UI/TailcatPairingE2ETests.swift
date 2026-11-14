import XCTest

/// Onboards through a Tailcat pairing link against a real Home Assistant running the Tailcat
/// integration: the app signs in, registers and shows the frontend through the tunnel alone, with no
/// internal or external URL. Skipped unless a pairing link is provided, so neither `fastlane test`
/// nor the nightly E2E workflow runs it:
///
///     TEST_RUNNER_TAILCAT_E2E_PAIRING_LINK='homeassistant://tailcat/pair?…' \
///     TEST_RUNNER_E2E_HOME_ASSISTANT_USERNAME=… TEST_RUNNER_E2E_HOME_ASSISTANT_PASSWORD=… \
///     TEST_RUNNER_TAILCAT_E2E_SCREENSHOTS=/path/to/dir \
///         xcodebuild test -scheme Tests-UI … -only-testing:Tests-UI/TailcatPairingE2ETests
///
/// The app has to start without servers (erase the simulator, or uninstall the app and reset its
/// Keychain), and location must not have been denied to it. The link is a secret: it is never
/// printed, and no screenshot shows it.
final class TailcatPairingE2ETests: XCTestCase {
    private var app: XCUIApplication!
    private var flow: E2EFlow!
    private var pairingLink: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        let environment = ProcessInfo.processInfo.environment
        guard let link = environment["TAILCAT_E2E_PAIRING_LINK"], !link.isEmpty else {
            throw XCTSkip("TAILCAT_E2E_PAIRING_LINK is not set")
        }
        pairingLink = try XCTUnwrap(Self.linkForThisBuild(link), "The pairing link is not a URL")

        app = XCUIApplication()
        app.launchArguments = E2EFlow.launchArguments
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
        screenshot("ios-1-invitation")
        accept.tap()

        // The login page is served by Home Assistant through the tunnel's loopback URL.
        let login = flow.webViewShowingLogin(timeout: E2EFlow.Timeout.frontend)
        screenshot("ios-2-login")
        flow.logIn(in: login)
        flow.nameDevice()
        answerPermissions()
        declineNotifications()

        flow.wait(
            for: flow.webElement(labelContaining: "sidebar toggle"),
            timeout: E2EFlow.Timeout.frontend,
            "frontend dashboard"
        )
        screenshot("ios-3-dashboard")

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
        screenshot("ios-4-connection-settings")

        flow.scrollTo(tailcatRow, "Tailcat row")
        tailcatRow.tap()
        let status = app.descendants(matching: .any)[.tailcatSettingsStatus].firstMatch
        let activeConnection = app.descendants(matching: .any)[.tailcatSettingsActiveConnection].firstMatch
        flow.wait(for: activeConnection, timeout: E2EFlow.Timeout.screen, "Tailcat settings screen")
        XCTAssertTrue(status.label.contains("Paired"), "The server is not shown as paired")
        XCTAssertTrue(activeConnection.label.contains("Tailcat"), "The app is not connected through the tunnel")
        screenshot("ios-5-tailcat-screen")

        // With a server set up, opening a link again asks what to do with it.
        app.open(pairingLink)
        let newServer = app.alerts.firstMatch.buttons["Add as New Server"]
        flow.wait(for: newServer, timeout: E2EFlow.Timeout.screen, "existing server choice")
        screenshot("ios-6-existing-server-alert")
        app.alerts.firstMatch.buttons["Cancel"].tap()
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

    private func screenshot(_ name: String) {
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
