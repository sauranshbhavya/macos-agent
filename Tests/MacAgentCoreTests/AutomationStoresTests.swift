import Foundation
import Testing
@testable import MacAgentCore

struct AutomationStoresTests {
    @Test
    func storedRoutineIdentityMatchesItsName() {
        let routine = StoredRoutine(name: "Morning Setup", steps: [])
        #expect(routine.id == "Morning Setup")
    }
}
