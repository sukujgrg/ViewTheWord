//
//  ApiCalls.swift
//  ViewTheWord
//
//  Created by Suku on 8/6/2024.
//

import Foundation
import SwiftUI

class NetworkManager {
    static let shared = NetworkManager()
    private var activeTasks: [URLSessionDataTask] = []

    private init() {}

    func sendTextOverNetwork(text: String, title: String) {
        // https://github.com/sukujgrg/echoHttp/tree/main
        guard let apiUrlString = UserDefaults.standard.string(forKey: "apiUrlToPost"),
              let url = URL(string: apiUrlString),
              url.host != nil,
              url.scheme == "http" || url.scheme == "https" else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 0.5

        let params = ["text": text, "title": title]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: params, options: []) else {
            logger.error("Failed to serialize JSON parameters")
            return
        }
        request.httpBody = httpBody

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            defer {
                self?.removeTask(task: nil)
            }

            if let error = error {
                logger.error("Network error: \(error.localizedDescription)")
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response type")
                return
            }

            guard httpResponse.statusCode == 201 else {
                logger.error("Unexpected status code: \(httpResponse.statusCode)")
                return
            }
        }

        activeTasks.append(task)
        task.resume()
    }

    private func removeTask(task: URLSessionDataTask?) {
        activeTasks.removeAll { $0 == task }
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
