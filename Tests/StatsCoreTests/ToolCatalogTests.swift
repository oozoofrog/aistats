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
