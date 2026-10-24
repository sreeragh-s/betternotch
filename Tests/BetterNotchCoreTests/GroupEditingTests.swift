import Foundation
import Testing
@testable import BetterNotchCore

@Test func reassignmentPreservesEveryFileExactlyOnceAndRemovesEmptyGroups() {
    let a = evidence("a.txt").file, b = evidence("b.txt").file
    let first = FileGroup(name: "First", files: [a])
    let second = FileGroup(name: "Second", files: [b])
    var plan = GroupingPlan(groups: [first, second])
    plan.reassign(a.id, to: second.id)
    #expect(plan.groups.count == 1)
    #expect(Set(plan.groups.flatMap(\.files).map(\.id)) == [a.id, b.id])
    plan.separate(a.id)
    #expect(plan.groups.count == 2)
    #expect(plan.groups.flatMap(\.files).count == 2)
    plan.reassign(a.id, to: UUID())
    #expect(plan.groups.flatMap(\.files).count == 2)
}

@Test func namesCannotEscapeDestinationAndHaveBoundedUTF8Length() {
    #expect(FolderNames.safeComponent("../../Tax:2026") == "-..-Tax-2026")
    #expect(FolderNames.safeComponent(" . \n") == "Related Files")
    #expect(!FolderNames.safeComponent("one/two\\three").contains("/"))
    #expect(FolderNames.safeComponent(String(repeating: "📁", count: 100)).utf8.count <= 180)
}
