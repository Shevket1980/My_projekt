import Foundation
import CryptoKit

enum VoiceMode: String {
    case standard
    case lively

    var russianName: String {
        switch self {
        case .standard: return "Обычный голос"
        case .lively: return "Живой голос"
        }
    }
}

struct TranslationProgress {
    var remainingSeconds: Int?
    var delayed: Bool
    var serverMessage: String?
    var voiceMode: VoiceMode
    var fallbackToStandard: Bool
}

struct TranslationResult {
    let audioURL: String
    let fallbackAudioURLs: [String]
    let detectedLanguage: String?
    let requestedVoiceMode: VoiceMode
    let usedVoiceMode: VoiceMode
}

final class VotApiClient {
    private struct VotSession {
        let uuid: String
        let secretKey: String
        let expiresAtSeconds: Int64
    }

    private enum ClientError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let message): return message
            }
        }
    }

    private var session: VotSession?
    private let urlSession: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.urlSession = URLSession(configuration: configuration)
    }

    func requestTranslation(
        youtubeURL: String,
        durationSeconds: Double,
        sourceLanguage: String = "auto",
        targetLanguage: String = "ru",
        title: String = "",
        voiceMode: VoiceMode = .standard,
        oauthToken: String? = nil,
        onProgress: @escaping (TranslationProgress) -> Void = { _ in }
    ) async throws -> TranslationResult {
        let requestedVoiceMode = voiceMode
        var activeVoiceMode = voiceMode
        var effectiveSourceLanguage = sourceLanguage
        var sentAudioFallback = false
        var lastMessage = ""
        var retryAttempt = 0
        var firstRequest = true
        var fellBackToStandard = false

        if activeVoiceMode == .lively,
           targetLanguage == "ru",
           effectiveSourceLanguage == "auto" {
            effectiveSourceLanguage = await detectLanguageFromTitle(title) ?? "auto"
        }
        if activeVoiceMode == .lively,
           (targetLanguage != "ru" || effectiveSourceLanguage == "auto") {
            activeVoiceMode = .standard
            fellBackToStandard = true
        }

        onProgress(
            TranslationProgress(
                remainingSeconds: nil,
                delayed: false,
                serverMessage: nil,
                voiceMode: activeVoiceMode,
                fallbackToStandard: fellBackToStandard
            )
        )

        for _ in 0..<Self.maxTranslationAttempts {
            try Task.checkCancellation()
            let useLivelyVoice = activeVoiceMode == .lively
            let activeSession = try await getSession()
            let body = VotProto.encodeTranslationRequest(
                url: youtubeURL,
                firstRequest: firstRequest,
                duration: durationSeconds > 0 ? durationSeconds : Self.defaultDuration,
                language: effectiveSourceLanguage,
                responseLanguage: targetLanguage,
                videoTitle: title,
                useLivelyVoice: useLivelyVoice
            )

            var headers = secureHeaders(
                secType: "Vtrans",
                session: activeSession,
                body: body,
                path: Self.pathTranslate
            )
            if useLivelyVoice, let oauthToken, !oauthToken.isEmpty {
                headers["Authorization"] = "OAuth \(oauthToken)"
            }

            let responseBytes = try await requestBinary(
                path: Self.pathTranslate,
                body: body,
                method: "POST",
                extraHeaders: headers
            )
            let response = try VotProto.decodeTranslationResponse(responseBytes)
            lastMessage = response.message

            switch response.status {
            case Self.statusFinished, Self.statusPartContent:
                guard !response.url.isEmpty else {
                    throw ClientError.message("VOT вернул готовый перевод без ссылки на аудио")
                }
                let usedVoiceMode: VoiceMode = response.isLivelyVoice ? .lively : .standard
                return TranslationResult(
                    audioURL: response.url,
                    fallbackAudioURLs: buildAudioProxyURLs(response.url),
                    detectedLanguage: response.language.isEmpty ? nil : response.language,
                    requestedVoiceMode: requestedVoiceMode,
                    usedVoiceMode: usedVoiceMode
                )

            case Self.statusWaiting, Self.statusLongWaiting:
                firstRequest = false
                let waitMilliseconds: Int64
                if retryAttempt > 0 {
                    waitMilliseconds = Self.retryIntervalMilliseconds
                } else if response.remainingTime > 0 {
                    if response.remainingTime <= Self.maxInitialWaitSeconds {
                        waitMilliseconds = Int64(max(5, response.remainingTime)) * 1000
                    } else {
                        waitMilliseconds = Self.longWaitMilliseconds
                    }
                } else {
                    waitMilliseconds = Self.retryIntervalMilliseconds
                }
                retryAttempt += 1
                try await delayWithProgress(
                    waitMilliseconds: waitMilliseconds,
                    serverRemainingSeconds: response.remainingTime,
                    serverMessage: response.message,
                    voiceMode: activeVoiceMode,
                    fallbackToStandard: fellBackToStandard,
                    onProgress: onProgress
                )

            case Self.statusAudioRequested:
                onProgress(
                    TranslationProgress(
                        remainingSeconds: response.remainingTime > 0 ? response.remainingTime : nil,
                        delayed: false,
                        serverMessage: response.message.isEmpty ? nil : response.message,
                        voiceMode: activeVoiceMode,
                        fallbackToStandard: fellBackToStandard
                    )
                )
                if !sentAudioFallback, youtubeURL.hasPrefix("https://youtu.be/") {
                    try await requestAudioFallback(
                        videoURL: youtubeURL,
                        translationID: response.translationId
                    )
                    sentAudioFallback = true
                    firstRequest = true
                } else {
                    throw ClientError.message("Для этого видео VOT запросил исходную аудиодорожку")
                }

            case Self.statusSessionRequired:
                if activeVoiceMode == .lively {
                    activeVoiceMode = .standard
                    fellBackToStandard = true
                    firstRequest = true
                    retryAttempt = 0
                    sentAudioFallback = false
                    onProgress(
                        TranslationProgress(
                            remainingSeconds: nil,
                            delayed: false,
                            serverMessage: response.message.isEmpty ? nil : response.message,
                            voiceMode: .standard,
                            fallbackToStandard: true
                        )
                    )
                } else {
                    throw ClientError.message("Для этого видео VOT требует авторизацию Яндекса")
                }

            case Self.statusFailed:
                if activeVoiceMode == .lively, isLivelyUnavailableMessage(response.message) {
                    activeVoiceMode = .standard
                    fellBackToStandard = true
                    firstRequest = true
                    retryAttempt = 0
                    sentAudioFallback = false
                    onProgress(
                        TranslationProgress(
                            remainingSeconds: nil,
                            delayed: false,
                            serverMessage: response.message.isEmpty ? nil : response.message,
                            voiceMode: .standard,
                            fallbackToStandard: true
                        )
                    )
                } else {
                    throw ClientError.message(
                        response.message.isEmpty ? "Яндекс не смог перевести это видео" : response.message
                    )
                }

            default:
                let detail = response.message.isEmpty ? "" : " (\(response.message))"
                throw ClientError.message("Неизвестный статус VOT: \(response.status)\(detail)")
            }
        }

        throw ClientError.message(
            lastMessage.isEmpty ? "Истекло время ожидания голосового перевода" : lastMessage
        )
    }

    private func getSession() async throws -> VotSession {
        let now = Int64(Date().timeIntervalSince1970)
        if let session, session.expiresAtSeconds > now + 10 {
            return session
        }

        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        let body = VotProto.encodeSessionRequest(uuid: uuid, module: "video-translation")
        let responseBytes = try await requestBinary(
            path: Self.pathSession,
            body: body,
            method: "POST",
            extraHeaders: ["Vtrans-Signature": hmacSHA256Hex(body)]
        )
        let response = try VotProto.decodeSessionResponse(responseBytes)
        let newSession = VotSession(
            uuid: uuid,
            secretKey: response.secretKey,
            expiresAtSeconds: now + Int64(response.expires)
        )
        session = newSession
        return newSession
    }

    private func requestAudioFallback(videoURL: String, translationID: String) async throws {
        guard !translationID.isEmpty else {
            throw ClientError.message("VOT не вернул идентификатор резервной аудиодорожки")
        }
        try await requestFailedAudio(videoURL: videoURL)

        let activeSession = try await getSession()
        let body = VotProto.encodeAudioRequest(
            translationId: translationID,
            url: videoURL,
            fileId: Self.audioFallbackFileID
        )
        _ = try await requestBinary(
            path: Self.pathAudio,
            body: body,
            method: "PUT",
            extraHeaders: secureHeaders(
                secType: "Vtrans",
                session: activeSession,
                body: body,
                path: Self.pathAudio
            )
        )
    }

    private func requestFailedAudio(videoURL: String) async throws {
        let jsonData = try JSONSerialization.data(
            withJSONObject: ["video_url": videoURL],
            options: []
        )
        let response = try await requestJSON(
            path: Self.pathFailAudio,
            jsonBody: jsonData,
            method: "PUT"
        )
        let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
        let status = (object?["status"] as? NSNumber)?.intValue ?? 0
        guard status == 1 else {
            throw ClientError.message("VOT отклонил резервный запрос аудио")
        }
    }

    private func requestBinary(
        path: String,
        body: Data,
        method: String,
        extraHeaders: [String: String]
    ) async throws -> Data {
        var headers = baseHeaders()
        extraHeaders.forEach { headers[$0.key] = $0.value }
        var lastError: Error?

        do {
            return try await executeDirect(
                path: path,
                body: body,
                method: method,
                headers: headers,
                label: "прямой сервер Яндекса"
            )
        } catch {
            lastError = error
        }

        for worker in Self.defaultWorkers {
            do {
                let wrapper = try JSONSerialization.data(
                    withJSONObject: [
                        "headers": headers,
                        "body": body.map { Int($0) }
                    ],
                    options: []
                )
                return try await executeWorker(
                    worker: worker,
                    path: path,
                    wrapperJSON: wrapper,
                    method: method,
                    expectJSON: false
                )
            } catch {
                lastError = error
            }
        }

        throw ClientError.message(
            "Сетевой запрос VOT не выполнен: \(lastError?.localizedDescription ?? "нет доступного сервера")"
        )
    }

    private func requestJSON(path: String, jsonBody: Data, method: String) async throws -> Data {
        var headers = baseHeaders()
        headers["Accept"] = "application/json"
        headers["Content-Type"] = Self.jsonMediaType
        var lastError: Error?

        do {
            return try await executeDirect(
                path: path,
                body: jsonBody,
                method: method,
                headers: headers,
                label: "прямой сервер Яндекса"
            )
        } catch {
            lastError = error
        }

        let rawJSON = String(data: jsonBody, encoding: .utf8) ?? "{}"
        for worker in Self.defaultWorkers {
            do {
                let wrapper = try JSONSerialization.data(
                    withJSONObject: [
                        "headers": headers,
                        "body": rawJSON
                    ],
                    options: []
                )
                return try await executeWorker(
                    worker: worker,
                    path: path,
                    wrapperJSON: wrapper,
                    method: method,
                    expectJSON: true
                )
            } catch {
                lastError = error
            }
        }

        throw ClientError.message(
            "JSON-запрос VOT не выполнен: \(lastError?.localizedDescription ?? "нет доступного сервера")"
        )
    }

    private func executeDirect(
        path: String,
        body: Data,
        method: String,
        headers: [String: String],
        label: String
    ) async throws -> Data {
        guard let url = URL(string: "https://\(Self.directHost)\(path)") else {
            throw ClientError.message("Некорректный адрес VOT")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try await execute(request, label: label)
    }

    private func executeWorker(
        worker: String,
        path: String,
        wrapperJSON: Data,
        method: String,
        expectJSON: Bool
    ) async throws -> Data {
        guard let url = URL(string: "https://\(worker)\(path)") else {
            throw ClientError.message("Некорректный адрес VOT worker")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = wrapperJSON
        request.setValue(expectJSON ? "application/json" : Self.protobufMediaType, forHTTPHeaderField: "Accept")
        request.setValue(Self.jsonMediaType, forHTTPHeaderField: "Content-Type")
        return try await execute(request, label: "worker \(worker)")
    }

    private func execute(_ request: URLRequest, label: String) async throws -> Data {
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.message("\(label) вернул некорректный ответ")
        }
        guard httpResponse.statusCode == 200 else {
            let yandexStatus = httpResponse.value(forHTTPHeaderField: "X-Yandex-Status")
            let detail = String(data: data.prefix(180), encoding: .utf8) ?? ""
            var message = "\(label): HTTP \(httpResponse.statusCode)"
            if let yandexStatus, !yandexStatus.isEmpty { message += " / \(yandexStatus)" }
            if !detail.isEmpty { message += ": \(detail)" }
            throw ClientError.message(message)
        }
        guard !data.isEmpty else {
            throw ClientError.message("\(label) вернул пустой ответ")
        }
        return data
    }

    private func secureHeaders(
        secType: String,
        session: VotSession,
        body: Data,
        path: String
    ) -> [String: String] {
        let token = "\(session.uuid):\(path):\(Self.componentVersion)"
        let tokenSign = hmacSHA256Hex(Data(token.utf8))
        return [
            "\(secType)-Signature": hmacSHA256Hex(body),
            "Sec-\(secType)-Sk": session.secretKey,
            "Sec-\(secType)-Token": "\(tokenSign):\(token)"
        ]
    }

    private func baseHeaders() -> [String: String] {
        [
            "User-Agent": Self.userAgent,
            "Accept": Self.protobufMediaType,
            "Accept-Language": "en",
            "Content-Type": Self.protobufMediaType,
            "Pragma": "no-cache",
            "Cache-Control": "no-cache",
            "sec-ch-ua": Self.secChUA,
            "sec-ch-ua-full-version-list": Self.secChUAFullVersionList,
            "Sec-Fetch-Mode": "no-cors"
        ]
    }

    private func hmacSHA256Hex(_ data: Data) -> String {
        let key = SymmetricKey(data: Data(Self.hmacKey.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    private func buildAudioProxyURLs(_ urlString: String) -> [String] {
        guard let components = URLComponents(string: urlString),
              components.host == "vtrans.s3-private.mds.yandex.net" else {
            return []
        }
        let marker = "/tts/prod/"
        guard let range = components.path.range(of: marker) else { return [] }
        let fileName = String(components.path[range.upperBound...])
        guard !fileName.isEmpty else { return [] }

        return Self.audioProxyWorkers.map { worker in
            var result = "https://\(worker)/video-translation/audio-proxy/\(fileName)"
            if let query = components.percentEncodedQuery, !query.isEmpty {
                result += "?\(query)"
            }
            return result
        }
    }

    private func isLivelyUnavailableMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("обычная озвучка") ||
            normalized.contains("lively") ||
            normalized.contains("жив") ||
            normalized.contains("authorization") ||
            normalized.contains("авториз")
    }

    private func detectLanguageFromTitle(_ title: String) async -> String? {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minDetectTextLength else { return nil }
        var components = URLComponents(string: "\(Self.detectAPIURL)/detect")
        components?.queryItems = [
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "service", value: "yandexbrowser")
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let language = json["lang"] as? String,
                  !language.isEmpty,
                  language != "auto" else {
                return nil
            }
            return language
        } catch {
            return nil
        }
    }

    private func delayWithProgress(
        waitMilliseconds: Int64,
        serverRemainingSeconds: Int,
        serverMessage: String,
        voiceMode: VoiceMode,
        fallbackToStandard: Bool,
        onProgress: @escaping (TranslationProgress) -> Void
    ) async throws {
        let totalSeconds = max(1, Int((Double(waitMilliseconds) / 1000.0).rounded(.up)))
        let knownETA = serverRemainingSeconds > 0 ? serverRemainingSeconds : nil

        for elapsed in 0..<totalSeconds {
            try Task.checkCancellation()
            let remaining: Int?
            if let knownETA {
                remaining = max(0, knownETA - elapsed)
            } else {
                remaining = max(0, totalSeconds - elapsed)
            }
            onProgress(
                TranslationProgress(
                    remainingSeconds: remaining,
                    delayed: knownETA != nil && remaining == 0,
                    serverMessage: serverMessage.isEmpty ? nil : serverMessage,
                    voiceMode: voiceMode,
                    fallbackToStandard: fallbackToStandard
                )
            )
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private static let directHost = "api.browser.yandex.ru"
    private static let defaultWorkers = [
        "vot-worker.eu.cc",
        "vot-worker.vtrans.eu.cc",
        "vot-worker.toil.cc",
        "vot.deno.dev",
        "vot-new.toil-dump.workers.dev"
    ]
    private static let audioProxyWorkers = [
        "vot-worker.eu.cc",
        "vot-worker.vtrans.eu.cc",
        "vot-worker.toil.cc",
        "vot.deno.dev"
    ]

    private static let protobufMediaType = "application/x-protobuf"
    private static let jsonMediaType = "application/json; charset=utf-8"
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 YaBrowser/26.6.0.0 Safari/537.36"
    private static let componentVersion = "26.6.4.760"
    private static let hmacKey = "bt8xH3VOlb4mqf0nqAibnDOoiPlXsisf"
    private static let defaultDuration = 310.0
    private static let minDetectTextLength = 35
    private static let detectAPIURL = "https://translate-backend.transly.eu.cc/v2"

    private static let pathSession = "/session/create"
    private static let pathTranslate = "/video-translation/translate"
    private static let pathFailAudio = "/video-translation/fail-audio-js"
    private static let pathAudio = "/video-translation/audio"
    private static let audioFallbackFileID = "web_api_get_all_generating_urls_data_from_iframe"

    private static let secChUA = "\"Chromium\";v=\"148\", \"YaBrowser\";v=\"26.6\", \"Not?A_Brand\";v=\"99\", \"Yowser\";v=\"2.5\""
    private static let secChUAFullVersionList = "\"Chromium\";v=\"148.0.7778.760\", \"YaBrowser\";v=\"26.6.4.760\", \"Not?A_Brand\";v=\"99.0.0.0\", \"Yowser\";v=\"2.5\""

    private static let statusFailed = 0
    private static let statusFinished = 1
    private static let statusWaiting = 2
    private static let statusLongWaiting = 3
    private static let statusPartContent = 5
    private static let statusAudioRequested = 6
    private static let statusSessionRequired = 7

    private static let maxInitialWaitSeconds = 180
    private static let longWaitMilliseconds: Int64 = 120_000
    private static let retryIntervalMilliseconds: Int64 = 30_000
    private static let maxTranslationAttempts = 40
}
