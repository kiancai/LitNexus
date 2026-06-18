import Foundation

// 同步 HTTP 辅助（在后台线程调用，不要在主线程用）。引擎里的下载/AI 都用它。

enum HTTPError: Error, LocalizedError {
    case noResponse
    case status(Int, String)
    case noData
    case transport(String)

    var isRateLimited: Bool {
        if case .status(let code, _) = self { return code == 429 }
        return false
    }
    var errorDescription: String? {
        switch self {
        case .noResponse: return "无响应"
        case .status(let c, let b): return "HTTP \(c)：\(b.prefix(200))"
        case .noData: return "无响应数据"
        case .transport(let m): return m
        }
    }
}

enum HTTP {
    static func getJSON(_ url: URL, timeout: TimeInterval = 30) throws -> Any {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        return try send(req)
    }

    static func postJSON(_ url: URL, headers: [String: String], body: Data,
                         timeout: TimeInterval = 120) throws -> Any {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try send(req)
    }

    private static func send(_ req: URLRequest) throws -> Any {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Any, Error> = .failure(HTTPError.noResponse)
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { result = .failure(HTTPError.transport(err.localizedDescription)); return }
            guard let http = resp as? HTTPURLResponse else {
                result = .failure(HTTPError.noResponse); return
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                result = .failure(HTTPError.status(http.statusCode, body)); return
            }
            guard let data else { result = .failure(HTTPError.noData); return }
            do { result = .success(try JSONSerialization.jsonObject(with: data)) }
            catch { result = .failure(HTTPError.transport("JSON 解析失败：\(error.localizedDescription)")) }
        }
        task.resume()
        sem.wait()
        return try result.get()
    }
}
