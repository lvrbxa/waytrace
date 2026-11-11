import CoreMotion
import Foundation

// 前の点から今までの歩数と活動の秒数。2秒で返らなければnull
enum Motion {
    private static let pedometer = CMPedometer()
    private static let activity = CMMotionActivityManager()

    static func steps(from: Date, to: Date) async -> Int? {
        guard CMPedometer.isStepCountingAvailable() else { return nil }
        return await withTimeout {
            await withCheckedContinuation { (c: CheckedContinuation<Int?, Never>) in
                pedometer.queryPedometerData(from: from, to: to) { d, _ in c.resume(returning: d?.numberOfSteps.intValue) }
            }
        }
    }

    static func activities(from: Date, to: Date) async -> [Int]? {
        guard CMMotionActivityManager.isActivityAvailable() else { return nil }
        return await withTimeout {
            await withCheckedContinuation { (c: CheckedContinuation<[Int]?, Never>) in
                // 開始より前の活動も要る（区間の初めの種類を知るため）
                activity.queryActivityStarting(from: from.addingTimeInterval(-600), to: to, to: OperationQueue.main) { list, _ in
                    guard let list else { c.resume(returning: nil); return }
                    let items: [(Date, Int)] = list.map { a in
                        let k = a.stationary ? 0 : a.walking ? 1 : a.running ? 2 : a.automotive ? 3 : a.cycling ? 4 : 5
                        return (a.startDate, k)
                    }
                    c.resume(returning: Logic.activitySeconds(items, from: from, to: to))
                }
            }
        }
    }

    private static func withTimeout<T>(_ op: @escaping () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { g in
            g.addTask { await op() }
            g.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
    }
}
