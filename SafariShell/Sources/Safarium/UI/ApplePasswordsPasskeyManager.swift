import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import QuartzCore
import Security

/// Native Safari-style Apple Passwords inline AutoFill, Sign in with Apple modal sheet,
/// and FIDO2 / WebAuthn Passkey authenticator powered by Safari's embedded Touch ID scanner
/// (`SafariBiometricScannerView` + `LAAuthenticationView`).
final class ApplePasswordsPasskeyManager: NSObject {

    struct SavedPassword: Equatable {
        let host: String
        let username: String
        let password: String
    }

    struct StoredPasskey: Codable, Equatable {
        let credentialIDBase64URL: String
        let rpId: String
        let userIdBase64URL: String
        let userName: String
        let displayName: String
        let privateKeyRawBase64: String
        var signCount: UInt32
        let createdAt: Date
    }

    struct AppleSignInFlowState {
        var originatingHost: String
        var siteDisplayName: String
        var siteIcon: NSImage?
        var iconURL: String
        var clientId: String
        var redirectURI: String
        var scope: String
        var isPopupFlow: Bool
        var hideMyEmailSelected: Bool
        var biometricApproved: Bool
        var latestPageStep: String
        /// True while we wait for Apple's page to say what it needs. Touch ID is only offered when it can
        /// actually finish the sign-in: Apple already has a session (consent step) or a saved Apple Account
        /// password exists. Otherwise Apple's own page is shown — no fingerprint that leads nowhere.
        var awaitingPageDecision: Bool = false
    }

    /// Injectable biometric authenticator factory (production `SystemBiometricAuthenticator` by default; deterministic mock in tests).
    var biometricAuthenticatorFactory: () -> BiometricAuthEvaluating = {
        SystemBiometricAuthenticator()
    }

    /// Injectable macOS / Apple Account full name provider (`NSFullUserName()` in production).
    var userFullNameProvider: () -> String = {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? NSUserName() : full
    }

    /// Eliminates the post-checkmark 150ms celebration delay in automated unit tests.
    var immediateDismissOnMatchForTesting: Bool = false

    private weak var hostWindow: NSWindow?
    private weak var webContentHost: NSView?
    private weak var sheetContainerView: NSView?
    private weak var activeTab: BrowserTabEngine?


    // Embedded Safari Biometric Modal Sheet state
    private(set) var activeBiometricSheet: SafariBiometricSheetView?
    private var activeAuthenticator: BiometricAuthEvaluating?
    private var activeSheetCancelHandler: (() -> Void)?
    private var activeSheetMatchAction: (() -> Void)?
    private var activeSheetReason: String = ""
    /// Re-arms the inline Touch ID scan when the window becomes key again (macOS cancels LAContext
    /// evaluation with `.systemCancel` when the app/window loses focus).
    private var sheetKeyWindowObserver: NSObjectProtocol?
    /// Top-level Sign in with Apple with nothing saved: the sheet is only shown once Apple's page reaches its
    /// consent step (existing Apple session), where Touch ID can actually complete the sign-in.
    private var deferredAppleSheetPresenter: (() -> Void)?

    // Sign in with Apple state tracking
    private var pendingAppleIntent: (host: String, url: URL?, siteName: String, icon: NSImage?, snapshot: NSImage?, iconURL: String, scope: String, clientId: String, timestamp: Date)?
    private var lastNonAppleTabContext: (host: String, url: URL?, title: String, icon: NSImage?, snapshot: NSImage?)?
    private(set) var activeAppleSignInFlow: AppleSignInFlowState?

    /// Notifies `SafariWindowController` when a top-level Sign in with Apple sheet starts/ends masking `appleid.apple.com`.
    var onToolbarPresentationOverrideChanged: (() -> Void)?

    /// While a top-level Sign in with Apple biometric sheet is presented over the originating page,
    /// keep the address bar & toolbar anchored to the originating relying party (`janitorai.com`) just like Safari.
    var activeOriginatingTabPresentation: (url: URL, title: String, favicon: NSImage?)? {
        guard let flow = activeAppleSignInFlow,
              !flow.isPopupFlow,
              let sheet = activeBiometricSheet,
              !sheet.isShowingInteractiveWebAuth,
              !flow.originatingHost.isEmpty else { return nil }
        let origURL = (pendingAppleIntent?.host == flow.originatingHost ? pendingAppleIntent?.url : nil)
            ?? (lastNonAppleTabContext?.host == flow.originatingHost ? lastNonAppleTabContext?.url : nil)
            ?? URL(string: "https://\(flow.originatingHost)")
        guard let url = origURL else { return nil }
        return (url: url, title: flow.siteDisplayName, favicon: flow.siteIcon)
    }

    private static let passkeyService = "com.safarium.webauthn.passkeys.v1"

    var hasActiveBiometricSheet: Bool {
        activeBiometricSheet != nil
    }

