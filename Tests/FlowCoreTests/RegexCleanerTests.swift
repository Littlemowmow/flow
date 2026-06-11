import Testing
@testable import FlowCore

@Test func stripsFillerWords() {
    #expect(RegexCleaner.clean("um so I think uh we should umm ship it") == "So I think we should ship it")
}

@Test func collapsesWhitespaceAndFixesPunctuationSpacing() {
    #expect(RegexCleaner.clean("hello ,  world .") == "Hello, world.")
}

@Test func capitalizesFirstLetter() {
    #expect(RegexCleaner.clean("this works") == "This works")
}

@Test func emptyAndFillerOnlyInputYieldsEmpty() {
    #expect(RegexCleaner.clean("  ") == "")
    #expect(RegexCleaner.clean("um uh") == "")
}

@Test func doesNotEatWordsContainingFillers() {
    #expect(RegexCleaner.clean("the umbrella is uhuru themed") == "The umbrella is uhuru themed")
}
