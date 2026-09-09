import Foundation

func uiError(_ error: Error, fallback: String) -> String {
    (error as? DictationError)?.localizedDescription ?? L(fallback)
}

func workerErrorMessage(_ message: [String: Any]) -> String {
    switch message["code"] as? String {
    case "model_missing": return L("No model installed. Choose Download in Settings.")
    case "audio_duration": return L("Recording must be between 1 and 120 seconds.")
    case "invalid_audio": return L("The recording contains invalid audio data.")
    case "silence": return L("No clear audio detected. Nothing pasted.")
    case "empty_result": return L("No speech was recognized. Nothing pasted.")
    case "token_limit": return L("The transcript exceeded the length limit. Try a shorter recording.")
    case "audio_io": return L("Unable to read the recording. Please try again.")
    case "worker_exited": return String(format: L("Speech worker exited (%d). Please try again."), message["exit_status"] as? Int32 ?? -1)
    default: return L("Transcription failed. Please try again.")
    }
}
