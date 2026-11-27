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

    private struct ConditionalRequest {
        let reqId: String
        let origin: String
        let rpId: String
        let rpName: String
        let challengeBase64URL: String
        let allowCredentialIDs: Set<String>
        var isCrossOrigin: Bool = false
        var topOrigin: String? = nil
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

    private var autofillPanel: NSPanel?
    private var savePanel: NSPanel?
    private var dismissMonitor: Any?
    private var currentFieldRect: NSRect = .zero
    private var currentHost: String = ""
    private var conditionalRequests: [String: ConditionalRequest] = [:]
    private var activeASController: ASAuthorizationController?
    private var pendingASRequest: (reqId: String, tab: BrowserTabEngine)?

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
    private var lastVerifiedHostTimestamp: [String: Date] = [:]

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
        dismissAutofillPopover()
        dismissSavePopover()
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

        let autofillEnabled = BrowserSettings.shared.bool(BrowserSettings.Key.autofillPasswords, default: true)

        switch type {
        case "autofill_focus":
            guard autofillEnabled else { return }
            handleAutofillFocus(json: json, tab: tab)
        case "autofill_blur":
            dismissAutofillPopover()
        case "autofill_save":
            guard autofillEnabled else { return }
            handleAutofillSave(json: json, tab: tab)
        case "webauthn_create":
            handleWebAuthnCreate(json: json, tab: tab)
        case "webauthn_get":
            handleWebAuthnGet(json: json, tab: tab)
        case "webauthn_abort":
            if let reqId = json["reqId"] as? String {
                conditionalRequests.removeValue(forKey: reqId)
                if activeBiometricSheet != nil {
                    teardownBiometricSheet()
                }
            }
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
        dismissAutofillPopover()
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

    // MARK: - 1. Inline AutoFill Popover (Apple Passwords + Conditional Passkeys)

    private func handleAutofillFocus(json: [String: Any], tab: BrowserTabEngine) {
        guard activeBiometricSheet == nil else { return }
        guard let host = json["host"] as? String, !host.isEmpty,
              let rectDict = json["rect"] as? [String: Any],
              let rx = rectDict["x"] as? Double,
              let ry = rectDict["y"] as? Double,
              let rw = rectDict["width"] as? Double,
              let rh = rectDict["height"] as? Double else {
            return
        }
        let fieldType = (json["fieldType"] as? String) ?? "username"
        let hasPasskeyHint = (json["hasPasskeyHint"] as? Bool) ?? false
        let conditionalReqId = (json["conditionalReqId"] as? String) ?? ""

        let passwords = queryAppleKeychainPasswords(forHost: host)
        let passkeys = (hasPasskeyHint || !conditionalReqId.isEmpty) ? queryPasskeys(forRpId: host) : []

        // Show popover if we have matching passwords, matching passkeys, or it's a new-password field
        guard !passwords.isEmpty || !passkeys.isEmpty || fieldType == "new-password" else {
            dismissAutofillPopover()
            return
        }

        currentHost = host
        currentFieldRect = NSRect(x: rx, y: ry, width: rw, height: rh)
        presentInlineAutofillPopover(
            host: host,
            fieldType: fieldType,
            viewportRect: currentFieldRect,
            passwords: passwords,
            passkeys: passkeys,
            conditionalReqId: conditionalReqId,
            tab: tab
        )
    }

    private func screenAnchorPoint(forViewportRect r: NSRect) -> NSPoint? {
        guard let win = hostWindow, let hostView = webContentHost else { return nil }
        let viewH = hostView.bounds.height
        let xInHost = max(8, min(hostView.bounds.width - 8, r.origin.x))
        let bottomYInHost = hostView.isFlipped ? (r.origin.y + r.height) : (viewH - (r.origin.y + r.height))
        let ptInWin = hostView.convert(NSPoint(x: xInHost, y: bottomYInHost), to: nil)
        return win.convertPoint(toScreen: ptInWin)
    }

    private func presentInlineAutofillPopover(
        host: String,
        fieldType: String,
        viewportRect: NSRect,
        passwords: [SavedPassword],
        passkeys: [StoredPasskey],
        conditionalReqId: String,
        tab: BrowserTabEngine
    ) {
        dismissAutofillPopover()
        guard let anchorScreen = screenAnchorPoint(forViewportRect: viewportRect) else { return }

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let width: CGFloat = max(272, min(332, viewportRect.width))
        let rowHeight: CGFloat = 46.0
        let footerHeight: CGFloat = 34.0
        let suggestRowCount = (fieldType == "new-password") ? 1 : 0
        let totalRows = passkeys.count + passwords.count + suggestRowCount
        let contentHeight = CGFloat(totalRows) * rowHeight + footerHeight + 16.0

        let panel = NSPanel(
            contentRect: NSRect(x: anchorScreen.x, y: anchorScreen.y - contentHeight - 6, width: width, height: contentHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)

        let container = AuthFlippedView(frame: NSRect(x: 0, y: 0, width: width, height: contentHeight))
        container.wantsLayer = true
        container.layer?.cornerRadius = 14.0
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        let tintOverlay = NSView(frame: container.bounds)
        tintOverlay.wantsLayer = true
        tintOverlay.layer?.backgroundColor = (isDark
            ? NSColor(srgbRed: 0.08, green: 0.08, blue: 0.095, alpha: 0.56)
            : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.76)).cgColor
        container.addSubview(tintOverlay)

        var y: CGFloat = 8.0

        // 1. Passkeys rows
        for pk in passkeys {
            let row = makeAutofillRow(
                frame: NSRect(x: 6, y: y, width: width - 12, height: rowHeight),
                symbolName: "person.badge.key.fill",
                title: pk.userName.isEmpty ? pk.displayName : pk.userName,
                subtitle: "Passkey for \(pk.rpId) · Touch ID",
                showTouchIDBadge: true,
                isDark: isDark
            ) { [weak self] in
                guard let self else { return }
                self.dismissAutofillPopover()
                if let cond = self.conditionalRequests[conditionalReqId] {
                    self.presentPasskeySignInSheet(req: cond, passkeys: [pk], siteIcon: tab.favicon, tab: tab)
                }
            }
            container.addSubview(row)
            y += rowHeight
        }

        // 2. Saved Apple Passwords rows
        for cred in passwords {
            let row = makeAutofillRow(
                frame: NSRect(x: 6, y: y, width: width - 12, height: rowHeight),
                symbolName: "key.fill",
                title: cred.username.isEmpty ? host : cred.username,
                subtitle: "Password for \(cred.host) · Touch ID",
                showTouchIDBadge: true,
                isDark: isDark
            ) { [weak self] in
                guard let self else { return }
                self.dismissAutofillPopover()
                self.authenticateAndFillPassword(cred, siteIcon: tab.favicon, tab: tab)
            }
            container.addSubview(row)
            y += rowHeight
        }

        // 3. Suggest Strong Password row (for new-password fields)
        if fieldType == "new-password" {
            let strong = Self.generateStrongPassword()
            let row = makeAutofillRow(
                frame: NSRect(x: 6, y: y, width: width - 12, height: rowHeight),
                symbolName: "wand.and.stars",
                title: "Use Strong Password",
                subtitle: strong,
                showTouchIDBadge: false,
                isDark: isDark
            ) { [weak self] in
                guard let self else { return }
                self.dismissAutofillPopover()
                self.injectCredentials(username: "", password: strong, onlyPassword: true, tab: tab)
            }
            container.addSubview(row)
            y += rowHeight
        }

        // Divider + "Passwords…" footer opening Apple Passwords app
        let sep = NSView(frame: NSRect(x: 12, y: y + 2, width: width - 24, height: 0.5))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.10)).cgColor
        container.addSubview(sep)

        let footerBtn = AuthPopoverRowButton(frame: NSRect(x: 6, y: y + 5, width: width - 12, height: footerHeight - 4), isDark: isDark) { [weak self] in
            self?.dismissAutofillPopover()
            Self.openApplePasswordsApp()
        }
        let footerIcon = NSImageView(frame: NSRect(x: 10, y: 7, width: 15, height: 15))
        footerIcon.image = AssetLoader.shared.symbol(named: "key.horizontal.fill", pointSize: 12, weight: .medium)
        footerIcon.contentTintColor = isDark ? NSColor.white.withAlphaComponent(0.75) : NSColor.black.withAlphaComponent(0.65)
        footerBtn.addSubview(footerIcon)

        let footerLbl = NSTextField(labelWithString: "Passwords…")
        footerLbl.frame = NSRect(x: 32, y: 6, width: width - 52, height: 17)
        footerLbl.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        footerLbl.textColor = isDark ? NSColor.white.withAlphaComponent(0.86) : NSColor.black.withAlphaComponent(0.78)
        footerBtn.addSubview(footerLbl)
        container.addSubview(footerBtn)

        if #available(macOS 26.0, *) {
            let gv = NSGlassEffectView(frame: container.bounds)
            gv.style = .regular
            gv.cornerRadius = 14.0
            gv.appearance = panel.appearance
            gv.contentView = container
            panel.contentView = gv
        } else {
            let vev = NSVisualEffectView(frame: container.bounds)
            vev.material = .popover
            vev.blendingMode = .behindWindow
            vev.state = .active
            vev.wantsLayer = true
            vev.layer?.cornerRadius = 14.0
            vev.layer?.masksToBounds = true
            vev.addSubview(container)
            panel.contentView = vev
        }

        hostWindow?.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        autofillPanel = panel

        dismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] ev in
            guard let self, let p = self.autofillPanel else { return ev }
            if ev.type == .keyDown && ev.keyCode == 53 {
                self.dismissAutofillPopover()
                return nil
            }
            if ev.type == .leftMouseDown || ev.type == .rightMouseDown {
                if ev.window !== p {
                    self.dismissAutofillPopover()
                }
            }
            return ev
        }
    }

    func authenticateAndFillPassword(_ cred: SavedPassword, siteIcon: NSImage?, tab: BrowserTabEngine) {
        let normHost = cred.host.lowercased()
        if let recent = lastVerifiedHostTimestamp[normHost], Date().timeIntervalSince(recent) < 12.0 {
            injectCredentials(username: cred.username, password: cred.password, onlyPassword: false, tab: tab)
            return
        }

        let displaySite = Self.cleanRelyingPartyDisplayName(rawName: nil, host: cred.host)
        let title = cred.username.isEmpty ? cred.host : cred.username
        let acct = SafariBiometricAccountOption(
            id: "\(cred.host)|\(cred.username)",
            title: title,
            subtitle: "Saved Password · \(cred.host)",
            initials: SafariBiometricAccountOption.computeInitials(from: title)
        )
        let cfg = SafariBiometricSheetKind.PasswordAutoFillConfig(
            siteDisplayName: displaySite,
            siteHost: cred.host,
            siteIcon: siteIcon,
            account: acct
        )
        presentBiometricSheet(
            kind: .passwordAutoFill(cfg),
            reason: "AutoFill password for \(cred.host)",
            onCancel: {
                tab.focusWebContent()
            },
            onMatched: { [weak self] in
                guard let self else { return }
                self.lastVerifiedHostTimestamp[normHost] = Date()
                self.teardownBiometricSheet()
                self.injectCredentials(username: cred.username, password: cred.password, onlyPassword: false, tab: tab)
                tab.focusWebContent()
            }
        )
    }

    private func makeAutofillRow(
        frame: NSRect,
        symbolName: String,
        title: String,
        subtitle: String,
        showTouchIDBadge: Bool,
        isDark: Bool,
        onClick: @escaping () -> Void
    ) -> NSView {
        let row = AuthPopoverRowButton(frame: frame, isDark: isDark, onClick: onClick)

        let iconBg = NSView(frame: NSRect(x: 10, y: 9, width: 28, height: 28))
        iconBg.wantsLayer = true
        iconBg.layer?.cornerRadius = 8.0
        iconBg.layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.07)).cgColor
        row.addSubview(iconBg)

        let iv = NSImageView(frame: NSRect(x: 6, y: 6, width: 16, height: 16))
        iv.image = AssetLoader.shared.symbol(named: symbolName, pointSize: 13.5, weight: .semibold)
        iv.contentTintColor = NSColor.controlAccentColor
        iconBg.addSubview(iv)

        let trailingPad: CGFloat = showTouchIDBadge ? 34 : 12
        let titleLbl = NSTextField(labelWithString: title)
        titleLbl.frame = NSRect(x: 46, y: 7, width: frame.width - 46 - trailingPad, height: 17)
        titleLbl.font = NSFont.systemFont(ofSize: 13.0, weight: .semibold)
        titleLbl.textColor = isDark ? NSColor.white.withAlphaComponent(0.95) : NSColor.black.withAlphaComponent(0.88)
        titleLbl.lineBreakMode = .byTruncatingTail
        row.addSubview(titleLbl)

        let subLbl = NSTextField(labelWithString: subtitle)
        subLbl.frame = NSRect(x: 46, y: 24, width: frame.width - 46 - trailingPad, height: 15)
        subLbl.font = NSFont.systemFont(ofSize: 11.0, weight: .regular)
        subLbl.textColor = isDark ? NSColor.white.withAlphaComponent(0.58) : NSColor.black.withAlphaComponent(0.52)
        subLbl.lineBreakMode = .byTruncatingTail
        row.addSubview(subLbl)

        if showTouchIDBadge {
            let tidIcon = NSImageView(frame: NSRect(x: frame.width - 26, y: 14, width: 18, height: 18))
            tidIcon.image = NSImage(systemSymbolName: "touchid", accessibilityDescription: "Touch ID")?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            tidIcon.contentTintColor = SafariBiometricScannerView.coralPink
            row.addSubview(tidIcon)
        }

        return row
    }

    func dismissAutofillPopover() {
        if let m = dismissMonitor {
            NSEvent.removeMonitor(m)
            dismissMonitor = nil
        }
        if let p = autofillPanel {
            hostWindow?.removeChildWindow(p)
            p.orderOut(nil)
            autofillPanel = nil
        }
    }

    // MARK: - 2. Save Password Prompt

    private func handleAutofillSave(json: [String: Any], tab: BrowserTabEngine) {
        guard let host = json["host"] as? String, !host.isEmpty,
              let password = json["password"] as? String, !password.isEmpty else { return }
        let username = (json["username"] as? String) ?? ""

        // Normalize idmsa.apple.com / appleid.apple.com saves under appleid.apple.com so future
        // Sign in with Apple sheets find the Apple Account credential immediately!
        let normalizedHost = Self.isAppleAuthHost(host) ? "appleid.apple.com" : host

        let existing = queryAppleKeychainPasswords(forHost: normalizedHost)
        if existing.contains(where: { $0.username == username && $0.password == password }) {
            return
        }
        presentSavePasswordPopover(host: normalizedHost, username: username, password: password)
    }

    private func presentSavePasswordPopover(host: String, username: String, password: String) {
        dismissSavePopover()
        guard let win = hostWindow else { return }

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let width: CGFloat = 330
        let height: CGFloat = 132
        let topRightX = win.frame.maxX - width - 22
        let topY = win.frame.maxY - SafariMetrics.toolbarHeight - height - 10

        let panel = NSPanel(
            contentRect: NSRect(x: topRightX, y: topY, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)

        let container = AuthFlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.cornerRadius = 16.0
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        let tintOverlay = NSView(frame: container.bounds)
        tintOverlay.wantsLayer = true
        tintOverlay.layer?.backgroundColor = (isDark
            ? NSColor(srgbRed: 0.08, green: 0.08, blue: 0.095, alpha: 0.60)
            : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.80)).cgColor
        container.addSubview(tintOverlay)

        let keyIcon = NSImageView(frame: NSRect(x: 16, y: 18, width: 22, height: 22))
        keyIcon.image = AssetLoader.shared.symbol(named: "key.fill", pointSize: 18, weight: .semibold)
        keyIcon.contentTintColor = .controlAccentColor
        container.addSubview(keyIcon)

        let headingTitle = (host == "appleid.apple.com") ? "Save Apple Account?" : "Save Password for \(host)?"
        let heading = NSTextField(labelWithString: headingTitle)
        heading.frame = NSRect(x: 46, y: 16, width: width - 62, height: 19)
        heading.font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        heading.textColor = isDark ? .white : .black
        heading.lineBreakMode = .byTruncatingTail
        container.addSubview(heading)

        let subText = username.isEmpty
            ? "Save this password for Touch ID AutoFill in Safarium."
            : "Save password for \"\(username)\" for Touch ID AutoFill."
        let sub = NSTextField(wrappingLabelWithString: subText)
        sub.frame = NSRect(x: 46, y: 38, width: width - 62, height: 34)
        sub.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        sub.textColor = isDark ? NSColor.white.withAlphaComponent(0.70) : NSColor.black.withAlphaComponent(0.60)
        container.addSubview(sub)

        let notNowBtn = NSButton(title: "Not Now", target: self, action: #selector(dismissSaveTapped))
        notNowBtn.bezelStyle = .rounded
        notNowBtn.frame = NSRect(x: width - 208, y: 88, width: 82, height: 28)
        container.addSubview(notNowBtn)

        let saveBtn = AuthClosureButton(title: "Save Password") { [weak self] in
            self?.savePasswordToAppleKeychain(host: host, username: username, password: password)
            self?.dismissSavePopover()
        }
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: width - 120, y: 88, width: 106, height: 28)
        container.addSubview(saveBtn)

        if #available(macOS 26.0, *) {
            let gv = NSGlassEffectView(frame: container.bounds)
            gv.style = .regular
            gv.cornerRadius = 16.0
            gv.appearance = panel.appearance
            gv.contentView = container
            panel.contentView = gv
        } else {
            let vev = NSVisualEffectView(frame: container.bounds)
            vev.material = .popover
            vev.blendingMode = .behindWindow
            vev.state = .active
            vev.wantsLayer = true
            vev.layer?.cornerRadius = 16.0
            vev.layer?.masksToBounds = true
            vev.addSubview(container)
            panel.contentView = vev
        }

        win.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        savePanel = panel
    }

    @objc private func dismissSaveTapped() {
        dismissSavePopover()
    }

    func dismissSavePopover() {
        if let p = savePanel {
            hostWindow?.removeChildWindow(p)
            p.orderOut(nil)
            savePanel = nil
        }
    }

    // MARK: - 3. WebAuthn / Passkeys (Safari Native Biometric Sheet + CryptoKit ES256)

    /// Validates W3C WebAuthn §5.1.3 / §5.1.4 Relying Party ID domain suffix rule against the frame's host.
    static func isValidRpId(_ rawRpId: String, forHost rawHost: String) -> Bool {
        var rpId = rawRpId.lowercased()
        var host = rawHost.lowercased()
        if rpId.hasSuffix(".") { rpId.removeLast() }
        if host.hasSuffix(".") { host.removeLast() }
        guard !rpId.isEmpty, !host.isEmpty else { return false }
        if rpId == host { return true }
        if isIPLiteral(rpId) || isIPLiteral(host) { return false }
        if isPublicSuffix(rpId) { return false }
        return host.hasSuffix(".\(rpId)")
    }

    private func handleWebAuthnCreate(json: [String: Any], tab: BrowserTabEngine) {
        guard let reqId = json["reqId"] as? String,
              let origin = json["origin"] as? String,
              let pk = json["publicKey"] as? [String: Any],
              let challengeB64 = pk["challenge"] as? String,
              let rp = pk["rp"] as? [String: Any],
              let user = pk["user"] as? [String: Any] else { return }

        let pageHost = (json["host"] as? String) ?? (URL(string: origin)?.host ?? "")
        let rpId = ((rp["id"] as? String) ?? pageHost).lowercased()
        let rawRpName = (rp["name"] as? String) ?? (json["siteName"] as? String)
        let rpDisplayName = Self.cleanRelyingPartyDisplayName(rawName: rawRpName, host: rpId)
        let userIdB64 = (user["id"] as? String) ?? ""
        let userName = (user["name"] as? String) ?? ""
        let displayName = (user["displayName"] as? String) ?? userName

        // 1. Validate RP ID against page host
        guard Self.isValidRpId(rpId, forHost: pageHost.isEmpty ? rpId : pageHost) else {
            rejectWebAuthn(
                reqId: reqId,
                name: "SecurityError",
                message: "The relying party ID '\(rpId)' is not a registrable domain suffix of '\(pageHost)'.",
                tab: tab
            )
            return
        }

        // 2. Check `excludeCredentials` per W3C WebAuthn §5.1.3 Step 20 (`InvalidStateError`)
        let excludeList = (pk["excludeCredentials"] as? [[String: Any]]) ?? []
        let excludeIds = Set(excludeList.compactMap { $0["id"] as? String })
        if !excludeIds.isEmpty {
            let existingIds = Set(queryPasskeys(forRpId: rpId).map(\.credentialIDBase64URL))
            if !excludeIds.isDisjoint(with: existingIds) {
                rejectWebAuthn(
                    reqId: reqId,
                    name: "InvalidStateError",
                    message: "A passkey matching excludeCredentials already exists on this device.",
                    tab: tab
                )
                return
            }
        }

        // 3. Verify ES256 (-7) or RS256 (-257) compatibility if pubKeyCredParams is non-empty
        let credParams = (pk["pubKeyCredParams"] as? [[String: Any]]) ?? []
        if !credParams.isEmpty {
            let supportsES256 = credParams.contains { ($0["alg"] as? Int) == -7 }
            if !supportsES256 {
                rejectWebAuthn(
                    reqId: reqId,
                    name: "NotSupportedError",
                    message: "Requested public key algorithm is not supported by platform authenticator.",
                    tab: tab
                )
                return
            }
        }

        let accountLabel = !userName.isEmpty ? userName : (!displayName.isEmpty ? displayName : rpId)
        let acctOption = SafariBiometricAccountOption(
            id: userIdB64.isEmpty ? accountLabel : userIdB64,
            title: accountLabel,
            subtitle: "Passkey for \(rpId)",
            initials: SafariBiometricAccountOption.computeInitials(from: !displayName.isEmpty ? displayName : accountLabel)
        )
        let cfg = SafariBiometricSheetKind.PasskeyCreateConfig(
            rpDisplayName: rpDisplayName,
            rpId: rpId,
            siteIcon: tab.favicon,
            account: acctOption
        )

        let reason = userName.isEmpty
            ? "Create a passkey for \(rpId)"
            : "Create a passkey for \"\(userName)\" on \(rpId)"

        presentBiometricSheet(
            kind: .passkeyCreate(cfg),
            reason: reason,
            onSecondaryAction: { [weak self] in
                guard let self else { return }
                self.teardownBiometricSheet()
                self.fallbackWebAuthn(reqId: reqId, tab: tab)
            },
            onCancel: { [weak self] in
                self?.rejectWebAuthn(reqId: reqId, name: "NotAllowedError", message: "User cancelled passkey creation.", tab: tab)
            },
            onMatched: { [weak self] in
                guard let self else { return }
                self.teardownBiometricSheet()
                self.mintAndResolveNewPasskey(
                    reqId: reqId,
                    origin: origin,
                    rpId: rpId,
                    userIdB64: userIdB64,
                    userName: userName,
                    displayName: displayName,
                    challengeB64: challengeB64,
                    tab: tab
                )
            }
        )
    }

    private func mintAndResolveNewPasskey(
        reqId: String,
        origin: String,
        rpId: String,
        userIdB64: String,
        userName: String,
        displayName: String,
        challengeB64: String,
        tab: BrowserTabEngine
    ) {
        let privateKey = P256.Signing.PrivateKey()
        var credBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, credBytes.count, &credBytes) == errSecSuccess else {
            rejectWebAuthn(reqId: reqId, name: "NotAllowedError", message: "Could not generate a credential ID.", tab: tab)
            return
        }
        let credIdData = Data(credBytes)
        let credIdB64 = Self.base64URLEncode(credIdData)

        let stored = StoredPasskey(
            credentialIDBase64URL: credIdB64,
            rpId: rpId,
            userIdBase64URL: userIdB64,
            userName: userName,
            displayName: displayName,
            privateKeyRawBase64: privateKey.rawRepresentation.base64EncodedString(),
            signCount: 1,
            createdAt: Date()
        )
        savePasskeyToKeychain(stored)

        let clientDataObj: [String: Any] = [
            "type": "webauthn.create",
            "challenge": challengeB64,
            "origin": origin,
            "crossOrigin": false
        ]
        guard let clientDataJSON = try? JSONSerialization.data(withJSONObject: clientDataObj, options: []) else {
            rejectWebAuthn(reqId: reqId, name: "UnknownError", message: "Failed to encode clientDataJSON", tab: tab)
            return
        }

        let authData = Self.buildRegistrationAuthData(
            rpId: rpId,
            signCount: stored.signCount,
            credentialId: credIdData,
            publicKey: privateKey.publicKey
        )
        let attestationObj = Self.buildNoneAttestationObject(authData: authData)
        let spkiData = privateKey.publicKey.derRepresentation

        let res: [String: Any] = [
            "id": credIdB64,
            "rawId": credIdB64,
            "clientDataJSON": Self.base64URLEncode(clientDataJSON),
            "attestationObject": Self.base64URLEncode(attestationObj),
            "authenticatorData": Self.base64URLEncode(authData),
            "publicKeySpki": Self.base64URLEncode(spkiData)
        ]
        resolveWebAuthn(reqId: reqId, result: res, tab: tab)
        tab.focusWebContent()
    }

    private func handleWebAuthnGet(json: [String: Any], tab: BrowserTabEngine) {
        guard let reqId = json["reqId"] as? String,
              let origin = json["origin"] as? String,
              let pk = json["publicKey"] as? [String: Any],
              let challengeB64 = pk["challenge"] as? String else { return }

        let pageHost = (json["host"] as? String) ?? (URL(string: origin)?.host ?? "")
        let rpId = ((pk["rpId"] as? String) ?? pageHost).lowercased()
        let rpDisplayName = Self.cleanRelyingPartyDisplayName(rawName: json["siteName"] as? String, host: rpId)
        let mediation = (json["mediation"] as? String) ?? "optional"
        let allowList = (pk["allowCredentials"] as? [[String: Any]]) ?? []
        let allowIds = Set(allowList.compactMap { $0["id"] as? String })

        guard Self.isValidRpId(rpId, forHost: pageHost.isEmpty ? rpId : pageHost) else {
            rejectWebAuthn(
                reqId: reqId,
                name: "SecurityError",
                message: "The relying party ID '\(rpId)' is not valid for '\(pageHost)'.",
                tab: tab
            )
            return
        }

        let req = ConditionalRequest(
            reqId: reqId,
            origin: origin,
            rpId: rpId,
            rpName: rpDisplayName,
            challengeBase64URL: challengeB64,
            allowCredentialIDs: allowIds,
            isCrossOrigin: (json["isCrossOrigin"] as? Bool) ?? false,
            topOrigin: json["topOrigin"] as? String
        )

        if mediation == "conditional" {
            conditionalRequests[reqId] = req
            return
        }

        let matching = queryPasskeys(forRpId: rpId).filter {
            allowIds.isEmpty || allowIds.contains($0.credentialIDBase64URL)
        }

        guard !matching.isEmpty else {
            performPlatformOrCrossDeviceWebAuthnAssertion(req: req, tab: tab)
            return
        }

        presentPasskeySignInSheet(req: req, passkeys: matching, siteIcon: tab.favicon, tab: tab)
    }

    /// `ASAuthorizationPlatformPublicKeyCredentialProvider` with browser `clientData` (other sites' passkeys,
    /// iCloud Keychain, iPhone QR/hybrid) only works with Apple's managed
    /// `com.apple.developer.web-browser.public-key-credential` entitlement.
    static let hasWebBrowserPasskeyEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil)
        return (value as? Bool) == true
    }()

    private func performPlatformOrCrossDeviceWebAuthnAssertion(req: ConditionalRequest, tab: BrowserTabEngine) {
        guard Self.hasWebBrowserPasskeyEntitlement else {
            // Falling back to CEF's built-in WebAuthn hangs forever (it has no authenticator UI), which left
            // buttons like Apple's "Sign in with Passkey" spinning. Fail fast so the page offers its other options.
            NSLog("[Safarium] Passkey request for %@ rejected: app lacks com.apple.developer.web-browser.public-key-credential", req.rpId)
            rejectWebAuthn(
                reqId: req.reqId,
                name: "NotAllowedError",
                message: "Passkeys saved in iCloud Keychain or on your iPhone are not available in this browser.",
                tab: tab
            )
            return
        }
        if let challengeData = Self.base64URLDecode(req.challengeBase64URL), hostWindow != nil {
            NSApp.activate(ignoringOtherApps: true)
            var clientData = ASPublicKeyCredentialClientData(challenge: challengeData, origin: req.origin)
            clientData.topOrigin = req.topOrigin ?? req.origin
            clientData.crossOrigin = req.isCrossOrigin ? .crossOrigin : .sameOriginWithAncestors

            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: req.rpId)
            let assertionReq = provider.createCredentialAssertionRequest(clientData: clientData)
            assertionReq.shouldShowHybridTransport = true
            if !req.allowCredentialIDs.isEmpty {
                assertionReq.allowedCredentials = req.allowCredentialIDs.compactMap { idStr in
                    guard let d = Self.base64URLDecode(idStr) else { return nil }
                    return ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: d)
                }
            }
            let ctrl = ASAuthorizationController(authorizationRequests: [assertionReq])
            ctrl.delegate = self
            ctrl.presentationContextProvider = self
            self.activeASController = ctrl
            self.pendingASRequest = (reqId: req.reqId, tab: tab)
            ctrl.performRequests()
            return
        }
        fallbackWebAuthn(reqId: req.reqId, tab: tab)
    }

    private func presentPasskeySignInSheet(
        req: ConditionalRequest,
        passkeys: [StoredPasskey],
        siteIcon: NSImage?,
        tab: BrowserTabEngine
    ) {
        conditionalRequests.removeValue(forKey: req.reqId)
        var chosenIndex = 0

        let accountOptions = passkeys.map { pk -> SafariBiometricAccountOption in
            let title = !pk.userName.isEmpty ? pk.userName : (!pk.displayName.isEmpty ? pk.displayName : pk.rpId)
            let nameSource = !pk.displayName.isEmpty ? pk.displayName : title
            return SafariBiometricAccountOption(
                id: pk.credentialIDBase64URL,
                title: title,
                subtitle: "Passkey · \(pk.rpId)",
                initials: SafariBiometricAccountOption.computeInitials(from: nameSource)
            )
        }

        let cfg = SafariBiometricSheetKind.PasskeySignInConfig(
            rpDisplayName: req.rpName,
            rpId: req.rpId,
            siteIcon: siteIcon,
            accounts: accountOptions,
            selectedAccountIndex: 0
        )

        let firstTitle = accountOptions.first?.title ?? ""
        let reason = firstTitle.isEmpty
            ? "Sign in to \(req.rpId) with a passkey"
            : "Sign in to \(req.rpId) as \"\(firstTitle)\""

        presentBiometricSheet(
            kind: .passkeySignIn(cfg),
            reason: reason,
            onSecondaryAction: { [weak self] in
                guard let self else { return }
                self.teardownBiometricSheet()
                self.performPlatformOrCrossDeviceWebAuthnAssertion(req: req, tab: tab)
            },
            onSelectAccountIndex: { idx in
                chosenIndex = max(0, min(passkeys.count - 1, idx))
            },
            onCancel: { [weak self] in
                self?.rejectWebAuthn(reqId: req.reqId, name: "NotAllowedError", message: "Touch ID authentication cancelled.", tab: tab)
            },
            onMatched: { [weak self] in
                guard let self else { return }
                self.teardownBiometricSheet()
                let selectedPasskey = passkeys[max(0, min(passkeys.count - 1, chosenIndex))]
                self.signAndResolvePasskeyAssertion(req: req, passkey: selectedPasskey, tab: tab)
            }
        )
    }

    private func signAndResolvePasskeyAssertion(req: ConditionalRequest, passkey: StoredPasskey, tab: BrowserTabEngine) {
        guard let rawKeyData = Data(base64Encoded: passkey.privateKeyRawBase64),
              let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: rawKeyData) else {
            rejectWebAuthn(reqId: req.reqId, name: "UnknownError", message: "Invalid passkey private key.", tab: tab)
            return
        }

        var updated = passkey
        updated.signCount &+= 1
        savePasskeyToKeychain(updated)

        var clientDataObj: [String: Any] = [
            "type": "webauthn.get",
            "challenge": req.challengeBase64URL,
            "origin": req.origin,
            "crossOrigin": req.isCrossOrigin
        ]
        if req.isCrossOrigin, let top = req.topOrigin { clientDataObj["topOrigin"] = top }
        guard let clientDataJSON = try? JSONSerialization.data(withJSONObject: clientDataObj, options: []) else {
            rejectWebAuthn(reqId: req.reqId, name: "UnknownError", message: "Failed to encode clientDataJSON.", tab: tab)
            return
        }

        let authData = Self.buildAssertionAuthData(rpId: req.rpId, signCount: updated.signCount)
        let clientDataHash = Data(SHA256.hash(data: clientDataJSON))
        var signedPayload = Data(authData)
        signedPayload.append(clientDataHash)

        guard let signature = try? privateKey.signature(for: signedPayload) else {
            rejectWebAuthn(reqId: req.reqId, name: "UnknownError", message: "Signing failed.", tab: tab)
            return
        }

        let res: [String: Any] = [
            "id": updated.credentialIDBase64URL,
            "rawId": updated.credentialIDBase64URL,
            "clientDataJSON": Self.base64URLEncode(clientDataJSON),
            "authenticatorData": Self.base64URLEncode(authData),
            "signature": Self.base64URLEncode(signature.derRepresentation),
            "userHandle": updated.userIdBase64URL
        ]
        resolveWebAuthn(reqId: req.reqId, result: res, tab: tab)
        tab.focusWebContent()
    }

    // MARK: - 4. JS Dispatch Helpers

    private func injectCredentials(username: String, password: String, onlyPassword: Bool, tab: BrowserTabEngine) {
        let uData = (try? JSONSerialization.data(withJSONObject: [username])) ?? Data("[\"\"]".utf8)
        let pData = (try? JSONSerialization.data(withJSONObject: [password])) ?? Data("[\"\"]".utf8)
        let uJS = String(data: uData, encoding: .utf8) ?? "[\"\"]"
        let pJS = String(data: pData, encoding: .utf8) ?? "[\"\"]"
        let flag = onlyPassword ? "true" : "false"
        tab.executeJavaScriptInAllFrames("window.__safariumFillCredentials && window.__safariumFillCredentials((\(uJS))[0], (\(pJS))[0], \(flag));")
    }

    private func resolveWebAuthn(reqId: String, result: [String: Any], tab: BrowserTabEngine) {
        guard let resData = try? JSONSerialization.data(withJSONObject: result),
              let resJSON = String(data: resData, encoding: .utf8),
              let idData = try? JSONSerialization.data(withJSONObject: [reqId]),
              let idJSON = String(data: idData, encoding: .utf8) else { return }
        tab.executeJavaScriptInAllFrames("window.__safariumResolveWebAuthn && window.__safariumResolveWebAuthn((\(idJSON))[0], \(resJSON));")
    }

    private func rejectWebAuthn(reqId: String, name: String, message: String, tab: BrowserTabEngine) {
        guard let arrData = try? JSONSerialization.data(withJSONObject: [reqId, name, message]),
              let arrJSON = String(data: arrData, encoding: .utf8) else { return }
        tab.executeJavaScriptInAllFrames("window.__safariumRejectWebAuthn && window.__safariumRejectWebAuthn.apply(null, \(arrJSON));")
    }

    /// CEF's built-in WebAuthn has no authenticator UI in this embedding, so handing a request back to it
    /// (`__safariumFallbackWebAuthn`) leaves the page waiting until its timeout. Fail the request instead.
    private func fallbackWebAuthn(reqId: String, tab: BrowserTabEngine) {
        rejectWebAuthn(
            reqId: reqId,
            name: "NotAllowedError",
            message: "This passkey option is not available in this browser.",
            tab: tab
        )
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

    func queryAppleKeychainPasswords(forHost rawHost: String) -> [SavedPassword] {
        let host = rawHost.lowercased()
        let baseDomain = Self.registrableDomain(for: host)
        let vault = loadVault()
        return vault.passwords.compactMap { entry in
            let srv = entry.host.lowercased()
            if srv == host || srv == baseDomain || srv == "www.\(baseDomain)" || (host.hasSuffix(".\(srv)") && !Self.isPublicSuffix(srv)) {
                return SavedPassword(host: entry.host, username: entry.username, password: entry.password)
            }
            return nil
        }
    }

    func savePasswordToAppleKeychain(host: String, username: String, password: String) {
        var vault = loadVault()
        let server = host.lowercased()
        vault.passwords.removeAll { $0.host.lowercased() == server && $0.username == username }
        vault.passwords.insert(.init(host: server, username: username, password: password), at: 0)
        persistVault(vault)
    }

    // MARK: - 7. Passkey Storage (Touch ID-gated)

    func queryPasskeys(forRpId rawRpId: String) -> [StoredPasskey] {
        let target = rawRpId.lowercased()
        let base = Self.registrableDomain(for: target)
        return loadVault().passkeys.filter { pk in
            let r = pk.rpId.lowercased()
            return r == target || r == base || (target.hasSuffix(".\(r)") && !Self.isPublicSuffix(r))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func savePasskeyToKeychain(_ passkey: StoredPasskey) {
        var vault = loadVault()
        vault.passkeys.removeAll { $0.credentialIDBase64URL == passkey.credentialIDBase64URL }
        vault.passkeys.insert(passkey, at: 0)
        persistVault(vault)
    }

    // MARK: - 8. WebAuthn Binary / CBOR Encoding

    static func buildRegistrationAuthData(
        rpId: String,
        signCount: UInt32,
        credentialId: Data,
        publicKey: P256.Signing.PublicKey
    ) -> Data {
        var data = Data()
        data.append(contentsOf: SHA256.hash(data: Data(rpId.utf8)))
        // Flags: UP (0x01) | UV (0x04) | BE (0x08) | BS (0x10) | AT (0x40) = 0x5D
        data.append(0x5D)
        var sc = signCount.bigEndian
        withUnsafeBytes(of: &sc) { data.append(contentsOf: $0) }
        // 16-byte AAGUID (Safarium Platform Authenticator)
        let aaguid: [UInt8] = [0x53, 0x61, 0x66, 0x61, 0x72, 0x69, 0x75, 0x6D, 0x50, 0x61, 0x73, 0x73, 0x6B, 0x65, 0x79, 0x01]
        data.append(contentsOf: aaguid)
        var credLen = UInt16(credentialId.count).bigEndian
        withUnsafeBytes(of: &credLen) { data.append(contentsOf: $0) }
        data.append(credentialId)
        data.append(encodeCOSEPublicKey(publicKey))
        return data
    }

    static func buildAssertionAuthData(rpId: String, signCount: UInt32) -> Data {
        var data = Data()
        data.append(contentsOf: SHA256.hash(data: Data(rpId.utf8)))
        // Flags: UP (0x01) | UV (0x04) | BE (0x08) | BS (0x10) = 0x1D
        data.append(0x1D)
        var sc = signCount.bigEndian
        withUnsafeBytes(of: &sc) { data.append(contentsOf: $0) }
        return data
    }

    static func encodeCOSEPublicKey(_ publicKey: P256.Signing.PublicKey) -> Data {
        let raw = publicKey.rawRepresentation // 64 bytes: X (32) || Y (32)
        let x = raw.prefix(32)
        let y = raw.suffix(32)
        var cbor = Data()
        cbor.append(0xA5) // map(5)
        // 1: 2 (kty: EC2)
        cbor.append(contentsOf: [0x01, 0x02])
        // 3: -7 (alg: ES256)
        cbor.append(contentsOf: [0x03, 0x26])
        // -1: 1 (crv: P-256)
        cbor.append(contentsOf: [0x20, 0x01])
        // -2: x (32-byte bstr)
        cbor.append(contentsOf: [0x21, 0x58, 0x20])
        cbor.append(x)
        // -3: y (32-byte bstr)
        cbor.append(contentsOf: [0x22, 0x58, 0x20])
        cbor.append(y)
        return cbor
    }

    static func buildNoneAttestationObject(authData: Data) -> Data {
        var cbor = Data()
        cbor.append(0xA3) // map(3)
        // "fmt": "none"
        cbor.append(cborText("fmt"))
        cbor.append(cborText("none"))
        // "attStmt": {}
        cbor.append(cborText("attStmt"))
        cbor.append(0xA0)
        // "authData": bstr(authData)
        cbor.append(cborText("authData"))
        cbor.append(cborBytes(authData))
        return cbor
    }

    static func cborText(_ s: String) -> Data {
        let utf8 = Data(s.utf8)
        var out = cborHeader(majorType: 3, length: utf8.count)
        out.append(utf8)
        return out
    }

    static func cborBytes(_ d: Data) -> Data {
        var out = cborHeader(majorType: 2, length: d.count)
        out.append(d)
        return out
    }

    static func cborHeader(majorType: UInt8, length: Int) -> Data {
        let prefix = majorType << 5
        if length < 24 {
            return Data([prefix | UInt8(length)])
        } else if length < 256 {
            return Data([prefix | 24, UInt8(length)])
        } else if length < 65536 {
            return Data([prefix | 25, UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
        } else {
            let n = UInt32(truncatingIfNeeded: length)
            return Data([prefix | 26, UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        }
    }

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

    static func generateStrongPassword() -> String {
        let lower = Array("abcdefghjkmnpqrstuvwxyz")
        let upper = Array("ABCDEFGHJKMNPQRSTUVWXYZ")
        let digits = Array("23456789")
        let all = lower + upper + digits
        func group() -> String {
            String((0..<5).map { _ in all.randomElement()! })
        }
        return "\(group())-\(group())-\(group())"
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

private final class AuthPopoverRowButton: NSView {
    private let isDark: Bool
    private let onClick: () -> Void
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init(frame: NSRect, isDark: Bool, onClick: @escaping () -> Void) {
        self.isDark = isDark
        self.onClick = onClick
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8.0
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.06)).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick()
        }
    }
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

extension ApplePasswordsPasskeyManager: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        return hostWindow ?? NSApp.keyWindow ?? NSWindow()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        defer {
            activeASController = nil
            pendingASRequest = nil
        }
        guard let pending = pendingASRequest else { return }
        if let cred = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
            let idB64 = Self.base64URLEncode(cred.credentialID)
            var res: [String: Any] = [
                "id": idB64,
                "rawId": idB64,
                "clientDataJSON": Self.base64URLEncode(cred.rawClientDataJSON),
                "authenticatorData": Self.base64URLEncode(cred.rawAuthenticatorData),
                "signature": Self.base64URLEncode(cred.signature)
            ]
            if let uh = cred.userID {
                res["userHandle"] = Self.base64URLEncode(uh)
            }
            resolveWebAuthn(reqId: pending.reqId, result: res, tab: pending.tab)
        } else {
            fallbackWebAuthn(reqId: pending.reqId, tab: pending.tab)
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        defer {
            activeASController = nil
            pendingASRequest = nil
        }
        guard let pending = pendingASRequest else { return }
        let nsErr = error as NSError
        if nsErr.domain == ASAuthorizationError.errorDomain && nsErr.code == ASAuthorizationError.canceled.rawValue {
            rejectWebAuthn(reqId: pending.reqId, name: "NotAllowedError", message: "User cancelled passkey sign-in.", tab: pending.tab)
        } else {
            // Never fall back to CEF's WebAuthn here: it has no UI and the page would wait forever.
            NSLog("[Safarium] Passkey assertion failed: %@ %ld", nsErr.domain, nsErr.code)
            rejectWebAuthn(reqId: pending.reqId, name: "NotAllowedError", message: nsErr.localizedDescription, tab: pending.tab)
        }
    }
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
