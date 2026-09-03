import RemoteAITestKit

/// Every suite that both the SwiftPM runner and the XCTest bridge execute.
public enum AllSuites {
    public static let suites: [TestSuite] = [
        BootstrapSuite.suite,
        ProtocolFixtureSuite.suite,
        MockAgentClientSuite.suite,
        ConnectionSuite.suite,
        CryptoSuite.suite,
    ]
}
