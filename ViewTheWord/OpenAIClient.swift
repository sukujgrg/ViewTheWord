import Foundation

// MARK: - OpenAI API Models

struct OpenAIEmbeddingRequest: Codable {
    let model: String
    let input: [String]
    let encoding_format: String?

    init(model: String = "text-embedding-3-small", input: [String], encodingFormat: String? = "float") {
        self.model = model
        self.input = input
        self.encoding_format = encodingFormat
    }
}

struct OpenAIEmbeddingResponse: Codable {
    let data: [EmbeddingData]
    let model: String
    let usage: Usage

    struct EmbeddingData: Codable {
        let embedding: [Float]
        let index: Int
        let object: String
    }

    struct Usage: Codable {
        let prompt_tokens: Int
        let total_tokens: Int
    }
}

// MARK: - OpenAI Client

class OpenAIClient {
    private let apiKey: String
    private let baseURL = "https://api.openai.com/v1"
    private let session: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    /// Generate embeddings for a batch of texts
    /// - Parameters:
    ///   - texts: Array of texts to embed (max 2048 per batch recommended)
    ///   - model: Embedding model to use (default: text-embedding-3-small)
    /// - Returns: Array of embeddings in the same order as input texts
    func generateEmbeddings(texts: [String], model: String = "text-embedding-3-small") async throws -> [[Float]] {
        guard !texts.isEmpty else {
            return []
        }

        let request = OpenAIEmbeddingRequest(model: model, input: texts)

        var urlRequest = URLRequest(url: URL(string: "\(baseURL)/embeddings")!)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("OpenAI API error: \(httpResponse.statusCode) - \(errorBody)")
            throw OpenAIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let embeddingResponse = try JSONDecoder().decode(OpenAIEmbeddingResponse.self, from: data)

        // Sort by index to ensure correct order
        let sortedData = embeddingResponse.data.sorted { $0.index < $1.index }
        return sortedData.map { $0.embedding }
    }

    /// Calculate cosine similarity between two embeddings
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else {
            logger.error("Embedding dimensions don't match: \(a.count) vs \(b.count)")
            return 0
        }

        var dotProduct: Float = 0
        var magnitudeA: Float = 0
        var magnitudeB: Float = 0

        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            magnitudeA += a[i] * a[i]
            magnitudeB += b[i] * b[i]
        }

        let magnitude = sqrt(magnitudeA) * sqrt(magnitudeB)
        return magnitude > 0 ? dotProduct / magnitude : 0
    }
}

enum OpenAIError: Error, LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case invalidAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from OpenAI API"
        case .apiError(let statusCode, let message):
            return "OpenAI API error (\(statusCode)): \(message)"
        case .invalidAPIKey:
            return "Invalid or missing OpenAI API key"
        }
    }
}
