import AppKit
import WebKit
import AVFoundation

private struct VideoState {
    let id: String
    let youtubeURL: String
    let title: String
    let currentTime: Double
    let duration: Double
    let paused: Bool
    let playbackRate: Double
    let isLive: Bool
}

@MainActor
final class PlayerWindowController: NSWindowController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private enum UIState: String {
        case idle
        case loading
        case active
    }

    private var webView: WKWebView!
    private let api = VotApiClient()
    private var uiState: UIState = .idle
    private var selectedVoiceMode: VoiceMode = .standard
    private var translationTask: Task<Void, Never>?
    private var generation = UUID()
    private var audioPlayer: AVPlayer?
    private var syncTimer: Timer?
    private var translatedVideoID: String?

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        if #available(macOS 10.15.4, *) {
            configuration.preferences.isElementFullscreenEnabled = true
        }

        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController
        userContentController.addUserScript(
            WKUserScript(
                source: Self.playerInjectionScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.allowsMagnification = true
        browser.setValue(false, forKey: "drawsBackground")

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let initialRect = NSRect(
            x: screenFrame.minX + 20,
            y: screenFrame.minY + 20,
            width: max(1000, screenFrame.width - 40),
            height: max(680, screenFrame.height - 40)
        )
        let window = NSWindow(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LibreTube VOT"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = browser
        window.minSize = NSSize(width: 900, height: 600)

        super.init(window: window)
        self.webView = browser
        browser.navigationDelegate = self
        browser.uiDelegate = self
        userContentController.add(self, name: "vot")

        if let url = URL(string: "https://www.youtube.com/") {
            browser.load(URLRequest(url: url))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "vot")
        syncTimer?.invalidate()
        audioPlayer?.pause()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "vot", let body = message.body as? [String: Any] else { return }
        let action = body["action"] as? String ?? ""

        switch action {
        case "toggle":
            if uiState == .idle {
                beginTranslation()
            } else {
                stopTranslation(statusMessage: nil)
            }

        case "mode":
            guard let rawMode = body["mode"] as? String,
                  let mode = VoiceMode(rawValue: rawMode) else { return }
            let shouldRestart = uiState != .idle
            selectedVoiceMode = mode
            if shouldRestart {
                stopTranslation(statusMessage: nil)
                beginTranslation()
            } else {
                updateWebState(
                    state: .idle,
                    status: "Режим: \(mode.russianName)",
                    mode: mode
                )
                clearStatusLater()
            }

        default:
            break
        }
    }

    private func beginTranslation() {
        guard uiState == .idle else { return }
        generation = UUID()
        let token = generation
        uiState = .loading
        updateWebState(
            state: .loading,
            status: "Запрашиваю перевод…",
            mode: selectedVoiceMode
        )

        translationTask = Task { @MainActor [weak self] in
            await self?.runTranslation(token: token)
        }
    }

    private func runTranslation(token: UUID) async {
        do {
            let initialState = try await getVideoState()
            try ensureCurrent(token)

            guard !initialState.id.isEmpty else {
                throw NSError(
                    domain: "LibreTubeVOT",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Откройте видео YouTube и нажмите флажок ещё раз"]
                )
            }
            guard !initialState.isLive, initialState.duration > 0 else {
                throw NSError(
                    domain: "LibreTubeVOT",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Голосовой перевод прямых трансляций пока не поддерживается"]
                )
            }

            let requestedMode = selectedVoiceMode
            let result = try await api.requestTranslation(
                youtubeURL: initialState.youtubeURL,
                durationSeconds: initialState.duration,
                sourceLanguage: "auto",
                targetLanguage: "ru",
                title: initialState.title,
                voiceMode: requestedMode,
                oauthToken: nil,
                onProgress: { [weak self] progress in
                    Task { @MainActor in
                        self?.handleProgress(progress, token: token)
                    }
                }
            )
            try ensureCurrent(token)

            let player = try await prepareTranslatedPlayer(result)
            try ensureCurrent(token)

            let freshState = try await getVideoState()
            guard freshState.id == initialState.id else {
                throw NSError(
                    domain: "LibreTubeVOT",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Видео изменилось во время подготовки перевода"]
                )
            }

            enableTranslatedAudio(player, for: freshState)
            uiState = .active
            translatedVideoID = freshState.id
            updateWebState(
                state: .active,
                status: result.usedVoiceMode == .lively ? "Живой перевод включён" : "Перевод включён",
                mode: result.usedVoiceMode
            )
            clearStatusLater(keepingState: .active)
            startSyncTimer()

        } catch is CancellationError {
            // User explicitly cancelled the request.
        } catch {
            guard generation == token else { return }
            stopTranslation(statusMessage: "Ошибка: \(error.localizedDescription)")
            clearStatusLater()
        }

        if generation == token {
            translationTask = nil
        }
    }

    private func ensureCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private func handleProgress(_ progress: TranslationProgress, token: UUID) {
        guard generation == token, uiState == .loading else { return }
        var status: String

        if progress.fallbackToStandard {
            status = "Живой голос недоступен — использую обычный"
        } else if progress.delayed {
            status = "Перевод задерживается на сервере…"
        } else if let seconds = progress.remainingSeconds, seconds > 0 {
            status = "Перевод готовится · примерно \(formatTime(seconds))"
        } else {
            status = "Перевод готовится…"
        }

        updateWebState(
            state: .loading,
            status: status,
            mode: progress.voiceMode
        )
    }

    private func prepareTranslatedPlayer(_ result: TranslationResult) async throws -> AVPlayer {
        let candidates = ([result.audioURL] + result.fallbackAudioURLs).reduce(into: [String]()) { list, item in
            if !list.contains(item) { list.append(item) }
        }
        var lastError: Error?

        for candidate in candidates {
            try Task.checkCancellation()
            guard let url = URL(string: candidate) else { continue }
            do {
                let asset = AVURLAsset(url: url)
                let playable = try await asset.load(.isPlayable)
                guard playable else { continue }
                let item = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: item)
                player.automaticallyWaitsToMinimizeStalling = true
                player.volume = 1.0
                return player
            } catch {
                lastError = error
            }
        }

        throw NSError(
            domain: "LibreTubeVOT",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey: "Переведённую аудиодорожку не удалось загрузить" +
                    (lastError.map { ": \($0.localizedDescription)" } ?? "")
            ]
        )
    }

    private func enableTranslatedAudio(_ player: AVPlayer, for state: VideoState) {
        audioPlayer?.pause()
        audioPlayer = player
        duckOriginalAudio()

        let position = CMTime(seconds: max(0, state.currentTime), preferredTimescale: 600)
        player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
        if state.paused {
            player.pause()
        } else {
            player.playImmediately(atRate: Float(clampRate(state.playbackRate)))
        }
    }

    private func startSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.synchronizeAudio()
            }
        }
        if let syncTimer {
            RunLoop.main.add(syncTimer, forMode: .common)
        }
    }

    private func synchronizeAudio() async {
        guard uiState == .active,
              let player = audioPlayer,
              let translatedVideoID else { return }

        do {
            let state = try await getVideoState()
            guard state.id == translatedVideoID else {
                stopTranslation(statusMessage: "Видео изменилось — перевод выключен")
                clearStatusLater()
                return
            }

            let audioTime = player.currentTime().seconds
            if audioTime.isFinite, abs(audioTime - state.currentTime) > 0.22 {
                player.seek(
                    to: CMTime(seconds: max(0, state.currentTime), preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }

            if state.paused {
                if player.rate != 0 { player.pause() }
            } else {
                let wantedRate = Float(clampRate(state.playbackRate))
                if player.rate == 0 || abs(player.rate - wantedRate) > 0.02 {
                    player.playImmediately(atRate: wantedRate)
                }
            }
        } catch {
            // A transient JavaScript/navigation error should not immediately stop playback.
        }
    }

    private func stopTranslation(statusMessage: String?) {
        generation = UUID()
        translationTask?.cancel()
        translationTask = nil
        syncTimer?.invalidate()
        syncTimer = nil
        audioPlayer?.pause()
        audioPlayer = nil
        translatedVideoID = nil
        restoreOriginalAudio()
        uiState = .idle
        updateWebState(
            state: .idle,
            status: statusMessage,
            mode: selectedVoiceMode
        )
    }

    private func getVideoState() async throws -> VideoState {
        let result = try await evaluateJavaScript("window.__LibreTubeVOT?.getVideoState?.()")
        guard let object = result as? [String: Any] else {
            throw NSError(
                domain: "LibreTubeVOT",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Плеер YouTube ещё не готов"]
            )
        }

        let id = object["id"] as? String ?? ""
        let youtubeURL = object["youtubeURL"] as? String ?? ""
        let title = object["title"] as? String ?? ""
        let currentTime = (object["currentTime"] as? NSNumber)?.doubleValue ?? 0
        let duration = (object["duration"] as? NSNumber)?.doubleValue ?? 0
        let paused = (object["paused"] as? NSNumber)?.boolValue ?? true
        let playbackRate = (object["playbackRate"] as? NSNumber)?.doubleValue ?? 1
        let isLive = (object["isLive"] as? NSNumber)?.boolValue ?? false

        return VideoState(
            id: id,
            youtubeURL: youtubeURL,
            title: title,
            currentTime: currentTime,
            duration: duration,
            paused: paused,
            playbackRate: playbackRate,
            isLive: isLive
        )
    }

    private func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private func duckOriginalAudio() {
        webView.evaluateJavaScript("window.__LibreTubeVOT?.duckOriginal?.()", completionHandler: nil)
    }

    private func restoreOriginalAudio() {
        webView.evaluateJavaScript("window.__LibreTubeVOT?.restoreOriginal?.()", completionHandler: nil)
    }

    private func updateWebState(
        state: UIState,
        status: String?,
        mode: VoiceMode
    ) {
        let payload: [String: Any] = [
            "state": state.rawValue,
            "status": status ?? NSNull(),
            "mode": mode.rawValue
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__LibreTubeVOT?.setState?.(\(json))", completionHandler: nil)
    }

    private func clearStatusLater(keepingState state: UIState = .idle) {
        let token = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.generation == token, self.uiState == state else { return }
            self.updateWebState(state: state, status: nil, mode: self.selectedVoiceMode)
        }
    }

    private func formatTime(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let rest = seconds % 60
        return String(format: "%d:%02d", minutes, rest)
    }

    private func clampRate(_ rate: Double) -> Double {
        min(2.0, max(0.5, rate.isFinite ? rate : 1.0))
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateWebState(state: uiState, status: nil, mode: selectedVoiceMode)
    }

    private static let playerInjectionScript = #"""
    (() => {
      if (window.__LibreTubeVOTInstalled) return;
      window.__LibreTubeVOTInstalled = true;

      const STATE = { state: 'idle', status: null, mode: 'standard' };
      let originalVolume = null;
      let menuOpen = false;

      const send = (payload) => {
        try { window.webkit.messageHandlers.vot.postMessage(payload); } catch (_) {}
      };

      const ensureStyle = () => {
        if (document.getElementById('vot-mac-style')) return;
        const style = document.createElement('style');
        style.id = 'vot-mac-style';
        style.textContent = `
          .vot-mac-button {
            color: rgba(255,255,255,.92) !important;
            width: 44px !important;
            min-width: 44px !important;
            position: relative;
            opacity: .92;
          }
          .vot-mac-button:hover { opacity: 1; }
          .vot-mac-button.vot-active { color: #BB86FC !important; opacity: 1; }
          .vot-mac-button.vot-loading { color: white !important; animation: votPulse 1.05s ease-in-out infinite; }
          .vot-mac-button svg { width: 25px; height: 25px; fill: currentColor; vertical-align: middle; }
          .vot-mac-button::after {
            content: '';
            position: absolute;
            right: 3px;
            bottom: 7px;
            width: 5px;
            height: 5px;
            border-radius: 50%;
            background: currentColor;
            opacity: .8;
          }
          @keyframes votPulse { 0%,100% { opacity: .65 } 50% { opacity: 1 } }
          .vot-mac-status {
            position: absolute;
            right: 16px;
            bottom: 58px;
            z-index: 2147483646;
            max-width: min(520px, 75%);
            padding: 9px 12px;
            border-radius: 9px;
            background: rgba(18,18,18,.88);
            color: white;
            font: 500 13px/1.25 -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            box-shadow: 0 4px 18px rgba(0,0,0,.3);
            pointer-events: none;
            opacity: 0;
            transform: translateY(5px);
            transition: opacity .15s ease, transform .15s ease;
          }
          .vot-mac-status.visible { opacity: 1; transform: translateY(0); }
          .vot-mac-menu {
            position: absolute;
            right: 48px;
            bottom: 50px;
            z-index: 2147483647;
            display: none;
            min-width: 185px;
            padding: 6px;
            border: 1px solid rgba(255,255,255,.12);
            border-radius: 10px;
            background: rgba(24,24,24,.97);
            box-shadow: 0 8px 28px rgba(0,0,0,.45);
            font: 500 13px/1.2 -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
          }
          .vot-mac-menu.open { display: block; }
          .vot-mac-menu button {
            display: block;
            width: 100%;
            padding: 9px 10px;
            border: 0;
            border-radius: 7px;
            background: transparent;
            color: #f5f5f5;
            text-align: left;
            cursor: pointer;
          }
          .vot-mac-menu button:hover { background: rgba(255,255,255,.1); }
          .vot-mac-menu button.selected { color: #BB86FC; background: rgba(187,134,252,.12); }
          .vot-mac-menu .hint { padding: 5px 10px 4px; color: #aaa; font-size: 11px; }
        `;
        document.documentElement.appendChild(style);
      };

      const flagSVG = `
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <path d="M5.5 2.75a1 1 0 0 1 1 1V4h10.2c.75 0 1.22.8.87 1.46L15.8 8.8l1.77 3.34a1 1 0 0 1-.87 1.46H7.5v6.65a1 1 0 1 1-2 0V3.75a1 1 0 0 1 1-1Z"/>
        </svg>`;

      const getPlayer = () => document.querySelector('#movie_player');

      const applyState = () => {
        const button = document.querySelector('.vot-mac-button');
        if (button) {
          button.classList.toggle('vot-active', STATE.state === 'active');
          button.classList.toggle('vot-loading', STATE.state === 'loading');
          const modeName = STATE.mode === 'lively' ? 'живой голос' : 'обычный голос';
          const stateName = STATE.state === 'active' ? 'включён' : STATE.state === 'loading' ? 'загружается' : 'выключен';
          button.title = `Голосовой перевод: ${stateName} · ${modeName}\nПравый клик — выбор голоса`;
          button.setAttribute('aria-label', button.title);
        }

        const status = document.querySelector('.vot-mac-status');
        if (status) {
          status.textContent = STATE.status || '';
          status.classList.toggle('visible', !!STATE.status);
        }

        document.querySelectorAll('.vot-mac-menu button[data-mode]').forEach((item) => {
          item.classList.toggle('selected', item.dataset.mode === STATE.mode);
        });
      };

      const mount = () => {
        ensureStyle();
        const player = getPlayer();
        const right = player?.querySelector('.ytp-right-controls');
        if (!player || !right) return;

        if (!right.querySelector('.vot-mac-button')) {
          const button = document.createElement('button');
          button.type = 'button';
          button.className = 'ytp-button vot-mac-button';
          button.innerHTML = flagSVG;
          button.addEventListener('click', (event) => {
            event.preventDefault();
            event.stopPropagation();
            send({ action: 'toggle' });
          }, true);
          button.addEventListener('contextmenu', (event) => {
            event.preventDefault();
            event.stopPropagation();
            const menu = player.querySelector('.vot-mac-menu');
            if (menu) menu.classList.toggle('open');
          }, true);

          const fullscreen = right.querySelector('.ytp-fullscreen-button');
          if (fullscreen) right.insertBefore(button, fullscreen);
          else right.appendChild(button);
        }

        if (!player.querySelector('.vot-mac-status')) {
          const status = document.createElement('div');
          status.className = 'vot-mac-status';
          player.appendChild(status);
        }

        if (!player.querySelector('.vot-mac-menu')) {
          const menu = document.createElement('div');
          menu.className = 'vot-mac-menu';
          menu.innerHTML = `
            <div class="hint">Голос перевода</div>
            <button type="button" data-mode="standard">Обычный голос</button>
            <button type="button" data-mode="lively">Живой голос</button>`;
          menu.querySelectorAll('button[data-mode]').forEach((item) => {
            item.addEventListener('click', (event) => {
              event.preventDefault();
              event.stopPropagation();
              send({ action: 'mode', mode: item.dataset.mode });
              menu.classList.remove('open');
            }, true);
          });
          player.appendChild(menu);
        }

        applyState();
      };

      const videoID = () => {
        try {
          const url = new URL(location.href);
          const direct = url.searchParams.get('v');
          if (direct) return direct;
          const parts = url.pathname.split('/').filter(Boolean);
          if (parts[0] === 'shorts' && parts[1]) return parts[1];
          if (parts[0] === 'live' && parts[1]) return parts[1];
          if (parts[0] === 'embed' && parts[1]) return parts[1];
        } catch (_) {}
        return '';
      };

      window.__LibreTubeVOT = {
        setState(payload) {
          STATE.state = payload?.state || 'idle';
          STATE.status = payload?.status || null;
          STATE.mode = payload?.mode || STATE.mode || 'standard';
          mount();
          applyState();
        },

        getVideoState() {
          const video = document.querySelector('video');
          const id = videoID();
          const duration = video && Number.isFinite(video.duration) ? video.duration : 0;
          const title = (document.title || '').replace(/\s*-\s*YouTube\s*$/i, '').trim();
          const liveBadge = document.querySelector('.ytp-live-badge, .ytp-live');
          return {
            id,
            youtubeURL: id ? `https://youtu.be/${id}` : '',
            title,
            currentTime: video && Number.isFinite(video.currentTime) ? video.currentTime : 0,
            duration,
            paused: video ? !!video.paused : true,
            playbackRate: video && Number.isFinite(video.playbackRate) ? video.playbackRate : 1,
            isLive: !!liveBadge && duration === 0
          };
        },

        duckOriginal() {
          const video = document.querySelector('video');
          if (!video) return;
          if (originalVolume === null) originalVolume = video.volume;
          video.volume = Math.max(0, Math.min(1, originalVolume * 0.28));
        },

        restoreOriginal() {
          const video = document.querySelector('video');
          if (video && originalVolume !== null) {
            video.volume = Math.max(0, Math.min(1, originalVolume));
          }
          originalVolume = null;
        }
      };

      document.addEventListener('click', (event) => {
        const menu = document.querySelector('.vot-mac-menu');
        if (menu && menu.classList.contains('open') && !menu.contains(event.target) && !event.target.closest?.('.vot-mac-button')) {
          menu.classList.remove('open');
        }
      }, true);

      new MutationObserver(mount).observe(document.documentElement, { subtree: true, childList: true });
      setInterval(mount, 900);
      mount();
    })();
    """#
}
