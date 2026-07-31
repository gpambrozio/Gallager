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
        #expect(seeds.count == 26)
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
        let w18 = try #require(seeds.first { $0.id == "W18" })
        #expect(w18.expected == .waiting)
        #expect(w18.message.contains("fix-wave agent is working"))
    }

    @Test func minedURLDefaultPathShape() {
        // The env override itself is untestable here (setenv breaks
        // posix_spawn — see memory); this only pins the default path.
        #expect(StopFinalityDataset.minedURL.path.hasSuffix(".gallager/eval/stop-finality-mined.json"))
    }
}
