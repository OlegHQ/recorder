import Foundation
import Speech
import RecorderCore

/// On-device speech recognition of `mic.m4a` into timed words (source seconds = mic seconds).
/// Never uses the server: fails clearly when on-device recognition is unavailable.
/// ponytail: SFSpeechRecognizer only; macOS 26's SpeechAnalyzer/SpeechTranscriber is the upgrade path.
enum Transcriber {
    struct Failure: Error, LocalizedError {
        let errorDescription: String?
    }

    static func words(in audio: URL) async throws -> [Word] {
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else {
            throw Failure(errorDescription: "Speech Recognition is not allowed. Enable Recorder in System Settings ▸ Privacy & Security ▸ Speech Recognition.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            throw Failure(errorDescription: "Speech recognition is unavailable for \(Locale.current.identifier).")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw Failure(errorDescription: "On-device speech recognition is not available for \(Locale.current.identifier); captions are never sent to a server.")
        }
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { c in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true
                    c.resume(returning: result.bestTranscription.segments.map {
                        Word(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                    })
                } else if let error {
                    done = true
                    c.resume(throwing: error)
                }
            }
        }
    }
}
