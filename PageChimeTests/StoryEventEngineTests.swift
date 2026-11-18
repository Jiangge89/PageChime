import XCTest
@testable import PageChime

final class StoryEventEngineTests: XCTestCase {
    var engine: StoryEventEngine!

    override func setUp() {
        super.setUp()
        engine = StoryEventEngine()
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    // MARK: - Basic Detection

    func testFrogAndWaterSplash() {
        let events = engine.analyze(text: "The frog jumped into the pond.", language: .english)
        let soundIDs = Set(events.map(\.soundID))
        XCTAssertTrue(soundIDs.contains("frog_croak"), "Should detect frog")
        XCTAssertTrue(soundIDs.contains("water_splash"), "Should detect water splash")
    }

    func testChineseFrogAndWaterSplash() {
        let events = engine.analyze(text: "青蛙跳进了池塘。", language: .chinese)
        let soundIDs = Set(events.map(\.soundID))
        XCTAssertTrue(soundIDs.contains("frog_croak"), "Should detect 青蛙")
        XCTAssertTrue(soundIDs.contains("water_splash"), "Should detect 跳进/池塘")
    }

    // MARK: - Negation

    // Negation is proximity-based: only the ~15 chars (en) / 5 chars (zh)
    // before a keyword are checked, so unpunctuated speech doesn't negate
    // every keyword in the transcript.

    func testEnglishNegation() {
        let events = engine.analyze(text: "There was no frog in the pond.", language: .english)
        let soundIDs = events.map(\.soundID)
        XCTAssertFalse(soundIDs.contains("frog_croak"), "Should not trigger when negated")
    }

    func testChineseNegation() {
        let events = engine.analyze(text: "池塘里没有青蛙。", language: .chinese)
        let soundIDs = events.map(\.soundID)
        XCTAssertFalse(soundIDs.contains("frog_croak"), "Should not trigger when negated")
    }

    func testEnglishRainNegation() {
        let events = engine.analyze(text: "It was not raining.", language: .english)
        let soundIDs = events.map(\.soundID)
        XCTAssertFalse(soundIDs.contains("rain_light"), "Should not trigger rain when negated")
    }

    func testChineseRainNegation() {
        let events = engine.analyze(text: "天没有下雨。", language: .chinese)
        let soundIDs = events.map(\.soundID)
        XCTAssertFalse(soundIDs.contains("rain_light"), "Should not trigger rain when negated")
    }

    func testPartialNegationInCompoundSentence() {
        let events = engine.analyze(text: "There was no dog, but the cat meowed.", language: .english)
        let soundIDs = Set(events.map(\.soundID))
        XCTAssertFalse(soundIDs.contains("dog_bark"), "Dog should be negated")
        XCTAssertTrue(soundIDs.contains("cat_meow"), "Cat should trigger")
    }

    func testDistantChineseNegationDoesNotSuppress() {
        // Unpunctuated speech: "没有" far before the keyword must not negate it.
        let events = engine.analyze(text: "天上没有一朵云彩院子里的小狗在跑", language: .chinese)
        XCTAssertTrue(events.contains { $0.soundID == "dog_bark" },
                      "Negation outside the proximity window should not suppress")
    }

    func testPostKeywordNegationIsNotDetected() {
        // Known limitation: negation after the keyword is not detected.
        let events = engine.analyze(text: "The frog did not make a sound.", language: .english)
        XCTAssertTrue(events.contains { $0.soundID == "frog_croak" })
    }

    // MARK: - Questions

    func testEnglishQuestionTriggersImmediately() {
        let events = engine.analyze(text: "What sound does a frog make?", language: .english)
        let frogEvent = events.first { $0.soundID == "frog_croak" }
        XCTAssertNotNil(frogEvent, "Should detect frog in question")
        XCTAssertEqual(frogEvent?.delayMilliseconds, 0, "Questions are not delayed")
    }

    func testChineseQuestionTriggersImmediately() {
        let events = engine.analyze(text: "青蛙是怎么叫的？", language: .chinese)
        let frogEvent = events.first { $0.soundID == "frog_croak" }
        XCTAssertNotNil(frogEvent, "Should detect 青蛙 in question")
        XCTAssertEqual(frogEvent?.delayMilliseconds, 0, "Questions are not delayed")
    }

    // MARK: - Multiple Effects

    func testNoLimitOnEffectsPerPass() {
        let events = engine.analyze(
            text: "It was raining, and then thunder shook the forest.",
            language: .english
        )
        let soundIDs = Set(events.map(\.soundID))
        XCTAssertTrue(soundIDs.contains("rain_light"))
        XCTAssertTrue(soundIDs.contains("thunder"))
        XCTAssertTrue(soundIDs.contains("forest_ambience"))
    }

    // MARK: - Duplicate Suppression

    func testChineseDuplicateInSentence() {
        let events = engine.analyze(text: "狗，狗，狗跑了过来。", language: .chinese)
        let dogEvents = events.filter { $0.soundID == "dog_bark" }
        XCTAssertEqual(dogEvents.count, 1, "Should only trigger dog once per sentence")
    }

    func testEnglishDuplicateInSentence() {
        let events = engine.analyze(text: "The dog and another dog ran by.", language: .english)
        let dogEvents = events.filter { $0.soundID == "dog_bark" }
        XCTAssertEqual(dogEvents.count, 1, "Should only trigger dog once per sentence")
    }

    // MARK: - Cooldown

    func testCooldownBlocksRepeat() {
        var time = Date()
        engine.currentTime = { time }

        let first = engine.analyze(text: "The frog croaked.", language: .english)
        XCTAssertEqual(first.filter { $0.soundID == "frog_croak" }.count, 1,
                       "First mention should trigger")

        time = time.addingTimeInterval(2)
        let second = engine.analyze(text: "Another frog appeared.", language: .english)
        XCTAssertEqual(second.filter { $0.soundID == "frog_croak" }.count, 0,
                       "Should be blocked within the 3s cooldown")

        time = time.addingTimeInterval(2)
        let third = engine.analyze(text: "A frog jumped out.", language: .english)
        XCTAssertEqual(third.filter { $0.soundID == "frog_croak" }.count, 1,
                       "Should trigger after cooldown expires")
    }

    // MARK: - Session Reset

    func testResetClearsCooldowns() {
        let events1 = engine.analyze(text: "The frog croaked.", language: .english)
        XCTAssertEqual(events1.count, 1)

        engine.reset()

        let events2 = engine.analyze(text: "The frog croaked.", language: .english)
        XCTAssertEqual(events2.count, 1, "After reset, cooldowns should be cleared")
    }

    // MARK: - Bilingual Matching

    func testEnglishDogDetection() {
        let events = engine.analyze(text: "The dog barked loudly.", language: .english)
        XCTAssertTrue(events.contains { $0.soundID == "dog_bark" })
    }

    func testChineseDogDetection() {
        let events = engine.analyze(text: "小狗汪汪叫。", language: .chinese)
        XCTAssertTrue(events.contains { $0.soundID == "dog_bark" })
    }

    func testEnglishCatDetection() {
        let events = engine.analyze(text: "The kitten purred softly.", language: .english)
        XCTAssertTrue(events.contains { $0.soundID == "cat_meow" })
    }

    func testChineseCatDetection() {
        let events = engine.analyze(text: "小猫在角落里叫。", language: .chinese)
        XCTAssertTrue(events.contains { $0.soundID == "cat_meow" })
    }

    // MARK: - Weather Detection

    func testRainDetection() {
        let events = engine.analyze(text: "It started raining heavily.", language: .english)
        XCTAssertTrue(events.contains { $0.soundID == "rain_light" })
    }

    func testThunderDetection() {
        let events = engine.analyze(text: "Thunder rumbled in the distance.", language: .english)
        XCTAssertTrue(events.contains { $0.soundID == "thunder" })
    }

    func testChineseWindDetection() {
        let events = engine.analyze(text: "外面刮风了。", language: .chinese)
        XCTAssertTrue(events.contains { $0.soundID == "wind" })
    }

    // MARK: - Vehicle Detection

    func testCarDetection() {
        let events = engine.analyze(text: "A car drove past.", language: .english)
        XCTAssertTrue(events.contains { $0.soundID == "car" })
    }

    func testChineseTrainDetection() {
        let events = engine.analyze(text: "火车来了。", language: .chinese)
        XCTAssertTrue(events.contains { $0.soundID == "train" })
    }

    // MARK: - Environment Detection

    func testForestDetection() {
        let events = engine.analyze(text: "They walked deep into the forest.", language: .english)
        XCTAssertTrue(events.contains { $0.soundID == "forest_ambience" })
    }

    func testChineseOceanDetection() {
        let events = engine.analyze(text: "他们来到了海边。", language: .chinese)
        XCTAssertTrue(events.contains { $0.soundID == "ocean_waves" })
    }

    // MARK: - No False Positives

    func testNoTriggerForUnrelatedText() {
        let events = engine.analyze(text: "The little girl ate her breakfast.", language: .english)
        XCTAssertTrue(events.isEmpty, "Unrelated text should not trigger any events")
    }

    func testNoTriggerForChineseUnrelatedText() {
        let events = engine.analyze(text: "小朋友吃了早饭。", language: .chinese)
        XCTAssertTrue(events.isEmpty, "Unrelated Chinese text should not trigger")
    }

    // MARK: - Multiple Sentences

    func testMultipleSentences() {
        let events = engine.analyze(
            text: "The dog barked. The cat meowed.",
            language: .english
        )
        let soundIDs = Set(events.map(\.soundID))
        XCTAssertTrue(soundIDs.contains("dog_bark"))
        XCTAssertTrue(soundIDs.contains("cat_meow"))
    }

    // MARK: - Action Detection

    func testDoorKnock() {
        let events = engine.analyze(text: "Someone was knocking at the door.", language: .english)
        XCTAssertTrue(events.contains { $0.soundID == "door_knock" })
    }

    func testChineseFootsteps() {
        let events = engine.analyze(text: "远处传来了脚步声。", language: .chinese)
        XCTAssertTrue(events.contains { $0.soundID == "footsteps" })
    }

    // MARK: - Event Properties

    func testEventHasCorrectType() {
        let events = engine.analyze(text: "The frog croaked.", language: .english)
        XCTAssertEqual(events.first?.type, .animal)
        XCTAssertEqual(events.first?.entity, "frog")
    }

    func testNonQuestionHasNoDelay() {
        let events = engine.analyze(text: "The frog croaked.", language: .english)
        XCTAssertEqual(events.first?.delayMilliseconds, 0)
    }
}
