import Foundation
import Testing
@testable import SupervoxCore

/// Le stub doit servir à chaque client sa propre réponse et ne lui montrer que ses propres requêtes, même quand
/// des dizaines de clients travaillent en même temps (ce que font des suites de tests différentes). Si ce test
/// échoue, les autres suites qui s'appuient sur le stub ne prouvent plus rien.
@Suite("StubIsolationTests", .serialized)
struct StubIsolationTests {
    @Test func concurrentClientsEachGetTheirOwnReplyAndTheirOwnRequest() async throws {
        let count = 40
        let clients = (0..<count).map { i in
            stubbedClient(status: 200, body: "{\"text\":\"reponse-\(i)\"}", baseURL: "https://hote-\(i).test", apiKey: "cle-\(i)")
        }
        // Plusieurs tours par client : un état partagé se trahirait par une réponse ou une requête d'un autre client.
        let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (i, client) in clients.enumerated() {
                group.addTask {
                    var last = ""
                    for _ in 0..<5 { last = try await client.transcribe(wav: Data([UInt8(i)]), model: "m\(i)", language: nil, prompt: nil) }
                    return (i, last)
                }
            }
            var all: [Int: String] = [:]
            for try await (i, text) in group { all[i] = text }
            return all
        }
        for (i, client) in clients.enumerated() {
            #expect(results[i] == "reponse-\(i)")
            let request = try #require(StubURLProtocol.lastRequest(of: client))
            #expect(request.url?.host == "hote-\(i).test")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cle-\(i)")
            #expect(StubURLProtocol.requestCount(of: client) == 5)
            #expect(StubURLProtocol.lastBody(of: client).range(of: Data("m\(i)".utf8)) != nil)
        }
    }

    @Test func aClientNeverSeesTheRequestsOfAnother() async throws {
        let a = stubbedClient(status: 200, body: "{\"text\":\"a\"}")
        let b = stubbedClient(status: 200, body: "{\"text\":\"b\"}")
        _ = try await a.transcribe(wav: Data([1]), model: "m", language: nil, prompt: nil)
        #expect(StubURLProtocol.requestCount(of: a) == 1)
        #expect(StubURLProtocol.requestCount(of: b) == 0)
        #expect(StubURLProtocol.lastRequest(of: b) == nil)
    }
}
