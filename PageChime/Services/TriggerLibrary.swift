import Foundation

enum TriggerLibrary {
    static let defaultTriggers: [TriggerEntry] = animals + weather + actions + vehicles + environments

    // MARK: - Animals

    static let animals: [TriggerEntry] = [
        TriggerEntry(
            entity: "frog", soundID: "frog_croak", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["frog", "toad"], "zh": ["青蛙", "蟾蜍"]]
        ),
        TriggerEntry(
            entity: "dog", soundID: "dog_bark", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["dog", "puppy"], "zh": ["狗", "小狗"]]
        ),
        TriggerEntry(
            entity: "cat", soundID: "cat_meow", eventType: .animal,
            intensity: .soft, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["cat", "kitten"], "zh": ["猫", "小猫"]]
        ),
        TriggerEntry(
            entity: "cow", soundID: "cow_moo", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["cow"], "zh": ["牛"]]
        ),
        TriggerEntry(
            entity: "sheep", soundID: "sheep_baa", eventType: .animal,
            intensity: .soft, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["sheep", "lamb"], "zh": ["羊", "小羊"]]
        ),
        TriggerEntry(
            entity: "lion", soundID: "lion_roar", eventType: .animal,
            intensity: .strong, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["lion"], "zh": ["狮子"]]
        ),
        TriggerEntry(
            entity: "elephant", soundID: "elephant_trumpet", eventType: .animal,
            intensity: .strong, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["elephant"], "zh": ["大象"]]
        ),
        TriggerEntry(
            entity: "bird", soundID: "bird_chirp", eventType: .animal,
            intensity: .soft, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["bird", "birds"], "zh": ["鸟", "小鸟"]]
        ),
        TriggerEntry(
            entity: "owl", soundID: "owl_hoot", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["owl"], "zh": ["猫头鹰"]]
        ),
        TriggerEntry(
            entity: "duck", soundID: "duck_quack", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["duck"], "zh": ["鸭子"]]
        ),
        TriggerEntry(
            entity: "chicken", soundID: "chicken_cluck", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["chicken", "rooster"], "zh": ["鸡", "公鸡"]]
        ),
        TriggerEntry(
            entity: "horse", soundID: "horse_neigh", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["horse"], "zh": ["马"]]
        ),
        TriggerEntry(
            entity: "squirrel", soundID: "squirrel_chirp", eventType: .animal,
            intensity: .soft, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["squirrel"], "zh": ["松鼠"]]
        ),
        TriggerEntry(
            entity: "dinosaur", soundID: "dinosaur_roar", eventType: .animal,
            intensity: .strong, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["dinosaur", "t-rex"], "zh": ["恐龙", "霸王龙"]]
        ),
        TriggerEntry(
            entity: "whale", soundID: "whale_call", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["whale"], "zh": ["鲸鱼", "鲸"]]
        ),
    ]

    // MARK: - Weather

    static let weather: [TriggerEntry] = [
        TriggerEntry(
            entity: "rain", soundID: "rain_light", eventType: .weather,
            intensity: .soft, cooldownSeconds: 20, isAmbience: true,
            keywords: ["en": ["rain", "raining"], "zh": ["下雨", "雨"]]
        ),
        TriggerEntry(
            entity: "thunder", soundID: "thunder", eventType: .weather,
            intensity: .strong, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["thunder"], "zh": ["打雷", "雷声"]]
        ),
        TriggerEntry(
            entity: "wind", soundID: "wind", eventType: .weather,
            intensity: .normal, cooldownSeconds: 20, isAmbience: true,
            keywords: ["en": ["wind", "windy"], "zh": ["风", "刮风"]]
        ),
        TriggerEntry(
            entity: "storm", soundID: "storm", eventType: .weather,
            intensity: .strong, cooldownSeconds: 20, isAmbience: true,
            keywords: ["en": ["storm"], "zh": ["暴风雨"]]
        ),
    ]

    // MARK: - Actions and Objects

    static let actions: [TriggerEntry] = [
        TriggerEntry(
            entity: "knock", soundID: "door_knock", eventType: .action,
            intensity: .normal, cooldownSeconds: 10, isAmbience: false,
            keywords: ["en": ["knock", "knocking"], "zh": ["敲门"]]
        ),
        TriggerEntry(
            entity: "door", soundID: "door_open", eventType: .action,
            intensity: .soft, cooldownSeconds: 10, isAmbience: false,
            keywords: ["en": ["door opened", "open the door", "opened the door"], "zh": ["开门", "门打开了"]]
        ),
        TriggerEntry(
            entity: "footsteps", soundID: "footsteps", eventType: .action,
            intensity: .soft, cooldownSeconds: 10, isAmbience: false,
            keywords: ["en": ["footsteps", "walking", "walked"], "zh": ["走路", "脚步"]]
        ),
        TriggerEntry(
            entity: "running", soundID: "running", eventType: .action,
            intensity: .normal, cooldownSeconds: 10, isAmbience: false,
            keywords: ["en": ["running", "ran "], "zh": ["跑", "跑过来"]]
        ),
        TriggerEntry(
            entity: "splash", soundID: "water_splash", eventType: .action,
            intensity: .normal, cooldownSeconds: 10, isAmbience: false,
            keywords: [
                "en": ["splash", "jumped into", "fell into", "pond", "pool"],
                "zh": ["水花", "跳进水里", "跳进", "池塘"],
            ]
        ),
        TriggerEntry(
            entity: "bell", soundID: "bell", eventType: .object,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["bell", "ringing"], "zh": ["铃铛", "铃声"]]
        ),
        TriggerEntry(
            entity: "clock", soundID: "clock_tick", eventType: .object,
            intensity: .soft, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["clock", "ticking"], "zh": ["时钟", "滴答"]]
        ),
        TriggerEntry(
            entity: "laugh", soundID: "laughter", eventType: .action,
            intensity: .normal, cooldownSeconds: 10, isAmbience: false,
            keywords: ["en": ["laugh", "laughing", "laughed"], "zh": ["笑", "大笑"]]
        ),
        TriggerEntry(
            entity: "door_slam", soundID: "door_slam", eventType: .action,
            intensity: .strong, cooldownSeconds: 10, isAmbience: false,
            keywords: ["en": ["slammed the door", "door slammed", "slam"], "zh": ["砰", "摔门", "关门"]]
        ),
        TriggerEntry(
            entity: "crying", soundID: "child_crying", eventType: .action,
            intensity: .normal, cooldownSeconds: 10, isAmbience: false,
            keywords: ["en": ["crying", "cried", "sobbing", "tears"], "zh": ["哭", "哭泣", "流泪"]]
        ),
        TriggerEntry(
            entity: "waves", soundID: "waves_crashing", eventType: .action,
            intensity: .normal, cooldownSeconds: 10, isAmbience: false,
            keywords: ["en": ["waves", "wave"], "zh": ["海浪", "浪花", "波浪"]]
        ),
        TriggerEntry(
            entity: "children_playing", soundID: "children_playing", eventType: .action,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["children playing", "kids playing", "playground"], "zh": ["嬉笑", "打闹", "玩耍"]]
        ),
    ]

    // MARK: - Vehicles

    static let vehicles: [TriggerEntry] = [
        TriggerEntry(
            entity: "car", soundID: "car", eventType: .vehicle,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["car", "automobile"], "zh": ["汽车", "小汽车"]]
        ),
        TriggerEntry(
            entity: "train", soundID: "train", eventType: .vehicle,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["train"], "zh": ["火车"]]
        ),
        TriggerEntry(
            entity: "airplane", soundID: "airplane", eventType: .vehicle,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["airplane", "plane"], "zh": ["飞机"]]
        ),
        TriggerEntry(
            entity: "helicopter", soundID: "helicopter", eventType: .vehicle,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["helicopter"], "zh": ["直升机"]]
        ),
        TriggerEntry(
            entity: "boat", soundID: "boat", eventType: .vehicle,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["boat"], "zh": ["船"]]
        ),
        TriggerEntry(
            entity: "ship", soundID: "ship_horn", eventType: .vehicle,
            intensity: .strong, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["ship", "foghorn"], "zh": ["轮船", "汽笛"]]
        ),
        TriggerEntry(
            entity: "bus", soundID: "bus", eventType: .vehicle,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["bus"], "zh": ["公交车", "巴士", "大巴"]]
        ),
    ]

    // MARK: - Environments

    static let environments: [TriggerEntry] = [
        TriggerEntry(
            entity: "forest", soundID: "forest_ambience", eventType: .environment,
            intensity: .soft, cooldownSeconds: 30, isAmbience: true,
            keywords: ["en": ["forest", "woods"], "zh": ["森林", "树林"]]
        ),
        TriggerEntry(
            entity: "ocean", soundID: "ocean_waves", eventType: .environment,
            intensity: .soft, cooldownSeconds: 30, isAmbience: true,
            keywords: ["en": ["ocean", "sea", "beach"], "zh": ["海边", "大海"]]
        ),
        TriggerEntry(
            entity: "night", soundID: "night_ambience", eventType: .environment,
            intensity: .soft, cooldownSeconds: 30, isAmbience: true,
            keywords: ["en": ["night", "nighttime", "midnight"], "zh": ["夜晚", "深夜"]]
        ),
        TriggerEntry(
            entity: "farm", soundID: "farm_ambience", eventType: .environment,
            intensity: .soft, cooldownSeconds: 30, isAmbience: true,
            keywords: ["en": ["farm"], "zh": ["农场"]]
        ),
        TriggerEntry(
            entity: "wind_trees", soundID: "wind_trees", eventType: .environment,
            intensity: .soft, cooldownSeconds: 30, isAmbience: true,
            keywords: ["en": ["rustling", "leaves blowing", "trees swaying"], "zh": ["树叶", "沙沙", "风吹树"]]
        ),
    ]
}
