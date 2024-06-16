//
//  ApiCalls.swift
//  ViewTheWord
//
//  Created by Suku on 8/6/2024.
//

import Foundation
import SwiftUI

func sendTextOverNetwork(text: String, title: String) {
    // https://github.com/sukujgrg/echoHttp/tree/main
    @AppStorage("apiUrlToPost") var apiUrlToPost: URL?
    guard let url = apiUrlToPost, url.host != nil, url.scheme == "http" || url.scheme == "https" else { return }
    var request = URLRequest(url: url)
    let params = ["text": text, "title": title]
    do {
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: params, options: [])
        request.timeoutInterval = 0.5
        URLSession.shared.dataTask(with: request)
        { data, response, error in
            if error != nil {
                logger.error("\(error)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 201 else {
                logger.error("\(request) \(response)")
                return
            }
        }
        .resume()
    }
}

func clearApi() {
    sendTextOverNetwork(text: "", title: "")
}
