import Foundation

struct MultipartFormData {
    private let boundary: String
    private var body = Data()

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    init(boundary: String = UUID().uuidString) {
        self.boundary = boundary
    }

    mutating func append(field name: String, value: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func append(file data: Data, name: String, fileName: String, mimeType: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }

    var finalized: Data {
        var result = body
        result.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return result
    }
}
