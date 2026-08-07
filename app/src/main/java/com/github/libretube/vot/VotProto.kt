package com.github.libretube.vot

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Tiny protobuf wire codec for the handful of Yandex VOT messages we use.
 *
 * Keeping this codec local avoids adding a protobuf Gradle plugin/dependency to LibreTube.
 * Field numbers mirror the current vot.js schema (3.0.2, checked 2026-08-07).
 */
internal object VotProto {
    data class TranslationResponse(
        val url: String = "",
        val status: Int = 0,
        val remainingTime: Int = 0,
        val translationId: String = "",
        val language: String = "",
        val message: String = "",
        val isLivelyVoice: Boolean = false,
    )

    data class SessionResponse(
        val secretKey: String,
        val expires: Int,
    )

    fun encodeSessionRequest(uuid: String, module: String): ByteArray = Writer().apply {
        string(1, uuid)
        string(2, module)
    }.toByteArray()

    fun decodeSessionResponse(bytes: ByteArray): SessionResponse {
        val reader = Reader(bytes)
        var secretKey = ""
        var expires = 0
        while (reader.hasRemaining()) {
            val tag = reader.readTag() ?: break
            when (tag.fieldNumber) {
                1 -> secretKey = reader.readString(tag.wireType)
                2 -> expires = reader.readInt32(tag.wireType)
                else -> reader.skip(tag.wireType)
            }
        }
        require(secretKey.isNotBlank()) { "VOT session response did not include a secret key" }
        return SessionResponse(secretKey, expires)
    }

    fun encodeTranslationRequest(
        url: String,
        firstRequest: Boolean,
        duration: Double,
        language: String,
        responseLanguage: String,
        videoTitle: String,
        useLivelyVoice: Boolean = false,
    ): ByteArray = Writer().apply {
        string(3, url)
        bool(5, firstRequest)
        double(6, duration)
        int32(7, 1)
        string(8, language)
        string(14, responseLanguage)
        int32(15, 1)
        int32(16, 2)
        bool(18, useLivelyVoice)
        if (videoTitle.isNotBlank()) string(19, videoTitle)
    }.toByteArray()

    fun encodeAudioRequest(
        translationId: String,
        url: String,
        fileId: String,
    ): ByteArray {
        val audioInfo = Writer().apply {
            string(1, fileId)
        }.toByteArray()

        return Writer().apply {
            string(1, translationId)
            string(2, url)
            message(6, audioInfo)
        }.toByteArray()
    }

    fun decodeTranslationResponse(bytes: ByteArray): TranslationResponse {
        val reader = Reader(bytes)
        var url = ""
        var status = 0
        var remainingTime = 0
        var translationId = ""
        var language = ""
        var message = ""
        var isLivelyVoice = false

        while (reader.hasRemaining()) {
            val tag = reader.readTag() ?: break
            when (tag.fieldNumber) {
                1 -> url = reader.readString(tag.wireType)
                4 -> status = reader.readInt32(tag.wireType)
                5 -> remainingTime = reader.readInt32(tag.wireType)
                7 -> translationId = reader.readString(tag.wireType)
                8 -> language = reader.readString(tag.wireType)
                9 -> message = reader.readString(tag.wireType)
                10 -> isLivelyVoice = reader.readInt32(tag.wireType) != 0
                else -> reader.skip(tag.wireType)
            }
        }
        return TranslationResponse(url, status, remainingTime, translationId, language, message, isLivelyVoice)
    }

    private data class Tag(val fieldNumber: Int, val wireType: Int)

    private class Writer {
        private val out = ByteArrayOutputStream()

        fun int32(field: Int, value: Int) {
            if (value == 0) return
            tag(field, WIRE_VARINT)
            varint(value.toLong() and 0xffffffffL)
        }

        fun bool(field: Int, value: Boolean) {
            if (!value) return
            tag(field, WIRE_VARINT)
            varint(1)
        }

        fun double(field: Int, value: Double) {
            if (value == 0.0) return
            tag(field, WIRE_FIXED64)
            val bytes = ByteBuffer.allocate(8)
                .order(ByteOrder.LITTLE_ENDIAN)
                .putDouble(value)
                .array()
            out.write(bytes)
        }

        fun string(field: Int, value: String) {
            if (value.isEmpty()) return
            bytes(field, value.toByteArray(Charsets.UTF_8))
        }

        fun message(field: Int, value: ByteArray) = bytes(field, value)

        fun bytes(field: Int, value: ByteArray) {
            tag(field, WIRE_LENGTH_DELIMITED)
            varint(value.size.toLong())
            out.write(value)
        }

        private fun tag(field: Int, wireType: Int) {
            require(field > 0)
            varint(((field shl 3) or wireType).toLong())
        }

        private fun varint(value: Long) {
            var v = value
            while (true) {
                if ((v and -128L) == 0L) {
                    out.write(v.toInt())
                    return
                }
                out.write(((v and 0x7f) or 0x80).toInt())
                v = v ushr 7
            }
        }

        fun toByteArray(): ByteArray = out.toByteArray()
    }

    private class Reader(private val data: ByteArray) {
        private var position = 0

        fun hasRemaining(): Boolean = position < data.size

        fun readTag(): Tag? {
            if (!hasRemaining()) return null
            val raw = readVarint().toInt()
            if (raw == 0) return null
            return Tag(raw ushr 3, raw and 0x7)
        }

        fun readInt32(wireType: Int): Int {
            requireWire(wireType, WIRE_VARINT)
            return readVarint().toInt()
        }

        fun readString(wireType: Int): String = readBytes(wireType).toString(Charsets.UTF_8)

        private fun readBytes(wireType: Int): ByteArray {
            requireWire(wireType, WIRE_LENGTH_DELIMITED)
            val length = readVarint().toInt()
            require(length >= 0 && position + length <= data.size) { "Malformed protobuf length" }
            val result = data.copyOfRange(position, position + length)
            position += length
            return result
        }

        fun skip(wireType: Int) {
            when (wireType) {
                WIRE_VARINT -> readVarint()
                WIRE_FIXED64 -> advance(8)
                WIRE_LENGTH_DELIMITED -> advance(readVarint().toInt())
                WIRE_FIXED32 -> advance(4)
                else -> error("Unsupported protobuf wire type: $wireType")
            }
        }

        private fun advance(count: Int) {
            require(count >= 0 && position + count <= data.size) { "Malformed protobuf payload" }
            position += count
        }

        private fun readVarint(): Long {
            var result = 0L
            var shift = 0
            while (shift < 64) {
                require(position < data.size) { "Truncated protobuf varint" }
                val b = data[position++].toInt() and 0xff
                result = result or ((b and 0x7f).toLong() shl shift)
                if ((b and 0x80) == 0) return result
                shift += 7
            }
            error("Malformed protobuf varint")
        }

        private fun requireWire(actual: Int, expected: Int) {
            require(actual == expected) { "Unexpected protobuf wire type: $actual, expected $expected" }
        }
    }

    private const val WIRE_VARINT = 0
    private const val WIRE_FIXED64 = 1
    private const val WIRE_LENGTH_DELIMITED = 2
    private const val WIRE_FIXED32 = 5
}
