import Foundation

enum TriggerLibrary {
    static let defaultTriggers: [TriggerEntry] = animals + weather + actions + vehicles + environments

    static func contextualStrings(for language: ReadingLanguage) -> [String] {
        defaultTriggers.flatMap { $0.keywords[language.rawValue] ?? [] }
    }

    // MARK: - Animals

    static let animals: [TriggerEntry] = [
        TriggerEntry(
            entity: "frog", soundID: "frog_croak", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["frog", "toad"], "zh": ["青蛙", "蟾蜍", "蛤蟆"]]
        ),
        TriggerEntry(
            entity: "dog", soundID: "dog_bark", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["dog", "puppy", "pup"], "zh": ["狗", "小狗", "狗狗", "汪汪"]]
        ),
        TriggerEntry(
            entity: "cat", soundID: "cat_meow", eventType: .animal,
            intensity: .soft, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["cat", "kitten", "kitty"], "zh": ["猫", "小猫", "猫咪", "喵喵"]]
        ),
        TriggerEntry(
            entity: "cow", soundID: "cow_moo", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["cow", "bull", "cattle"], "zh": ["牛", "奶牛", "黄牛", "水牛", "哞"]],
            excludePatterns: ["zh": ["牛奶", "牛仔", "牛皮", "吹牛"]]
        ),
        TriggerEntry(
            entity: "sheep", soundID: "sheep_baa", eventType: .animal,
            intensity: .soft, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["sheep", "lamb", "goat"], "zh": ["羊", "小羊", "绵羊", "山羊", "咩"]]
        ),
        TriggerEntry(
            entity: "lion", soundID: "lion_roar", eventType: .animal,
            intensity: .strong, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["lion"], "zh": ["狮子"]]
        ),
        TriggerEntry(
            entity: "elephant", soundID: "elephant_trumpet", eventType: .animal,
            intensity: .strong, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["elephant"], "zh": ["大象", "小象"]]
        ),
        TriggerEntry(
            entity: "bird", soundID: "bird_chirp", eventType: .animal,
            intensity: .soft, cooldownSeconds: 15, isAmbience: false,
            keywords: [
                "en": ["bird", "birds", "sparrow", "robin", "parrot", "crow", "eagle", "pigeon", "swallow"],
                "zh": ["鸟", "小鸟", "飞鸟", "麻雀", "鹦鹉", "燕子", "乌鸦", "喜鹊", "鸽子", "老鹰", "杜鹃", "百灵鸟"],
            ]
        ),
        TriggerEntry(
            entity: "owl", soundID: "owl_hoot", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["owl"], "zh": ["猫头鹰"]]
        ),
        TriggerEntry(
            entity: "duck", soundID: "duck_quack", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["duck", "duckling"], "zh": ["鸭子", "鸭", "小鸭", "嘎嘎"]]
        ),
        TriggerEntry(
            entity: "chicken", soundID: "chicken_cluck", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["chicken", "rooster", "hen", "chick"], "zh": ["鸡", "公鸡", "母鸡", "小鸡", "咯咯"]]
        ),
        TriggerEntry(
            entity: "horse", soundID: "horse_neigh", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["horse", "pony", "stallion", "mare"], "zh": ["马", "小马", "骏马", "马儿", "马匹"]],
            excludePatterns: ["zh": ["马上", "马路", "马虎", "马克", "马拉松", "罗马", "马来", "奥巴马", "马桶", "司马", "马甲", "马戏", "斑马"]]
        ),
        TriggerEntry(
            entity: "squirrel", soundID: "squirrel_chirp", eventType: .animal,
            intensity: .soft, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["squirrel"], "zh": ["松鼠"]]
        ),
        TriggerEntry(
            entity: "dinosaur", soundID: "dinosaur_roar", eventType: .animal,
            intensity: .strong, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["dinosaur", "t-rex", "raptor", "triceratops"], "zh": ["恐龙", "霸王龙", "三角龙", "翼龙", "剑龙"]]
        ),
        TriggerEntry(
            entity: "whale", soundID: "whale_call", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["whale", "humpback"], "zh": ["鲸鱼", "鲸", "蓝鲸"]]
        ),
        TriggerEntry(
            entity: "tiger", soundID: "tiger_roar", eventType: .animal,
            intensity: .strong, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["tiger"], "zh": ["老虎", "虎"]],
            excludePatterns: ["zh": ["马虎"]]
        ),
        TriggerEntry(
            entity: "monkey", soundID: "monkey_call", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["monkey", "chimp", "chimpanzee", "ape"], "zh": ["猴子", "猴", "猿"]]
        ),
        TriggerEntry(
            entity: "fox", soundID: "fox_bark", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["fox"], "zh": ["狐狸"]]
        ),
        TriggerEntry(
            entity: "zebra", soundID: "zebra_call", eventType: .animal,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["zebra"], "zh": ["斑马"]]
        ),
        TriggerEntry(
            entity: "giraffe", soundID: "giraffe_hum", eventType: .animal,
            intensity: .soft, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["giraffe"], "zh": ["长颈鹿"]]
        ),
        TriggerEntry(
            entity: "mouse", soundID: "mouse_squeak", eventType: .animal,
            intensity: .soft, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["mouse", "mice", "rat"], "zh": ["老鼠", "小老鼠", "耗子", "吱吱"]]
        ),
    ]

    // MARK: - Weather

    static let weather: [TriggerEntry] = [
        TriggerEntry(
            entity: "rain", soundID: "rain_light", eventType: .weather,
            intensity: .soft, cooldownSeconds: 20, isAmbience: true,
            keywords: ["en": ["rain", "raining", "rainy"], "zh": ["下雨", "雨", "雨天"]],
            excludePatterns: ["zh": ["雨伞", "雨衣", "雨鞋", "雨具"]]
        ),
        TriggerEntry(
            entity: "thunder", soundID: "thunder", eventType: .weather,
            intensity: .strong, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["thunder", "thunderstorm"], "zh": ["打雷", "雷声", "雷电"]]
        ),
        TriggerEntry(
            entity: "wind", soundID: "wind", eventType: .weather,
            intensity: .normal, cooldownSeconds: 20, isAmbience: true,
            keywords: ["en": ["wind", "windy", "breeze", "gust"], "zh": ["风", "刮风", "大风", "微风"]],
            excludePatterns: ["zh": ["风格", "风景", "风险", "风味", "风俗", "风趣", "风采", "风度", "作风", "风水", "风筝"]]
        ),
        TriggerEntry(
            entity: "storm", soundID: "storm", eventType: .weather,
            intensity: .strong, cooldownSeconds: 20, isAmbience: true,
            keywords: ["en": ["storm", "stormy"], "zh": ["暴风雨", "暴风"]]
        ),
    ]

    // MARK: - Actions and Objects

    static let actions: [TriggerEntry] = [
        TriggerEntry(
            entity: "knock", soundID: "door_knock", eventType: .action,
            intensity: .normal, cooldownSeconds: 10, isAmbience: false,
            keywords: ["en": ["knock", "knocking"], "zh": ["敲门", "咚咚"]]
        ),
        TriggerEntry(
            entity: "door", soundID: "door_open", eventType: .action,
            intensity: .soft, cooldownSeconds: 10, isAmbience: false,
            keywords: ["en": ["door opened", "open the door", "opened the door"], "zh": ["开门", "门打开了"]]
        ),
        TriggerEntry(
            entity: "footsteps", soundID: "footsteps", eventType: .action,
            intensity: .soft, cooldownSeconds: 10, isAmbience: false,
            keywords: ["en": ["footsteps", "walking", "walked"], "zh": ["走路", "脚步", "脚步声"]]
        ),
        TriggerEntry(
            entity: "running", soundID: "running", eventType: .action,
            intensity: .normal, cooldownSeconds: 10, isAmbience: false,
            keywords: ["en": ["running", "ran "], "zh": ["跑", "跑过来", "奔跑", "跑步"]]
        ),
        TriggerEntry(
            entity: "splash", soundID: "water_splash", eventType: .action,
            intensity: .normal, cooldownSeconds: 10, isAmbience: false,
            keywords: [
                "en": ["splash", "jumped into", "fell into", "pond", "pool"],
                "zh": ["水花", "跳进水里", "跳进", "池塘", "扑通"],
            ]
        ),
        TriggerEntry(
            entity: "bell", soundID: "bell", eventType: .object,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["bell", "ringing"], "zh": ["铃铛", "铃声", "钟声"]]
        ),
        TriggerEntry(
            entity: "clock", soundID: "clock_tick", eventType: .object,
            intensity: .soft, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["clock", "ticking"], "zh": ["时钟", "滴答", "钟表"]]
        ),
        TriggerEntry(
            entity: "laugh", soundID: "laughter", eventType: .action,
            intensity: .normal, cooldownSeconds: 10, isAmbience: false,
            keywords: ["en": ["laugh", "laughing", "laughed", "giggle", "giggling"], "zh": ["笑", "大笑", "哈哈", "嘻嘻", "笑了"]]
        ),
        TriggerEntry(
            entity: "door_slam", soundID: "door_slam", eventType: .action,
            intensity: .strong, cooldownSeconds: 10, isAmbience: false,
            keywords: ["en": ["slammed the door", "door slammed", "slam"], "zh": ["砰", "摔门", "关门", "用力关门"]]
        ),
        TriggerEntry(
            entity: "crying", soundID: "child_crying", eventType: .action,
            intensity: .normal, cooldownSeconds: 10, isAmbience: false,
            keywords: ["en": ["crying", "cried", "sobbing", "tears", "weeping"], "zh": ["哭", "哭泣", "流泪", "呜呜", "大哭"]]
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
            keywords: ["en": ["car", "automobile", "driving"], "zh": ["汽车", "小汽车", "车", "轿车", "开车", "坐车"]],
            excludePatterns: ["zh": ["火车", "列车", "公交车", "校车", "大巴车", "警车", "救护车", "消防车"]]
        ),
        TriggerEntry(
            entity: "train", soundID: "train", eventType: .vehicle,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["train", "locomotive", "railway"], "zh": ["火车", "列车", "小火车"]]
        ),
        TriggerEntry(
            entity: "airplane", soundID: "airplane", eventType: .vehicle,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["airplane", "plane", "jet"], "zh": ["飞机"]]
        ),
        TriggerEntry(
            entity: "helicopter", soundID: "helicopter", eventType: .vehicle,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["helicopter", "chopper"], "zh": ["直升机"]]
        ),
        TriggerEntry(
            entity: "boat", soundID: "boat", eventType: .vehicle,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["boat", "canoe", "rowboat", "sailboat"], "zh": ["船", "小船", "划船"]],
            excludePatterns: ["zh": ["宇宙飞船"]]
        ),
        TriggerEntry(
            entity: "ship", soundID: "ship_horn", eventType: .vehicle,
            intensity: .strong, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["ship", "foghorn"], "zh": ["轮船", "汽笛", "大船"]]
        ),
        TriggerEntry(
            entity: "bus", soundID: "bus", eventType: .vehicle,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["bus", "school bus"], "zh": ["公交车", "巴士", "大巴", "公交", "校车"]]
        ),
        TriggerEntry(
            entity: "subway", soundID: "subway", eventType: .vehicle,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["subway", "metro"], "zh": ["地铁"]]
        ),
        TriggerEntry(
            entity: "tractor", soundID: "tractor", eventType: .vehicle,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["tractor"], "zh": ["拖拉机"]]
        ),
        TriggerEntry(
            entity: "bulldozer", soundID: "bulldozer", eventType: .vehicle,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["bulldozer"], "zh": ["推土机"]]
        ),
        TriggerEntry(
            entity: "harvester", soundID: "harvester", eventType: .vehicle,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["harvester", "combine"], "zh": ["收割机"]]
        ),
        TriggerEntry(
            entity: "drill", soundID: "drill", eventType: .vehicle,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["drill", "drilling", "driller"], "zh": ["电钻", "钻头", "钻机", "钻"]],
            excludePatterns: ["zh": ["钻石", "钻研"]]
        ),
        TriggerEntry(
            entity: "excavator", soundID: "excavator", eventType: .vehicle,
            intensity: .normal, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["excavator", "digger"], "zh": ["挖掘机", "挖土机"]]
        ),
        TriggerEntry(
            entity: "police_car", soundID: "police_siren", eventType: .vehicle,
            intensity: .strong, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["police car", "police"], "zh": ["警车", "警察"]]
        ),
        TriggerEntry(
            entity: "ambulance", soundID: "ambulance_siren", eventType: .vehicle,
            intensity: .strong, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["ambulance"], "zh": ["救护车", "急救车"]]
        ),
        TriggerEntry(
            entity: "fire_truck", soundID: "fire_truck_siren", eventType: .vehicle,
            intensity: .strong, cooldownSeconds: 15, isAmbience: false,
            keywords: ["en": ["fire truck", "fire engine"], "zh": ["消防车", "救火车"]]
        ),
    ]

    // MARK: - Environments

    static let environments: [TriggerEntry] = [
        TriggerEntry(
            entity: "forest", soundID: "forest_ambience", eventType: .environment,
            intensity: .soft, cooldownSeconds: 30, isAmbience: true,
            keywords: ["en": ["forest", "woods", "jungle"], "zh": ["森林", "树林", "丛林"]]
        ),
        TriggerEntry(
            entity: "ocean", soundID: "ocean_waves", eventType: .environment,
            intensity: .soft, cooldownSeconds: 30, isAmbience: true,
            keywords: ["en": ["ocean", "sea", "beach"], "zh": ["海边", "大海", "海洋"]]
        ),
        TriggerEntry(
            entity: "night", soundID: "night_ambience", eventType: .environment,
            intensity: .soft, cooldownSeconds: 30, isAmbience: true,
            keywords: ["en": ["night", "nighttime", "midnight", "evening"], "zh": ["夜晚", "深夜", "晚上", "天黑"]]
        ),
        TriggerEntry(
            entity: "farm", soundID: "farm_ambience", eventType: .environment,
            intensity: .soft, cooldownSeconds: 30, isAmbience: true,
            keywords: ["en": ["farm", "farmyard", "barn"], "zh": ["农场", "牧场", "农庄"]]
        ),
        TriggerEntry(
            entity: "wind_trees", soundID: "wind_trees", eventType: .environment,
            intensity: .soft, cooldownSeconds: 30, isAmbience: true,
            keywords: ["en": ["rustling", "leaves blowing", "trees swaying"], "zh": ["树叶", "沙沙", "风吹树"]]
        ),
    ]
}
