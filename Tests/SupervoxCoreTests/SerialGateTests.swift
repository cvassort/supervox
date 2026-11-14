import Foundation
import Testing
@testable import SupervoxCore

private actor Probe {
    private(set) var active = 0
    private(set) var maxActive = 0
    private(set) var finished = 0
    func begin() { active += 1; maxActive = max(maxActive, active) }
    func end() { active -= 1; finished += 1 }
}

@Suite struct SerialGateTests {
    /// 30 tâches entrent dans la porte et se suspendent plusieurs fois à l'intérieur : sans la porte, elles se
    /// chevauchent (c'est ce que fait un acteur réentrant). Avec elle, jamais deux à la fois, et toutes finissent.
    @Test func neverLetsTwoTasksInsideAtOnce() async {
        let gate = SerialGate()
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 {
                group.addTask {
                    await gate.enter()
                    await probe.begin()
                    for _ in 0..<5 { await Task.yield() }
                    await probe.end()
                    gate.leave()
                }
            }
        }
        #expect(await probe.maxActive == 1)
        #expect(await probe.finished == 30)
        #expect(await probe.active == 0)
    }

    /// Une porte libre laisse passer sans attendre, et se rouvre après chaque sortie.
    @Test func reopensAfterEveryLeave() async {
        let gate = SerialGate()
        for _ in 0..<3 {
            await gate.enter()
            gate.leave()
        }
        await gate.enter()
        gate.leave()
    }

    /// Les tâches en attente passent dans l'ordre où elles sont arrivées à la porte.
    @Test func waitingTasksGoInArrivalOrder() async {
        let gate = SerialGate()
        let order = OrderLog()
        await gate.enter()
        var tasks: [Task<Void, Never>] = []
        for index in 0..<5 {
            tasks.append(Task {
                await gate.enter()
                await order.add(index)
                gate.leave()
            })
            // Laisse la tâche atteindre la porte avant de lancer la suivante : l'ordre d'arrivée est alors connu.
            // Borné : une porte cassée ne doit pas figer le test.
            var spins = 0
            while gate.waitingCount < index + 1 && spins < 50_000 { await Task.yield(); spins += 1 }
        }
        gate.leave()
        for task in tasks { await task.value }
        #expect(await order.values == [0, 1, 2, 3, 4])
    }
}

private actor OrderLog {
    private(set) var values: [Int] = []
    func add(_ value: Int) { values.append(value) }
}
