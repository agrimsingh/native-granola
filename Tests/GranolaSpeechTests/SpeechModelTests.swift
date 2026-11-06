import Foundation
import Testing
@testable import GranolaSpeech

@Suite struct SpeechModelTests {
    @Test func languageSupportFollowsTheModel() {
        #expect(ParakeetModel.v3.supports(Locale(identifier: "de_DE")))
        #expect(ParakeetModel.v3.supports(Locale(identifier: "en_SG")))
        #expect(!ParakeetModel.v3.supports(Locale(identifier: "ja_JP")))
        #expect(!ParakeetModel.v3.supports(Locale(identifier: "hi_IN")))
        #expect(ParakeetModel.v2.supports(Locale(identifier: "en_US")))
        #expect(!ParakeetModel.v2.supports(Locale(identifier: "fr_FR")))
        #expect(ParakeetModel.v3.languageCodes.count == 25)
    }
}
