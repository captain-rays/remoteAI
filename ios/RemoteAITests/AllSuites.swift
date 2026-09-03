import RemoteAITestKit

/// Every suite that both the SwiftPM runner and the XCTest bridge execute.
public enum AllSuites {
    public static let suites: [TestSuite] = [
        BootstrapSuite.suite,
        ProtocolFixtureSuite.suite,
        AgentContractSuite.suite,
        MockAgentClientSuite.suite,
        ConnectionSuite.suite,
        CryptoSuite.suite,
        AppModelSuite.suite,
        ConversationViewModelSuite.suite,
        TranscriptRendererSuite.suite,
        FileBrowserViewModelSuite.suite,
        TransferSuite.suite,
        PairingViewModelSuite.suite,
        SettingsViewModelSuite.suite,
        AppDependenciesSuite.suite,
    ]
}
