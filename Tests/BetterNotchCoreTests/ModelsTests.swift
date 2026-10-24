import Foundation
import Testing
@testable import BetterNotchCore

@Test func groupingPlanRoundTripsWithoutLosingSourceIdentity() throws {
    let file = FileDescriptor(url: URL(fileURLWithPath: "/tmp/invoice.pdf"), size: 42,
                              modified: Date(timeIntervalSince1970: 100), typeIdentifier: "com.adobe.pdf")
    let plan = GroupingPlan(groups: [FileGroup(name: "Invoices", files: [file])])
    let decoded = try JSONDecoder().decode(GroupingPlan.self, from: JSONEncoder().encode(plan))
    #expect(decoded == plan)
    #expect(decoded.groups[0].files[0].url == file.url)
}
