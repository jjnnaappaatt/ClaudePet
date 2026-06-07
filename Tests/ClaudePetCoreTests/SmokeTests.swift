import Testing
@testable import ClaudePetCore

@Test func coreVersionIsSet() {
    #expect(!ClaudePetCore.version.isEmpty)
}
