import Foundation

enum VotProto {
    struct TranslationResponse {
        var url = ""
        var status = 0
        var remainingTime = 0
        var translationId = ""
        var language = ""
        var message = ""
        var isLivelyVoice = false
    }

    struct SessionResponse {
        let secretKey: String
        let expires: Int
    }

    enum ProtoError: LocalizedError {
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let message): return message
            }
        }
    }

    static func encodeSessionRequest(uuid: String, module: String) -> Data {
        var writer = Writer()
        writer.string(1, uuid)
        writer.string(2, module)
        return writer.data
    }

    static func decodeSessionResponse(_ data: Data) throws -> SessionResponse {
        var reader = Reader(data)
        var secretKey = ""
        var expires = 0

        while reader.hasRemaining {
            guard let tag = try reader.readTag() else { break }
            switch tag.fieldNumber {
            case 1: secretKey = try reader.readString(wireType: tag.wireType)
            case 2: expires = try reader.readInt32(wireType: tag.wireType)
            default: try reader.skip(wireType: tag.wireType)
            }
        }

        guard !secretKey.isEmpty else {
            throw ProtoError.malformed("VOT session response did not include a secret key")
        }
        return SessionResponse(secretKey: secretKey, expires: expires)
    }

    static func encodeTranslationRequest(
        url: String,
        firstRequest: Bool,
        duration: Double,
        language: String,
        responseLanguage: String,
        videoTitle: String,
        useLivelyVoice: Bool
    ) -> Data {
        var writer = Writer()
        writer.string(3, url)
        writer.bool(5, firstRequest)
        writer.double(6, duration)
        writer.int32(7, 1)
        writer.string(8, language)
        writer.string(14, responseLanguage)
        writer.int32(15, 1)
        writer.int32(16, 2)
        writer.bool(18, useLivelyVoice)
        if !videoTitle.isEmpty { writer.string(19, videoTitle) }
        return writer.data
    }

    static func encodeAudioRequest(translationId: String, url: String, fileId: String) -> Data {
        var audioInfo = Writer()
        audioInfo.string(1, fileId)

        var writer = Writer()
        writer.string(1, translationId)
        writer.string(2, url)
        writer.message(6, audioInfo.data)
        return writer.data
    }

    static func decodeTranslationResponse(_ data: Data) throws -> TranslationResponse {
        var reader = Reader(data)
        var result = TranslationResponse()

        while reader.hasRemaining {
            guard let tag = try reader.readTag() else { break }
            switch tag.fieldNumber {
            case 1: result.url = try reader.readString(wireType: tag.wireType)
            case 4: result.status = try reader.readInt32(wireType: tag.wireType)
            case 5: result.remainingTime = try reader.readInt32(wireType: tag.wireType)
            case 7: result.translationId = try reader.readString(wireType: tag.wireType)
            case 8: result.language = try reader.readString(wireType: tag.wireType)
            case 9: result.message = try reader.readString(wireType: tag.wireType)
            case 10: result.isLivelyVoice = try reader.readInt32(wireType: tag.wireType) != 0
            default: try reader.skip(wireType: tag.wireType)
            }
        }
        return result
    }

    private struct Tag {
        let fieldNumber: Int
        let wireType: Int
    }

    private struct Writer {
        var data = Data()

        mutating func int32(_ field: Int, _ value: Int) {
            guard value != 0 else { return }
            tag(field, wireVarint)
            varint(UInt64(UInt32(bitPattern: Int32(value))))
        }

        mutating func bool(_ field: Int, _ value: Bool) {
            guard value else { return }
            tag(field, wireVarint)
            varint(1)
        }

        mutating func double(_ field: Int, _ value: Double) {
            guard value != 0 else { return }
            tag(field, wireFixed64)
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }

        mutating func string(_ field: Int, _ value: String) {
            guard !value.isEmpty else { return }
            bytes(field, Data(value.utf8))
        }

        mutating func message(_ field: Int, _ value: Data) {
            bytes(field, value)
        }

        mutating func bytes(_ field: Int, _ value: Data) {
            tag(field, wireLengthDelimited)
            varint(UInt64(value.count))
            data.append(value)
        }

        mutating func tag(_ field: Int, _ wireType: Int) {
            precondition(field > 0)
            varint(UInt64((field << 3) | wireType))
        }

        mutating func varint(_ value: UInt64) {
            var value = value
            while true {
                if value & ~0x7f == 0 {
                    data.append(UInt8(value))
                    return
                }
                data.append(UInt8((value & 0x7f) | 0x80))
                value >>= 7
            }
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var position = 0

        init(_ data: Data) {
            self.bytes = Array(data)
        }

        var hasRemaining: Bool { position < bytes.count }

        mutating func readTag() throws -> Tag? {
            guard hasRemaining else { return nil }
            let raw = Int(try readVarint())
            guard raw != 0 else { return nil }
            return Tag(fieldNumber: raw >> 3, wireType: raw & 0x7)
        }

        mutating func readInt32(wireType: Int) throws -> Int {
            try requireWire(wireType, wireVarint)
            return Int(Int32(bitPattern: UInt32(truncatingIfNeeded: try readVarint())))
        }

        mutating func readString(wireType: Int) throws -> String {
            let data = try readBytes(wireType: wireType)
            guard let string = String(data: data, encoding: .utf8) else {
                throw ProtoError.malformed("Malformed UTF-8 in protobuf response")
            }
            return string
        }

        mutating func readBytes(wireType: Int) throws -> Data {
            try requireWire(wireType, wireLengthDelimited)
            let length = Int(try readVarint())
            guard length >= 0, position + length <= bytes.count else {
                throw ProtoError.malformed("Malformed protobuf length")
            }
            let result = Data(bytes[position..<(position + length)])
            position += length
            return result
        }

        mutating func skip(wireType: Int) throws {
            switch wireType {
            case wireVarint:
                _ = try readVarint()
            case wireFixed64:
                try advance(8)
            case wireLengthDelimited:
                try advance(Int(try readVarint()))
            case wireFixed32:
                try advance(4)
            default:
                throw ProtoError.malformed("Unsupported protobuf wire type: \(wireType)")
            }
        }

        mutating func advance(_ count: Int) throws {
            guard count >= 0, position + count <= bytes.count else {
                throw ProtoError.malformed("Malformed protobuf payload")
            }
            position += count
        }

        mutating func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while shift < 64 {
                guard position < bytes.count else {
                    throw ProtoError.malformed("Truncated protobuf varint")
                }
                let byte = bytes[position]
                position += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            throw ProtoError.malformed("Malformed protobuf varint")
        }

        func requireWire(_ actual: Int, _ expected: Int) throws {
            guard actual == expected else {
                throw ProtoError.malformed("Unexpected protobuf wire type: \(actual), expected \(expected)")
            }
        }
    }

    private static let wireVarint = 0
    private static let wireFixed64 = 1
    private static let wireLengthDelimited = 2
    private static let wireFixed32 = 5
}
