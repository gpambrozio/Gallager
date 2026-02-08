import Foundation

/// Result builder for declaring test scenarios declaratively
@resultBuilder
public struct ScenarioBuilder {
    public static func buildBlock(_ steps: TestStep...) -> [TestStep] {
        steps
    }

    public static func buildBlock(_ steps: [TestStep]...) -> [TestStep] {
        steps.flatMap { $0 }
    }

    public static func buildOptional(_ steps: [TestStep]?) -> [TestStep] {
        steps ?? []
    }

    public static func buildEither(first steps: [TestStep]) -> [TestStep] {
        steps
    }

    public static func buildEither(second steps: [TestStep]) -> [TestStep] {
        steps
    }

    public static func buildArray(_ components: [[TestStep]]) -> [TestStep] {
        components.flatMap { $0 }
    }

    public static func buildExpression(_ step: TestStep) -> [TestStep] {
        [step]
    }
}

// MARK: - Convenience factory

public func scenario(
    _ name: String,
    tags: [String] = [],
    @ScenarioBuilder steps: () -> [TestStep]
) -> TestScenario {
    TestScenario(name: name, tags: tags, steps: steps())
}
