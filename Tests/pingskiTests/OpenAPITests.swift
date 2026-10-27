import XCTest
@testable import pingski

final class OpenAPITests: XCTestCase {
    func testEmbeddedSpecIsValidJSONAndMatchesFile() throws {
        let embedded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(OpenAPISpec.json.utf8)) as? [String: Any])
        XCTAssertEqual(embedded["openapi"] as? String, "3.0.3")
        let info = try XCTUnwrap(embedded["info"] as? [String: Any])
        XCTAssertEqual(info["version"] as? String, pingskiVersion, "bump openapi/openapi.json info.version with Version.swift")

        let fileURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("openapi/openapi.json")
        if let onDisk = try? Data(contentsOf: fileURL) {
            let a = try JSONSerialization.jsonObject(with: onDisk) as? NSDictionary
            XCTAssertEqual(a, embedded as NSDictionary, "run scripts/embed-openapi.sh after editing openapi/openapi.json")
        }
    }

    func testEveryRouteIsDocumented() throws {
        let spec = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(OpenAPISpec.json.utf8)) as? [String: Any])
        let paths = try XCTUnwrap(spec["paths"] as? [String: [String: Any]])
        for route in Router.routes {
            let item = try XCTUnwrap(paths[route.path], "missing path \(route.path) in openapi.json")
            XCTAssertNotNil(item[route.method.lowercased()], "missing \(route.method) \(route.path) in openapi.json")
        }
        for (path, item) in paths {
            for method in item.keys where !["parameters", "summary", "description"].contains(method) {
                XCTAssertTrue(Router.routes.contains { $0.path == path && $0.method.lowercased() == method }, "spec documents \(method.uppercased()) \(path) but the router has no such route")
            }
        }
    }
}
