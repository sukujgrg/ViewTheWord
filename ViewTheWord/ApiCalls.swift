//
//  ApiCalls.swift
//  ViewTheWord
//
//  Created by Suku on 8/6/2024.
//

import Foundation

final class NetworkManager {
    static let shared = NetworkManager()

    private struct VersePayload: Encodable {
        let text: String
        let title: String
    }

    private init() {}

    func sendTextOverNetwork(text: String, title: String) {
        // https://github.com/sukujgrg/echoHttp/tree/main
        guard let apiUrlString = UserDefaults.standard.string(forKey: AppDefaultsKey.apiUrlToPost),
              let url = URL(string: apiUrlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host != nil,
              url.scheme == "http" || url.scheme == "https" else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 0.5

        let payload = VersePayload(text: text, title: title)
        guard let httpBody = try? JSONEncoder().encode(payload) else {
            logger.fileError("Failed to encode network payload")
            return
        }
        request.httpBody = httpBody

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                logger.fileError("Network error: \(error.localizedDescription)")
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.fileError("Invalid response type")
                return
            }

            guard httpResponse.statusCode == 201 else {
                logger.fileError("Unexpected status code: \(httpResponse.statusCode)")
                return
            }
        }.resume()
    }

    func clearApi() {
        sendTextOverNetwork(text: "", title: "")
    }
}

// Convenience functions for backwards compatibility
func sendTextOverNetwork(text: String, title: String) {
    NetworkManager.shared.sendTextOverNetwork(text: text, title: title)
}

func clearApi() {
    NetworkManager.shared.clearApi()
}
