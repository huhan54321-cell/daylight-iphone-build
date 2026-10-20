#if DEBUG && targetEnvironment(simulator)
import Foundation

enum CareerMobileFixtures {
    static func make(_ original: CareerAssistantJSON) throws -> CareerAssistantJSON {
        var value = original.dictionary
        let formatter = ISO8601DateFormatter()
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(15 * 3600)
        let job = try CareerAssistantJSON.from(["id":"ui-mobile-job", "title":"UI 机器人实习", "company":"UI 测试团队", "city":"杭州", "sourceName":"合成测试资料", "sourceID":"official", "url":"https://example.com/jobs/mobile", "checkedAt":formatter.string(from: Date()), "status":"unconfirmed", "description":"仅用于隔离的模拟器交互测试。", "followUp":["saved":false,"stage":"面试","interview":["start":formatter.string(from:start),"end":formatter.string(from:start.addingTimeInterval(3600)),"location":"线上","notes":"合成面试"]]])
        value["jobs"] = .array([job] + original["jobs"].array)
        let lead = try CareerAssistantJSON.from(["id":"aaaaaaaaaaaaaaaaaaaaaaaa","title":"UI 招聘线索报告原帖","url":"https://www.xiaohongshu.com/explore/aaaaaaaaaaaaaaaaaaaaaaaa","reason":"合成招聘线索，未经真实平台验证","category":"hiring","saved":false,"read":false])
        value["leads"] = .array([lead])
        value["reports"] = .array([.object(["id":.string("ui-mobile-report"),"title":.string("UI 缓存招聘线索报告"),"message":.string("实际检索未执行；仅供交互测试"),"leads":.array([lead]),"priority":.array([lead])])])
        value["applications"] = .array([try .from(["id":"ui-mobile-review","jobID":"ui-mobile-job","company":"UI 测试团队","jobTitle":"UI 机器人实习","state":"draft","materialTitle":"UI 材料","materialContent":"合成真实资料确认场景","materialVersion":1,"reviewHash":"ui-review-hash","action":"submit","fields":[String:String]()])])
        return .object(value)
    }
}
#endif
