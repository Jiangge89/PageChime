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

    func testEnglishNegation() {
        let events = engine.analyze(text: "The frog did not make a sound.", language: .english)
        let soundIDs = events.map(\.soundID)
        XCTAssertFalse(soundIDs.contains("frog_croak"), "Should not trigger when negated")
    }

    func testChineseNegation() {
        let events = engine.analyze(text: "青蛙没有叫。", language: .chinese)
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
        let events = engine.analyze(text: "The dog did not bark, but the cat meowed.", language: .english)
        let soundIDs = Set(events.map(\.soundID))
        XCTAssertFalse(soundIDs.contains("dog_bark"), "Dog should be negated")
        XCTAssertTrue(soundIDs.contains("cat_meow"), "Cat should trigger")
    }

    // MARK: - Question Detection

    func testEnglishQuestion() {
        let events = engine.analyze(text: "What sound does a frog make?", language: .english)
        XCTAssertFalse(events.isEmpty, "Should detect frog in question")
        let frogEvent = events.first { $0.soundID == "frog_croak" }
        XCTAssertNotNil(frogEvent, "Should have frog event")
        XCTAssertEqual(frogEvent?.delayMilliseconds, 1500, "Question should add delay")
    }

    func testChineseQuestion() {
        let events = engine.analyze(text: "青蛙是怎么叫的？", language: .chinese)
        XCTAssertFalse(events.isEmpty, "Should detect 青蛙 in question")
        let frogEvent = events.first { $0.soundID == "frog_croak" }
        XCTAssertNotNil(frogEvent, "Should have frog event")
        XCTAssertEqual(frogEvent?.delayMilliseconds, 1500, "Question should add delay")
    }

    // MARK: - Max Effects Per Sentence

    func testMaxTwoEffectsPerSentence() {
        let events = engine.analyze(
            text: "It was raining, and then thunder shook the forest.",
            language: .english
        )
        XCTAssertLessThanOrEqual(events.count, 2, "Should not exceed 2 effects per sentence")
        let soundIDs = Set(events.map(\.soundID))
        XCTAssertTrue(
            soundIDs.contains("rain_light") || soundIDs.contains("thunder"),
            "Should contain rain or thunder"
        )
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

        let events1 = engine.analyze(text: "The frog croaked.", language: .english)
        XCTAssertEqual(events1.count, 1, "First mention should trigger")

        time = time.addingTimeInterval(5)
        engine.reset()
        // Re-create engine to properly test - but we need cooldown state
        // Actually, reset clears cooldowns, so let's test differently:

        let engine2 = StoryEventEngine()
        var time2 = Date()
        engine2.currentTime = { time2 }

        let first = engine2.analyze(text: "The frog croaked.", language: .english)
        XCTAssertEqual(first.count, 1, "First mention should trigger")

        time2 = time2.addingTimeInterval(5)
        let second = engine2.analyze(text: "Another frog appeared.", language: .english)
        XCTAssertEqual(second.filter({ $0.soundID == "frog_croak" }).count, 0,
                       "Should be blocked by cooldown")

        time2 = time2.addingTimeInterval(16)
        let third = engine2.analyze(text: "A frog jumped out.", language: .english)
        XCTAssertEqual(third.filter({ $0.soundID == "frog_croak" }).count, 1,
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
