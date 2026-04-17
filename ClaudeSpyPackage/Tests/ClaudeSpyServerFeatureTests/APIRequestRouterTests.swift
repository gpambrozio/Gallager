import ClaudeSpyNetworking
import Testing
@testable import ClaudeSpyServerFeature

@Test
func pingReturns() async {
    let router = LiveAPIRequestRouter()
    let request = JSONRPCRequest(id: "1", method: "system.ping", params: [:])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    #expect(response.result?["pong"]?.boolValue == true)
}

@Test
func unknownMethodReturnsError() async {
    let router = LiveAPIRequestRouter()
    let request = JSONRPCRequest(id: "2", method: "nonexistent.method", params: [:])
    let response = await router.handleRequest(request)
    #expect(response.ok == false)
    #expect(response.error?.code == "method_not_found")
}

@Test
func capabilitiesListsMethods() async {
    let router = LiveAPIRequestRouter()
    let request = JSONRPCRequest(id: "3", method: "system.capabilities", params: [:])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    if case let .array(methods) = response.result?["methods"] {
        let names = methods.compactMap(\.stringValue)
        #expect(names.contains("system.ping"))
        #expect(names.contains("session.list"))
        #expect(names.contains("input.send_text"))
    } else {
        Issue.record("Expected methods array")
    }
}
