import Foundation
import RemoteAISuites
import RemoteAITestKit

let exitCode = await TestRunner.main(AllSuites.suites)
exit(exitCode)
