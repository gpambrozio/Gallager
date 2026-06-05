#if os(macOS)
    import Testing
    @testable import ClaudeSpyServerFeature

    @Test
    func expandsBracedVariable() {
        let expander = LayoutVariableExpander(environment: ["FOO": "bar"])
        var undefined: [LayoutVariableExpander.UndefinedReference] = []
        let result = expander.expand("hello ${FOO}", undefined: &undefined)
        #expect(result == "hello bar")
        #expect(undefined.isEmpty)
    }

    @Test
    func expandsBareVariable() {
        let expander = LayoutVariableExpander(environment: ["USER": "alice"])
        var undefined: [LayoutVariableExpander.UndefinedReference] = []
        let result = expander.expand("hi $USER!", undefined: &undefined)
        #expect(result == "hi alice!")
    }

    @Test
    func bracedDefaultUsedWhenMissing() {
        let expander = LayoutVariableExpander(environment: [:])
        var undefined: [LayoutVariableExpander.UndefinedReference] = []
        let result = expander.expand("branch=${BRANCH:-main}", undefined: &undefined)
        #expect(result == "branch=main")
        // Defaulted vars are not warnings — the user told us what to fall back to.
        #expect(undefined.isEmpty)
    }

    @Test
    func emptyVariableUsesDefault() {
        // Mirrors POSIX `${X:-default}` which fires the default when the value is unset *or* empty.
        let expander = LayoutVariableExpander(environment: ["BRANCH": ""])
        var undefined: [LayoutVariableExpander.UndefinedReference] = []
        let result = expander.expand("${BRANCH:-main}", undefined: &undefined)
        #expect(result == "main")
    }

    @Test
    func recordsUndefinedVariables() {
        let expander = LayoutVariableExpander(environment: [:])
        var undefined: [LayoutVariableExpander.UndefinedReference] = []
        let result = expander.expand("hello ${MISSING}!", undefined: &undefined)
        #expect(result == "hello !")
        #expect(undefined == [LayoutVariableExpander.UndefinedReference(name: "MISSING")])
    }

    @Test
    func backslashEscapesDollar() {
        let expander = LayoutVariableExpander(environment: ["FOO": "bar"])
        var undefined: [LayoutVariableExpander.UndefinedReference] = []
        let result = expander.expand("\\$FOO and ${FOO}", undefined: &undefined)
        #expect(result == "$FOO and bar")
    }

    @Test
    func bareDollarStaysLiteralAtEndOrBeforeNonName() {
        let expander = LayoutVariableExpander(environment: [:])
        var undefined: [LayoutVariableExpander.UndefinedReference] = []
        let result = expander.expand("price: $", undefined: &undefined)
        #expect(result == "price: $")
        #expect(undefined.isEmpty)
    }

    @Test
    func unterminatedBraceLeavesLiteral() {
        let expander = LayoutVariableExpander(environment: ["FOO": "bar"])
        var undefined: [LayoutVariableExpander.UndefinedReference] = []
        let result = expander.expand("hello ${FOO", undefined: &undefined)
        #expect(result == "hello ${FOO")
    }

    @Test
    func multipleVariablesInOneString() {
        let expander = LayoutVariableExpander(
            environment: ["A": "1", "B": "2", "C": "3"]
        )
        var undefined: [LayoutVariableExpander.UndefinedReference] = []
        let result = expander.expand("$A-${B}-$C", undefined: &undefined)
        #expect(result == "1-2-3")
    }

    @Test
    func definedButEmptyVariableExpandsToEmpty() {
        // Bare `${VAR}` (no `:-default`) treats an empty value as defined,
        // matching POSIX `${VAR}` semantics. Distinct from `${VAR:-default}`,
        // which fires the default for both unset and empty.
        let expander = LayoutVariableExpander(environment: ["EMPTY": ""])
        var undefined: [LayoutVariableExpander.UndefinedReference] = []
        let result = expander.expand("[${EMPTY}]", undefined: &undefined)
        #expect(result == "[]")
        #expect(undefined.isEmpty)
    }

    @Test
    func bareDollarVarWithEmptyValueExpandsToEmpty() {
        // The `$VAR` (unbraced) form has always honored empty-as-defined; this
        // pins the behavior so it stays consistent with the braced form.
        let expander = LayoutVariableExpander(environment: ["EMPTY": ""])
        var undefined: [LayoutVariableExpander.UndefinedReference] = []
        let result = expander.expand("[$EMPTY]", undefined: &undefined)
        #expect(result == "[]")
        #expect(undefined.isEmpty)
    }
#endif
