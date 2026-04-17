import Foundation
import Testing
@testable import ClaudeSpyNetworking

@Test
func requestEncodesToJSON() throws {
    let request = JSONRPCRequest(
        id: "test-1",
        method: "session.list",
        params: [:]
    )
    let data = try JSONEncoder().encode(request)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["id"] as? String == "test-1")
    #expect(json["method"] as? String == "session.list")
    #expect(json["params"] is [String: Any])
}

@Test
func successResponseDecodable() throws {
    let json = Data("""
    {"id":"test-1","ok":true,"result":{"pong":true}}
    """.utf8)
    let response = try JSONDecoder().decode(JSONRPCResponse.self, from: json)
    #expect(response.id == "test-1")
    #expect(response.ok == true)
    #expect(response.error == nil)
}

@Test
func errorResponseDecodable() throws {
    let json = Data("""
    {"id":"test-2","ok":false,"error":{"code":"not_found","message":"Session not found"}}
    """.utf8)
    let response = try JSONDecoder().decode(JSONRPCResponse.self, from: json)
    #expect(response.id == "test-2")
    #expect(response.ok == false)
    #expect(response.error?.code == "not_found")
    #expect(response.error?.message == "Session not found")
}

@Test
func requestWithTypedParams() throws {
    let params: [String: JSONValue] = [
        "session_id": .string("my-session"),
        "name": .string("test"),
    ]
    let request = JSONRPCRequest(id: "test-3", method: "session.create", params: params)
    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
    #expect(decoded.params["session_id"] == .string("my-session"))
}
