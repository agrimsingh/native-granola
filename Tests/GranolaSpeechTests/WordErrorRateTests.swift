import Testing
@testable import GranolaSpeech

@Suite struct WordErrorRateTests {
    @Test func identicalAfterNormalization() {
        let w = WordErrorRate.compute(reference: "Hello, World! It's 3 o'clock.", hypothesis: "hello world it is three o'clock")
        #expect(w.errors == 0)
        #expect(w.referenceWords == 6)
        #expect(w.rate == 0)
    }

    @Test func countsEditTypes() {
        let w = WordErrorRate.compute(reference: "the cat sat on the mat", hypothesis: "the bat sat on mat")
        #expect(w.substitutions == 1)
        #expect(w.deletions == 1)
        #expect(w.insertions == 0)
        #expect(w.referenceWords == 6)
        #expect(abs(w.rate - 2.0 / 6) < 1e-9)
        let ins = WordErrorRate.compute(reference: "a b c", hypothesis: "a b x c d")
        #expect(ins.insertions == 2 && ins.substitutions == 0 && ins.deletions == 0)
    }

    @Test func emptySides() {
        #expect(WordErrorRate.compute(reference: "", hypothesis: "").rate == 0)
        #expect(WordErrorRate.compute(reference: "", hypothesis: "noise").insertions == 1)
        let w = WordErrorRate.compute(reference: "two words", hypothesis: "")
        #expect(w.deletions == 2)
        #expect(w.rate == 1)
    }

    @Test func numbersAndSymbols() {
        #expect(WordErrorRate.normalize("1,250") == ["one", "thousand", "two", "hundred", "fifty"])
        #expect(WordErrorRate.normalize("15%") == ["fifteen", "percent"])
        #expect(WordErrorRate.normalize("21st and 3rd") == ["twenty", "first", "and", "third"])
        #expect(WordErrorRate.normalize("twenty-one Q&A") == ["twenty", "one", "q", "and", "a"])
        #expect(WordErrorRate.normalize("Don’t \"quote\" me") == ["do", "not", "quote", "me"])
        #expect(WordErrorRate.spell(101) == ["one", "hundred", "one"])
        #expect(WordErrorRate.spell(40) == ["forty"])
    }

    @Test func aggregates() {
        let a = WordErrorRate.compute(reference: "a b c d", hypothesis: "a b c")
        let b = WordErrorRate.compute(reference: "e f", hypothesis: "e g")
        let sum = a + b
        #expect(sum.errors == 2)
        #expect(sum.referenceWords == 6)
    }
}
