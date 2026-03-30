import Foundation

final class BugReportSubmitter {

    struct SubmissionResult {
        let issueURL: String
        let issueNumber: Int
    }

    enum SubmissionError: LocalizedError {
        case encodingFailed
        case httpError(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .encodingFailed:      return "Failed to encode bug report payload."
            case .httpError(let code): return "GitHub returned HTTP \(code)."
            case .invalidResponse:     return "Unexpected response from GitHub."
            }
        }
    }

    static func submit(
        payload: BugReportPayload,
        description: String,
        steps: String
    ) async throws -> SubmissionResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let payloadJSON = String(data: try encoder.encode(payload), encoding: .utf8) else {
            throw SubmissionError.encodingFailed
        }

        let stepsSection = steps.isEmpty ? "Not provided" : steps
        let body = """
        ## Description
        \(description)

        ## Steps to Reproduce
        \(stepsSection)

        ## Environment
        | Key | Value |
        |---|---|
        | App Version | \(payload.appVersion) |
        | macOS | \(payload.macosVersion) |
        | Hardware | \(payload.hardwareModel) |
        | RAM | \(payload.physicalMemoryGB) GB |
        | Whisper Model | \(payload.whisperModel ?? "n/a") |
        | LLM Backend | \(payload.llmBackend ?? "n/a") |
        | Recording State | \(payload.recordingState ?? "n/a") |
        | Calendar Permission | \(payload.calendarPermission) |
        | Microphone Permission | \(payload.microphonePermission ?? "n/a") |
        | iCloud Sync | \(payload.icloudSyncEnabled ? "enabled" : "disabled") |

        <details>
        <summary>Full payload JSON</summary>

        ```json
        \(payloadJSON)
        ```
        </details>
        """

        let issueTitle = "[Bug] \(description.prefix(80))"
        let requestBody: [String: Any] = [
            "title": issueTitle,
            "body": body,
            "labels": ["bug-report"]
        ]

        let url = URL(string: "https://api.github.com/repos/\(BugReportConfig.repoOwner)/\(BugReportConfig.repoName)/issues")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(BugReportConfig.githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SubmissionError.invalidResponse
        }
        guard httpResponse.statusCode == 201 else {
            throw SubmissionError.httpError(httpResponse.statusCode)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let htmlURL = json?["html_url"] as? String,
              let number = json?["number"] as? Int else {
            throw SubmissionError.invalidResponse
        }
        return SubmissionResult(issueURL: htmlURL, issueNumber: number)
    }
}
