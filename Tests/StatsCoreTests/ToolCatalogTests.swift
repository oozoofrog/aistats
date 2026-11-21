import Foundation
import Testing
@testable import StatsCore

@Test func instructionsPrefixNamesEveryTool() {
    let text = MCPServer.instructions
    let prefix = String(text.unicodeScalars.prefix(512))
    for tool in MCPServer.toolNames {
        #expect(prefix.split(separator: "\n").contains { $0.hasSuffix(tool) && $0.contains(": ") })
    }
    #expect(prefix.lowercased().contains("current user"))
    #expect(text.utf8.count <= 768 && text.utf8.allSatisfy { $0 < 128 })
    #expect(text.contains("\(Int(Waiter.timeoutRange.upperBound)) seconds"))
    #expect(text.contains("\(MCPServer.maxResponseBytes) bytes"))
}

@Test func toolCatalogPreservesBaselineContractsWithinByteBudget() throws {
    typealias Object = [String: Any]
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("scripts/fixtures/tool-contract-0.3.0.json"))
    let baseline = try #require(JSONSerialization.jsonObject(with: data) as? [Object])
    let tools = MCPServer.tools
    var wire = Data()
    JSONWriter.write(["tools": tools], into: &wire)
    #expect(wire.count <= 8653)
    for tool in tools {
        let description = try #require(tool["description"] as? String)
        #expect(description.utf8.count <= 512)
        let schema = try #require(tool["inputSchema"] as? Object)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self)
        #expect(!json.contains("\"$ref\"") && !json.contains("\"$defs\""))
    }
    for row in baseline {
        let name = try #require(row["name"] as? String)
        let tool = try #require(tools.first { $0["name"] as? String == name })
        #expect(tool["title"] as? String == row["title"] as? String)
        #expect(tool["annotations"] as? [String: Bool] == row["annotations"] as? [String: Bool])
        guard let selectors = row["selector"] as? [String: Object] else { continue }
        let inputs = try #require((tool["inputSchema"] as? Object)?["properties"] as? [String: Object])
        for (key, contract) in selectors {
            var property = try #require(inputs[key])
            let description = property.removeValue(forKey: "description") as? String ?? ""
            if name != "find_processes" { #expect(description.utf8.count <= 48) }
            #expect((property as NSDictionary).isEqual(to: contract))
        }
    }
}
