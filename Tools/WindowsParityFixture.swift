import Foundation

/// Synthetic cross-platform scheduling oracle; never reads a personal library or opens QQ.
@main struct WindowsParityFixture {
    static func main() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let recipients = [Recipient(id:"A",name:"验收群A"),Recipient(id:"B",name:"验收群B")]
        var plan = Plan(id:"P",name:"隔离验收",text:"完整正文",assetIDs:[],recipientIDs:["A","B"],starts:now.addingTimeInterval(300),days:1,times:[],intervalMinutes:30,mode:"automatic")
        var cases: [[String:Any]] = []
        for (label, days, times, offset, jitter) in [("single",1,[String](),0.0,false),("multi-day",3,[String](),0.0,false),("multi-round",2,["09:00","14:00","19:00"],0.0,false),("shifted",2,[String](),3600.0,false),("jitter",2,[String](),0.0,true)] {
            plan.days=days;plan.times=times;plan.scheduleOffsetSeconds=offset
            // Round samples start at the next midnight, ensuring every slot is in the future.
            plan.starts=times.isEmpty ? now.addingTimeInterval(300) : Scheduling.calendar.startOfDay(for:now).addingTimeInterval(86400)
            let jobs=try Scheduling.expand(plan,recipients:recipients,assets:[],now:now,jitter:jitter)
            cases.append(["label":label,"starts":plan.starts.timeIntervalSinceReferenceDate,"days":days,"times":times,"offset":offset,"jitter":jitter,"scheduled":jobs.map{$0.scheduled.timeIntervalSinceReferenceDate},"recipients":jobs.map(\.recipient)])
        }
        let seeds=(0..<100).map { index -> [String:Any] in let text="seed\(index)";return ["text":text,"value":Scheduling.jittered(minutes:30,seed:Scheduling.stableSeed(text))] }
        let result:[String:Any]=["clock":now.timeIntervalSinceReferenceDate,"cases":cases,"jitterSeeds":seeds]
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]),as:UTF8.self))
    }
}