    init(window: NSWindow?, webContentHost: NSView, sheetContainerView: NSView? = nil) {
        self.hostWindow = window
        self.webContentHost = webContentHost
        self.sheetContainerView = sheetContainerView
        super.init()
    }

    deinit {
        dismissAllPopovers()
    }

    func dismissAllPopovers() {
        cancelActiveBiometricSheet()
    }

    func cancelActiveBiometricSheet() {
        let cancelHandler = activeSheetCancelHandler
        teardownBiometricSheet()
        cancelHandler?()
    }

    private func teardownBiometricSheet() {
        let hadSheet = (activeBiometricSheet != nil)
        let prevAuth = activeAuthenticator
        activeAuthenticator = nil
        prevAuth?.invalidate()
        activeSheetCancelHandler = nil
        activeSheetMatchAction = nil
        activeSheetReason = ""
        deferredAppleSheetPresenter = nil
        if let sheetKeyWindowObserver {
            NotificationCenter.default.removeObserver(sheetKeyWindowObserver)
        }
        sheetKeyWindowObserver = nil
        activeBiometricSheet?.removeFromSuperview()
        activeBiometricSheet = nil
        if hadSheet {
            onToolbarPresentationOverrideChanged?()
        }
    }

    // MARK: - Tab Navigation & Auth Popup Lifecycle Hooks

    private static func isIntermediateOAuthBrokerURL(_ url: URL, host: String) -> Bool {
        if host.hasSuffix(".supabase.co") || host.hasSuffix(".auth0.com") || host.contains(".clerk.") ||
           host.hasSuffix(".firebaseapp.com") || host.hasSuffix(".okta.com") || host.contains(".amazoncognito.com") {
            return true
        }
        let pathLower = url.path.lowercased()
        let queryLower = (url.query ?? "").lowercased()
        if (pathLower.contains("/oauth/") || pathLower.contains("/auth/v1/authorize")) && queryLower.contains("apple") {
            return true
        }
        return false
    }

    func handleTabURLChanged(url: URL?, tab: BrowserTabEngine) {
        self.activeTab = tab
        guard let url, let host = url.host?.lowercased(), !host.isEmpty else { return }

        if Self.isAppleAuthHost(host) {
            if url.path.lowercased().contains("/auth/authorize") && activeAppleSignInFlow == nil {
                beginAppleSignInSheetForAuthorizeURL(url, isPopup: false, tab: tab)
            }
        } else {
            let isBrokerHop = Self.isIntermediateOAuthBrokerURL(url, host: host)
            if !isBrokerHop || lastNonAppleTabContext == nil {
                lastNonAppleTabContext = (
                    host: host,
                    url: url,
                    title: tab.title,
                    icon: tab.favicon ?? (lastNonAppleTabContext?.host == host ? lastNonAppleTabContext?.icon : nil),
                    snapshot: tab.cachedSnapshot ?? (lastNonAppleTabContext?.host == host ? lastNonAppleTabContext?.snapshot : nil)
                )
            }
            // If a top-level Sign in with Apple redirect just completed and returned to the relying party, close the sheet!
            if let flow = activeAppleSignInFlow, !flow.isPopupFlow, !isBrokerHop {
                activeAppleSignInFlow = nil
                teardownBiometricSheet()
            }
        }
    }

    func handleTabFaviconUpdated(_ favicon: NSImage?, tab: BrowserTabEngine) {
        guard let favicon, let host = tab.currentURL?.host?.lowercased(), !host.isEmpty, !Self.isAppleAuthHost(host) else { return }
        if lastNonAppleTabContext?.host == host {
            lastNonAppleTabContext?.icon = favicon
        }
        if pendingAppleIntent?.host.lowercased() == host && pendingAppleIntent?.icon == nil {
            pendingAppleIntent?.icon = favicon
        }
        if var flow = activeAppleSignInFlow, flow.originatingHost.lowercased() == host, flow.siteIcon == nil {
            flow.siteIcon = favicon
            activeAppleSignInFlow = flow
            activeBiometricSheet?.updateSiteIcon(favicon, fallbackTitle: flow.siteDisplayName)
        }
    }

    func handleAuthPopupOpened(url: URL, tab: BrowserTabEngine) {
        self.activeTab = tab
        let host = (url.host ?? "").lowercased()
        let hasFreshIntent = pendingAppleIntent.map { Date().timeIntervalSince($0.timestamp) < 8.0 } ?? false
        if Self.isAppleAuthHost(host) || (url.absoluteString == "about:blank" && hasFreshIntent) {
            beginAppleSignInSheetForAuthorizeURL(url, isPopup: true, tab: tab)
        }
    }

    func handleAuthPopupURLChanged(url: URL, tab: BrowserTabEngine) {
        self.activeTab = tab
        let host = (url.host ?? "").lowercased()
        if Self.isAppleAuthHost(host) && activeAppleSignInFlow == nil {
            beginAppleSignInSheetForAuthorizeURL(url, isPopup: true, tab: tab)
        }
    }

