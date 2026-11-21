import Foundation

enum ResponseBudget {
    static func fit(_ object: [String: Any], payload: Data, line: Data) -> Data {
        guard let body = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return line }
        let strict = body["trackId"] != nil || body["tracks"] != nil || body["selector"] != nil
            || body["condition"] as? String == "port_listening" || body["condition"] as? String == "process_started"
        let lineLimit = strict ? MCPServer.maxResponseBytes : 9216
        if payload.count <= MCPServer.maxResponseBytes && line.count <= lineLimit { return line }
        var fields = body
        func fittedLine() -> Data? {
            guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]),
                  data.count <= MCPServer.maxResponseBytes else { return nil }
            var response = object
            response["result"] = ["content": [["type": "text", "text": "Result details follow.\n\n" + String(decoding: data, as: UTF8.self)]],
                                  "isError": false, "structuredContent": RawJSON(data: data)] as [String: Any]
            let candidate = MCPServer.encodeLine(response)
            return candidate.count <= lineLimit ? candidate : nil
        }
        if let result = fittedLine() { return result }
        for key in ["tracks", "topProcesses", "culprits", "processes"] {
            guard var rows = fields[key] as? [Any] else { continue }
            while !rows.isEmpty {
                rows.removeLast()
                fields[key] = rows
                fields[key + "Omitted"] = (fields[key + "Omitted"] as? Int ?? 0) + 1
                if let result = fittedLine() { return result }
            }
        }
        if var toolchain = fields["toolchain"] as? [String: Any] {
            if let errors = toolchain.removeValue(forKey: "errors") as? [String] {
                toolchain["errorsOmitted"] = errors.count
                fields["toolchain"] = toolchain
                if let result = fittedLine() { return result }
            }
            for key in ["toolchains", "developerDir", "commandLineToolsPath", "swiftVersion", "xcodeVersion", "xcodeBuild"] {
                if let value = toolchain[key] as? String, value.utf8.count > 96 {
                    toolchain[key] = String(value.unicodeScalars.prefix(64)) + "…"
                    fields["toolchain"] = toolchain
                    if let result = fittedLine() { return result }
                }
            }
        }
        if let reason = fields["reason"] as? String {
            fields["reason"] = String(reason.unicodeScalars.prefix(120)) + "…"
            if let result = fittedLine() { return result }
        }
        var response = object
        response["result"] = ["content": [["type": "text", "text": "Result exceeds the response size budget."]],
                              "isError": true] as [String: Any]
        return MCPServer.encodeLine(response)
    }
}
