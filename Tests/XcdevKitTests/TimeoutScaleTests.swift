import Foundation
import Testing
@testable import XcdevKit

/// `XCD_TIMEOUT_SCALE`, which stretches xcd's limits on a slow machine.
@Suite struct TimeoutScaleTests {
    @Test func aNumberOfAtLeastOneIsTheFactor() {
        #expect(TimeoutScale(environment: ["XCD_TIMEOUT_SCALE": "4"]).factor == 4)
        #expect(TimeoutScale(environment: ["XCD_TIMEOUT_SCALE": "2.5"]).factor == 2.5)
        #expect(TimeoutScale(environment: ["XCD_TIMEOUT_SCALE": "4"]).scaled(.seconds(60)) == .seconds(240))
    }

    /// Unset, or anything that would not lengthen a limit, leaves every limit as it is.
    @Test(arguments: [nil, "", "abc", "0", "0.5", "-2", "inf", "nan"])
    func anythingElseIsOne(value: String?) {
        let scale = TimeoutScale(environment: value.map { ["XCD_TIMEOUT_SCALE": $0] } ?? [:])
        #expect(scale.factor == 1 && scale.scaled(.seconds(60)) == .seconds(60))
    }
}