    func handleAuthPopupClosed(tab: BrowserTabEngine) {
        guard let flow = activeAppleSignInFlow, flow.isPopupFlow else { return }
        activeAppleSignInFlow = nil
        teardownBiometricSheet()
        tab.focusWebContent()
    }

    // MARK: - Renderer Auth Event Router

    func handleAuthEventJSON(_ jsonString: String, tab: BrowserTabEngine) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }
        self.activeTab = tab


        switch type {
        case "apple_signin_intent":
            handleAppleSignInIntent(json: json, tab: tab)
        case "apple_signin_page_state":
            handleAppleSignInPageState(json: json, tab: tab)
        case "apple_signin_needs_interactive":
            revealInteractiveAppleSignInIfNeeded(tab: tab)
        default:
            break
        }
    }

    // MARK: - Native Safari Biometric Modal Sheet Presenter

    private func presentBiometricSheet(
        kind: SafariBiometricSheetKind,
        reason: String,
        autoStartEvaluation: Bool = true,
        onSecondaryAction: (() -> Void)? = nil,
        onSelectAccountIndex: ((Int) -> Void)? = nil,
        onEmailPrivacyChanged: ((Bool) -> Void)? = nil,
        onCancel: @escaping () -> Void,
        onMatched: @escaping () -> Void
    ) {
        teardownBiometricSheet()

        guard let stage = webContentHost else {
            // Headless fallback if no webContentHost view was provided
            let auth = biometricAuthenticatorFactory()
            activeAuthenticator = auth
            auth.evaluate(reason: reason, allowPasswordFallback: !auth.canEvaluateBiometricsOrWatch) { [weak self] outcome in
                self?.activeAuthenticator = nil
                if outcome == .matched {
                    onMatched()
                } else {
                    onCancel()
                }
            }
            return
        }

        let sheet = SafariBiometricSheetView(kind: kind)
        let authenticator = biometricAuthenticatorFactory()
        if let laView = authenticator.makeEmbeddedAuthView(controlSize: .regular) {
            sheet.scannerView.attachEmbeddedAuthenticationView(laView)
        }

        self.activeBiometricSheet = sheet
        self.activeAuthenticator = authenticator
        self.activeSheetReason = reason
        self.activeSheetCancelHandler = onCancel
        self.activeSheetMatchAction = onMatched

        sheet.onCancel = { [weak self] in
            self?.cancelActiveBiometricSheet()
        }
        sheet.onSecondaryAction = onSecondaryAction
        sheet.onSelectAccountIndex = onSelectAccountIndex
        sheet.onEmailPrivacyChanged = onEmailPrivacyChanged
        sheet.onActivateBiometricScanner = { [weak self] in
            guard let self else { return }
            // Touch ID is already listening; a click must not restart (and thereby cancel) the scan.
            if self.activeBiometricSheet?.scannerView.state == .scanning { return }
            let allowPw: Bool
            switch self.activeBiometricSheet?.scannerView.state {
            case .failed, .fallbackPassword:
                allowPw = true
            default:
                allowPw = !authenticator.canEvaluateBiometricsOrWatch
            }
            self.startSheetBiometricEvaluation(allowPasswordFallback: allowPw)
        }

        let container = sheetContainerView ?? stage
        sheet.alphaValue = 1.0
        container.addSubview(sheet, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            sheet.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            sheet.topAnchor.constraint(equalTo: stage.topAnchor),
            sheet.bottomAnchor.constraint(equalTo: stage.bottomAnchor)
        ])
        container.layoutSubtreeIfNeeded()

        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !immediateDismissOnMatchForTesting,
           let layer = sheet.layer {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = 1.0
            fade.duration = 0.16
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "safariSheetFadeIn")
        }

        hostWindow?.makeFirstResponder(sheet.scannerView)

        if let window = hostWindow ?? stage.window {
            sheetKeyWindowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self, let sheet = self.activeBiometricSheet, sheet.scannerView.state == .idle,
                      !sheet.scannerView.isHidden, self.activeAppleSignInFlow?.awaitingPageDecision != true,
                      let auth = self.activeAuthenticator, auth.canEvaluateBiometricsOrWatch else { return }
                self.startSheetBiometricEvaluation(allowPasswordFallback: false)
            }
        }

        if autoStartEvaluation {
            startSheetBiometricEvaluation(allowPasswordFallback: !authenticator.canEvaluateBiometricsOrWatch)
        }
    }

    private func startSheetBiometricEvaluation(allowPasswordFallback: Bool) {
        guard let sheet = activeBiometricSheet,
              let authenticator = activeAuthenticator,
              !sheet.isShowingInteractiveWebAuth else { return }

        // A context that hit an unrecoverable error is replaced by the authenticator; show its new glyph view
        // so the scan stays inline instead of falling back to the system Touch ID alert.
        if !allowPasswordFallback, let laView = authenticator.makeEmbeddedAuthView(controlSize: .regular) {
            sheet.scannerView.attachEmbeddedAuthenticationView(laView)
        }
        sheet.scannerView.setState(.scanning)
        let reason = activeSheetReason
        authenticator.evaluate(reason: reason, allowPasswordFallback: allowPasswordFallback) { [weak self] outcome in
            guard let self, self.activeBiometricSheet === sheet, self.activeAuthenticator === authenticator else { return }
            switch outcome {
            case .matched:
                sheet.scannerView.setState(.matched)
                let matchAction = self.activeSheetMatchAction
                self.activeSheetMatchAction = nil
                if self.immediateDismissOnMatchForTesting {
                    matchAction?()
                } else {
                    // Let Apple's success checkmark finish drawing before the sheet goes away.
                    let usedPassword = allowPasswordFallback || !authenticator.canEvaluateBiometricsOrWatch
                    DispatchQueue.main.asyncAfter(deadline: .now() + (usedPassword ? 0.16 : 0.45)) {
                        matchAction?()
                    }
                }
            case .fallbackRequested:
                self.startSheetBiometricEvaluation(allowPasswordFallback: true)
            case .unavailable:
                if !allowPasswordFallback && authenticator.canEvaluateDeviceOwnerAuth {
                    self.startSheetBiometricEvaluation(allowPasswordFallback: true)
                } else {
                    sheet.scannerView.setState(.fallbackPassword)
                }
            case .failed(let msg):
                sheet.scannerView.setState(.failed(msg))
            case .cancelled:
                // Keep the Safari modal sheet open so the user can retry Touch ID or click Cancel explicitly,
                // matching macOS Safari's embedded LAAuthenticationView sheet behavior.
                sheet.scannerView.setState(.idle)
            }
        }
    }

    // MARK: - 0. Native Safari "Sign in with Apple" Sheet & Automation

    static func isAppleAuthHost(_ rawHost: String) -> Bool {
        let h = rawHost.lowercased()
        return h == "appleid.apple.com" || h.hasSuffix(".appleid.apple.com") ||
               h == "idmsa.apple.com" || h.hasSuffix(".idmsa.apple.com")
    }

    /// Produces Safari's clean human-readable brand name (e.g. `janitorai.com` -> `"Janitor"`,
    /// `"Sign in - Notion"` -> `"Notion"`, `com.nytimes.web` -> `"Nytimes"`).
    static func cleanRelyingPartyDisplayName(rawName: String?, host: String, clientId: String = "") -> String {
        if let raw = rawName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let normalizedSeparators = raw.replacingOccurrences(of: " - ", with: " | ")
            let parts = normalizedSeparators
                .components(separatedBy: CharacterSet(charactersIn: "|—–·:"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let genericWords: Set<String> = ["sign in", "log in", "login", "register", "sign up", "welcome", "home", "authorize", "apple"]
            if let candidate = parts.first(where: { !genericWords.contains($0.lowercased()) }) {
                if candidate.lowercased() == "janitorai" || candidate.lowercased() == "janitor ai" || candidate.lowercased() == "janitorai.com" {
                    return "Janitor"
                }
                if !candidate.contains(".") || candidate.contains(" ") {
                    return candidate
                }
            }
        }

        var cleanHost = host.lowercased()
        if cleanHost.hasPrefix("www.") { cleanHost.removeFirst(4) }
        if cleanHost.isEmpty && !clientId.isEmpty {
            // Reverse-DNS Apple Services ID (e.g. `com.janitorai.web` -> `janitorai`)
            let segs = clientId.split(separator: ".").map(String.init)
            if segs.count >= 2 {
                cleanHost = segs[1].lowercased()
            } else if let first = segs.first {
                cleanHost = first.lowercased()
            }
        }
        let baseLabel = cleanHost.split(separator: ".").first.map(String.init) ?? cleanHost
        if baseLabel == "janitorai" { return "Janitor" }
        guard !baseLabel.isEmpty else { return "This Website" }
        return baseLabel.prefix(1).uppercased() + baseLabel.dropFirst()
    }

    func resolvedAppleAccountIdentity() -> (displayName: String, email: String?, savedPassword: SavedPassword?) {
        let appleHosts = ["appleid.apple.com", "idmsa.apple.com", "apple.com", "icloud.com"]
        let vault = loadVault()
        let saved = vault.passwords.first { entry in
            let h = entry.host.lowercased()
            return appleHosts.contains(h) || h.hasSuffix(".apple.com") || h.hasSuffix(".icloud.com")
        }.map { SavedPassword(host: $0.host, username: $0.username, password: $0.password) }

        let fullName = userFullNameProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        let display = !fullName.isEmpty ? fullName : (saved?.username.isEmpty == false ? saved!.username : "Apple Account")
        let email = (saved?.username.contains("@") == true) ? saved?.username : nil
        return (display, email, saved)
    }

    private func handleAppleSignInIntent(json: [String: Any], tab: BrowserTabEngine) {
        let host = (json["host"] as? String) ?? (tab.currentURL?.host ?? "")
        let rawSite = json["siteName"] as? String
        let iconURL = (json["iconURL"] as? String) ?? ""
        let scope = (json["scope"] as? String) ?? ""
        let clientId = (json["clientId"] as? String) ?? ""
        let usePopup = (json["usePopup"] as? Bool) ?? false

        let siteName = Self.cleanRelyingPartyDisplayName(rawName: rawSite, host: host, clientId: clientId)
        let icon = tab.favicon ?? FaviconCache.shared.cachedImage(forURLString: tab.currentURL?.absoluteString ?? "")

        let initialSnap = tab.cachedSnapshot ?? (lastNonAppleTabContext?.host == host.lowercased() ? lastNonAppleTabContext?.snapshot : nil)
        pendingAppleIntent = (
            host: host,
            url: tab.currentURL,
            siteName: siteName,
            icon: icon,
            snapshot: initialSnap,
            iconURL: iconURL,
            scope: scope,
            clientId: clientId,
            timestamp: Date()
        )
        tab.captureSnapshot { [weak self] liveSnap in
            guard let self, let liveSnap else { return }
            if self.pendingAppleIntent?.host == host {
                self.pendingAppleIntent?.snapshot = liveSnap
            }
            if let flow = self.activeAppleSignInFlow, !flow.isPopupFlow, flow.originatingHost.lowercased() == host.lowercased() {
                self.activeBiometricSheet?.setFrozenBackdropSnapshot(liveSnap)
            }
        }

        // Pre-warm high-res icon if `iconURL` was provided
        if !iconURL.isEmpty, let u = URL(string: iconURL) {
            fetchRemoteIcon(url: u) { [weak self] fetched in
                guard let self, let fetched else { return }
                if self.pendingAppleIntent?.iconURL == iconURL {
                    self.pendingAppleIntent?.icon = fetched
                }
                if var flow = self.activeAppleSignInFlow, flow.iconURL == iconURL {
                    flow.siteIcon = fetched
                    self.activeAppleSignInFlow = flow
                    self.activeBiometricSheet?.updateSiteIcon(fetched, fallbackTitle: flow.siteDisplayName)
                }
            }
        }

        // When invoked via AppleJS `usePopup: true` (or explicit intent in tests without waiting for network),
        // present the native Safari Sign in with Apple sheet immediately for zero-latency responsiveness!
        if usePopup, activeAppleSignInFlow == nil {
            var syntheticComps = URLComponents(string: "https://appleid.apple.com/auth/authorize")!
            syntheticComps.queryItems = [
                URLQueryItem(name: "client_id", value: clientId),
                URLQueryItem(name: "scope", value: scope),
                URLQueryItem(name: "redirect_uri", value: (json["redirectURI"] as? String) ?? "")
            ]
            if let u = syntheticComps.url {
                beginAppleSignInSheetForAuthorizeURL(u, isPopup: true, tab: tab)
            }
        }
    }

    private func beginAppleSignInSheetForAuthorizeURL(_ url: URL, isPopup: Bool, tab: BrowserTabEngine) {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let qItems = comps?.queryItems ?? []
        func q(_ name: String) -> String {
            qItems.first(where: { $0.name.lowercased() == name })?.value ?? ""
        }

        let urlClientId = q("client_id")
        let urlRedirect = q("redirect_uri")
        let urlScope = q("scope")

        let recentIntent = pendingAppleIntent.flatMap { Date().timeIntervalSince($0.timestamp) < 20.0 ? $0 : nil }

        let redirectHost = URL(string: urlRedirect)?.host ?? ""
        let origHost = recentIntent?.host.isEmpty == false
            ? recentIntent!.host
            : (isPopup ? (tab.currentURL?.host ?? redirectHost) : (lastNonAppleTabContext?.host ?? redirectHost))
        let rawName = recentIntent?.siteName ?? (isPopup ? tab.title : lastNonAppleTabContext?.title)
        let clientId = !urlClientId.isEmpty ? urlClientId : (recentIntent?.clientId ?? "")
        let scope = !urlScope.isEmpty ? urlScope : (recentIntent?.scope ?? "")
        let siteDisplayName = Self.cleanRelyingPartyDisplayName(rawName: rawName, host: origHost, clientId: clientId)
        let siteIcon = recentIntent?.icon ?? (isPopup ? tab.favicon : lastNonAppleTabContext?.icon) ?? FaviconCache.shared.cachedImage(forURLString: "https://\(origHost)")
        let frozenBackdrop: NSImage? = isPopup ? nil : (recentIntent?.snapshot ?? lastNonAppleTabContext?.snapshot)

        let flow = AppleSignInFlowState(
            originatingHost: origHost,
            siteDisplayName: siteDisplayName,
            siteIcon: siteIcon,
            iconURL: recentIntent?.iconURL ?? "",
            clientId: clientId,
            redirectURI: urlRedirect,
            scope: scope,
            isPopupFlow: isPopup,
            hideMyEmailSelected: false,
            biometricApproved: false,
            latestPageStep: "loading"
        )
        let identity = resolvedAppleAccountIdentity()
        var startingFlow = flow
        startingFlow.awaitingPageDecision = (identity.savedPassword == nil)
        self.activeAppleSignInFlow = startingFlow
        let awaitingDecision = startingFlow.awaitingPageDecision

        let sheetCfg = SafariBiometricSheetKind.SignInWithAppleConfig(
            siteDisplayName: siteDisplayName,
            siteHost: origHost,
            siteIcon: siteIcon,
            accountName: identity.displayName,
            accountSubtitle: "Your account",
            requestsEmailScope: false,
            hideMyEmailSelected: false
        )

        func presentSheet(autoStart: Bool) {
        presentBiometricSheet(
            kind: .signInWithApple(sheetCfg),
            reason: "Sign in to \(siteDisplayName) using your Apple Account",
            autoStartEvaluation: autoStart,
            onSecondaryAction: { [weak self] in
                // "Use a different Apple Account"
                guard let self else { return }
                let prevAuth = self.activeAuthenticator
                self.activeAuthenticator = nil
                prevAuth?.invalidate()
                self.revealInteractiveAppleSignInIfNeeded(tab: tab)
            },
            onEmailPrivacyChanged: { [weak self] hideEmail in
                self?.activeAppleSignInFlow?.hideMyEmailSelected = hideEmail
            },
            onCancel: { [weak self] in
                guard let self else { return }
                let wasPopup = self.activeAppleSignInFlow?.isPopupFlow ?? isPopup
                self.activeAppleSignInFlow = nil
                tab.executeJavaScriptInAllFrames("window.__safariumDriveAppleSignIn && window.__safariumDriveAppleSignIn({ action: 'cancel' });")
                if wasPopup {
                    tab.closeAuthPopup()
                } else if tab.canGoBack {
                    tab.goBack()
                }
                tab.focusWebContent()
            },
            onMatched: { [weak self] in
                guard let self else { return }
                self.activeAppleSignInFlow?.biometricApproved = true
                self.driveUnderlyingAppleAuthAfterBiometrics(tab: tab)
            }
        )
        if let frozenBackdrop {
            activeBiometricSheet?.setFrozenBackdropSnapshot(frozenBackdrop)
        }
        onToolbarPresentationOverrideChanged?()
        }

        if awaitingDecision && !isPopup {
            // Leave Apple's page visible; no sheet (and no fingerprint) unless Touch ID can finish the job.
            teardownBiometricSheet()
            deferredAppleSheetPresenter = { presentSheet(autoStart: true) }
            return
        }
        presentSheet(autoStart: !awaitingDecision)
        if awaitingDecision, let sheet = activeBiometricSheet {
            sheet.scannerView.isHidden = true
            // Apple's page never reported a usable step (blocked script, odd layout): hand it to the user.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                guard let self, self.activeBiometricSheet === sheet,
                      self.activeAppleSignInFlow?.awaitingPageDecision == true else { return }
                self.activeAppleSignInFlow?.awaitingPageDecision = false
                self.revealInteractiveAppleSignInIfNeeded(tab: tab)
            }
        }
        onToolbarPresentationOverrideChanged?()
    }

    private func handleAppleSignInPageState(json: [String: Any], tab: BrowserTabEngine) {
        let step = (json["step"] as? String) ?? "loading"
        let rpName = (json["rpName"] as? String) ?? ""
        let rpIcon = (json["rpIcon"] as? String) ?? ""

        if activeAppleSignInFlow == nil,
           let urlStr = json["url"] as? String,
           let url = URL(string: urlStr),
           urlStr.lowercased().contains("/auth/authorize") {
            beginAppleSignInSheetForAuthorizeURL(url, isPopup: tab.hasActiveAuthPopup, tab: tab)
        }

        guard var flow = activeAppleSignInFlow else { return }
        flow.latestPageStep = step
        if !rpName.isEmpty && (flow.siteDisplayName == "This Website" || flow.siteDisplayName == "Appleid") {
            flow.siteDisplayName = rpName
        }
        activeAppleSignInFlow = flow

        if !rpIcon.isEmpty && flow.siteIcon == nil, let iconURL = URL(string: rpIcon) {
            fetchRemoteIcon(url: iconURL) { [weak self] img in
                guard let self, let img else { return }
                self.activeAppleSignInFlow?.siteIcon = img
                self.activeBiometricSheet?.updateSiteIcon(img, fallbackTitle: self.activeAppleSignInFlow?.siteDisplayName ?? "")
            }
        }

        if flow.awaitingPageDecision {
            switch step {
            case "consent_ready":
                // Apple already knows this browser's account session: Touch ID approves the consent step.
                activeAppleSignInFlow?.awaitingPageDecision = false
                if let presenter = deferredAppleSheetPresenter {
                    deferredAppleSheetPresenter = nil
                    presenter()
                } else if let sheet = activeBiometricSheet {
                    sheet.scannerView.isHidden = false
                    startSheetBiometricEvaluation(allowPasswordFallback: false)
                }
            case "credentials_needed", "credentials_error", "two_factor":
                // Nothing saved to sign in with; Touch ID cannot help. Show Apple's page directly.
                activeAppleSignInFlow?.awaitingPageDecision = false
                if deferredAppleSheetPresenter != nil {
                    deferredAppleSheetPresenter = nil // page is already on screen
                } else {
                    revealInteractiveAppleSignInIfNeeded(tab: tab)
                }
            default:
                break
            }
            return
        }

        // If the user ALREADY completed Touch ID on the native Safari sheet, drive the newly ready Apple auth step!
        if flow.biometricApproved {
            if step == "two_factor" || step == "credentials_error" {
                revealInteractiveAppleSignInIfNeeded(tab: tab)
            } else if step == "consent_ready" || step == "credentials_needed" {
                driveUnderlyingAppleAuthAfterBiometrics(tab: tab)
            }
        }
    }

    private func driveUnderlyingAppleAuthAfterBiometrics(tab: BrowserTabEngine) {
        guard let flow = activeAppleSignInFlow else { return }
        let identity = resolvedAppleAccountIdentity()

        // If Apple's auth frame explicitly needs credentials or 2FA and we don't have saved Apple credentials yet,
        // reveal the interactive Apple sign-in view cleanly so the user can sign in once!
        if flow.latestPageStep == "two_factor" || flow.latestPageStep == "credentials_error" {
            revealInteractiveAppleSignInIfNeeded(tab: tab)
            return
        }
        if flow.latestPageStep == "credentials_needed" && identity.savedPassword == nil {
            revealInteractiveAppleSignInIfNeeded(tab: tab)
            return
        }

        var cmd: [String: Any] = [
            "action": "continueOrSubmit",
            "hideEmail": flow.hideMyEmailSelected
        ]
        if let saved = identity.savedPassword {
            cmd["appleId"] = saved.username
            cmd["password"] = saved.password
        }
        if let cmdData = try? JSONSerialization.data(withJSONObject: cmd),
           let cmdJSON = String(data: cmdData, encoding: .utf8) {
            tab.executeJavaScriptInAllFrames("window.__safariumDriveAppleSignIn && window.__safariumDriveAppleSignIn(\(cmdJSON));")
        }
    }

    private func revealInteractiveAppleSignInIfNeeded(tab: BrowserTabEngine) {
        guard let flow = activeAppleSignInFlow else { return }
        if flow.isPopupFlow, let popupView = tab.authPopupContainerView, let sheet = activeBiometricSheet {
            sheet.setFrozenBackdropSnapshot(nil)
            sheet.revealInteractiveWebAuthView(popupView)
            onToolbarPresentationOverrideChanged?()
        } else {
            // Top-level `appleid.apple.com` navigation: remove the modal overlay so the user can interact directly with the page
            teardownBiometricSheet()
            tab.focusWebContent()
        }
    }

    private func fetchRemoteIcon(url: URL, completion: @escaping (NSImage?) -> Void) {
        guard url.scheme == "https" || url.scheme == "http" else {
            completion(nil)
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, err in
            guard err == nil, let data, !data.isEmpty, let img = NSImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion(img) }
        }.resume()
    }

    // MARK: - 6. Local Vault Storage (Touch ID-gated, zero macOS Keychain ACL popups)

    struct LocalVault: Codable {
        struct Entry: Codable {
            let host: String
            let username: String
            let password: String
        }
        var passwords: [Entry] = []
        var passkeys: [StoredPasskey] = []
    }

    var vaultURL: URL {
        let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSup
            .appendingPathComponent("Safarium/Profile", isDirectory: true)
            .appendingPathComponent("safarium-vault.json")
    }

    func loadVault() -> LocalVault {
        guard let raw = try? Data(contentsOf: vaultURL) else { return LocalVault() }
        if let plain = SafariumVaultCrypto.open(raw, keyDirectory: vaultURL.deletingLastPathComponent()),
           let decoded = try? JSONDecoder().decode(LocalVault.self, from: plain) {
            return decoded
        }
        // Legacy plaintext vault written by older builds: read it once and re-save it encrypted.
        if let decoded = try? JSONDecoder().decode(LocalVault.self, from: raw) {
            persistVault(decoded)
            return decoded
        }
        return LocalVault()
    }

    func persistVault(_ vault: LocalVault) {
        let dir = vaultURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let json = try? JSONEncoder().encode(vault),
              let sealed = SafariumVaultCrypto.seal(json, keyDirectory: dir) else { return }
        try? sealed.write(to: vaultURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path)
    }

    // MARK: - 8. Host Helpers

    static func base64URLDecode(_ str: String) -> Data? {
        var s = str.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Multi-label public suffixes (an embedded subset of the Public Suffix List: common country second-level
    /// domains plus popular hosting platforms where each subdomain belongs to a different owner).
    static let multiLabelPublicSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "co.nz", "org.nz", "net.nz", "govt.nz", "ac.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "co.kr", "or.kr", "ne.kr", "co.in", "net.in", "org.in", "ac.in", "gov.in",
        "com.br", "net.br", "org.br", "gov.br", "edu.br", "com.ar", "com.mx", "org.mx", "com.co", "com.pe", "com.ve", "com.uy",
        "com.tr", "net.tr", "org.tr", "gen.tr", "web.tr", "gov.tr", "edu.tr", "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.hk", "org.hk", "com.tw", "org.tw", "com.sg", "edu.sg", "com.my", "com.ph", "co.id", "co.th", "co.il", "org.il",
        "co.za", "org.za", "com.ng", "com.eg", "com.sa", "com.ua", "com.pl", "com.ru", "co.ke", "com.pk", "com.bd", "com.vn",
        "github.io", "githubusercontent.com", "gitlab.io", "bitbucket.io", "herokuapp.com", "vercel.app", "now.sh", "netlify.app",
        "pages.dev", "workers.dev", "web.app", "firebaseapp.com", "appspot.com", "blogspot.com", "wordpress.com", "tumblr.com",
        "cloudfront.net", "azurewebsites.net", "azureedge.net", "amazonaws.com", "s3.amazonaws.com", "elasticbeanstalk.com",
        "onrender.com", "fly.dev", "glitch.me", "repl.co", "replit.dev", "surge.sh", "ngrok.io", "ngrok-free.app", "trycloudflare.com",
        "duckdns.org", "no-ip.org", "ddns.net", "myshopify.com", "weebly.com", "wixsite.com", "squarespace.com", "github.dev",
        "vercel.dev", "deno.dev", "streamlit.app", "gitpod.io", "codespaces.dev", "cloudflare-ipfs.com"
    ]

    static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let p = host.split(separator: ".", omittingEmptySubsequences: false)
        return p.count == 4 && p.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// True when `host` is itself a public suffix (a single TLD label or an entry of `multiLabelPublicSuffixes`).
    static func isPublicSuffix(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.isEmpty || isIPLiteral(h) { return false }
        return !h.contains(".") || multiLabelPublicSuffixes.contains(h)
    }

    static func registrableDomain(for host: String) -> String {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        if isIPLiteral(h) { return h }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count <= 2 { return h }
        for i in 1..<parts.count {
            let suffix = parts[i...].joined(separator: ".")
            if multiLabelPublicSuffixes.contains(suffix) {
                return i == 0 ? h : parts[(i - 1)...].joined(separator: ".")
            }
        }
        return parts.suffix(2).joined(separator: ".")
    }

    static func openApplePasswordsApp() {
        let passwordsApp = URL(fileURLWithPath: "/System/Applications/Passwords.app")
        if FileManager.default.fileExists(atPath: passwordsApp.path) {
            NSWorkspace.shared.openApplication(at: passwordsApp, configuration: NSWorkspace.OpenConfiguration())
        } else if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Passwords-Settings.extension") {
            NSWorkspace.shared.open(settingsURL)
        }
    }
}

