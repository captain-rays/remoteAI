import Foundation
import RemoteAIKit
import RemoteAITestKit

public enum BootstrapSuite {
    public static let suite = TestSuite(
        name: "BootstrapSuite",
        cases: [
            TestCase("app name is stable") {
                try expectEqual(AppMetadata.name, "RemoteAI")
            },
            TestCase("protocol version is 1") {
                try expectEqual(AppMetadata.protocolVersion, 1)
            },
        ]
    )
}
