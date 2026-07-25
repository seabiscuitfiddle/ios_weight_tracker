import Foundation
import Testing
@testable import TallyStore

@Suite("Schema")
struct SchemaTests {
    @Test("schema version is set")
    func schemaVersion() {
        #expect(TallyStore.schemaVersion >= 1)
    }
}
