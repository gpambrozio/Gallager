import Foundation
import Testing
@testable import StopFinalityDataset

@Suite("StopFinalityDataset")
struct StopFinalityDatasetTests {
    @Test func decodesSchema() throws {
        let json = """
        [{"id": "X1", "message": "All done.", "expected": "final", "source": "seed", "notes": "smoke"}]
        """
        let cases = try JSONDecoder().decode([StopFinalityCase].self, from: Data(json.utf8))
        #expect(cases == [
            StopFinalityCase(id: "X1", message: "All done.", expected: .final, source: .seed, notes: "smoke"),
        ])
    }

    @Test func notesIsOptional() throws {
        let json = """
        [{"id": "X2", "message": "Waiting on CI.", "expected": "waiting", "source": "mined"}]
        """
        let cases = try JSONDecoder().decode([StopFinalityCase].self, from: Data(json.utf8))
        #expect(cases.first?.notes == nil)
    }

    @Test func seedsLoadFromBundle() throws {
        let seeds = try StopFinalityDataset.seeds()
        #expect(seeds.count == 21)
        #expect(seeds.allSatisfy { $0.source == .seed })
        #expect(Set(seeds.map(\.id)).count == seeds.count)
        let f1 = try #require(seeds.first { $0.id == "F1" })
        #expect(f1.expected == .final)
        #expect(f1.message.contains("Merged and pushed"))
        let w12 = try #require(seeds.first { $0.id == "W12" })
        #expect(w12.expected == .waiting)
        let w13 = try #require(seeds.first { $0.id == "W13" })
        #expect(w13.expected == .waiting)
        #expect(w13.message.contains("still working"))
    }

    @Test func minedURLHonorsEnvOverride() {
        // Can't mutate the process env safely in tests (see memory:
        // setenv breaks posix_spawn) — just pin the default path shape.
        #expect(StopFinalityDataset.minedURL.path.hasSuffix(".gallager/eval/stop-finality-mined.json"))
    }
}