private final class AuthFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class AuthClosureButton: NSButton {
    private let onTap: () -> Void
    init(title: String, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        self.title = title
        self.target = self
        self.action = #selector(tapped)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func tapped() { onTap() }
}

/// AES-256-GCM encryption for the local password/passkey vault.
enum SafariumVaultCrypto {
    static let magic = Data("SXV1".utf8)
    nonisolated(unsafe) static var keyOverride: SymmetricKey?

    static func seal(_ plaintext: Data, keyDirectory: URL) -> Data? {
        guard let key = keyOverride ?? loadOrCreateKey(in: keyDirectory),
              let box = try? AES.GCM.seal(plaintext, using: key, authenticating: magic),
              let combined = box.combined else { return nil }
        return magic + combined
    }

    static func open(_ data: Data, keyDirectory: URL) -> Data? {
        guard data.count > magic.count + 28, data.prefix(magic.count) == magic,
              let key = keyOverride ?? loadOrCreateKey(in: keyDirectory, createIfMissing: false),
              let box = try? AES.GCM.SealedBox(combined: data.dropFirst(magic.count)) else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: magic)
    }

    private static func loadOrCreateKey(in dir: URL, createIfMissing: Bool = true) -> SymmetricKey? {
        let keyFile = dir.appendingPathComponent("safarium-vault.key")
        if let d = try? Data(contentsOf: keyFile), d.count == 32 {
            return SymmetricKey(data: d)
        }
        guard createIfMissing else { return nil }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? raw.write(to: keyFile, options: .atomic)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        return key
    }
}
