import Foundation
import ReachyIntrospection
import ReachyJSON

// Drives a running Debug build through its introspection tree.
//
// An executable and not a `Scripts/*.swift` for the reason `ReachyGeometryExport`
// gives: a script cannot link a target, and the request and response types must
// be the ones the app uses.
//
// A Debug build of its own, too. `ReachyIntrospection` is empty in Release, so that
// a Release app that links ReachyUI carries no part of it.

#if DEBUG

    let usage = """
    usage: introspect [--port <port>] ls
           introspect [--port <port>] do <action> [<json object>]

    The port is 8765 unless --port or REACHY_INTROSPECT_PORT names another.
    The answer is one line of JSON on stdout. The exit status is 1 on a refusal.
    """

    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }

    var arguments = Array(CommandLine.arguments.dropFirst())
    var port = ProcessInfo.processInfo.environment["REACHY_INTROSPECT_PORT"].flatMap(UInt16.init) ?? 8765
    if arguments.first == "--port" {
        guard arguments.count >= 2, let named = UInt16(arguments[1]) else { fail(usage) }
        port = named
        arguments.removeFirst(2)
    }

    let request: IntrospectionRequest
    switch arguments.first {
    case "ls" where arguments.count == 1:
        request = IntrospectionRequest(cmd: .list)
    case "do" where arguments.count == 2 || arguments.count == 3:
        var input: JSONValue?
        if arguments.count == 3 {
            do {
                input = try JSONCodec.web.decode(JSONValue.self, from: Data(arguments[2].utf8))
            } catch {
                fail("the input is not JSON: \(arguments[2])")
            }
        }
        request = IntrospectionRequest(cmd: .perform, action: arguments[1], input: input)
    default:
        fail(usage)
    }

    do {
        let response = try await IntrospectionClient(port: port).send(request)
        let line = try JSONCodec.web.encode(response)
        FileHandle.standardOutput.write(line + Data("\n".utf8))
        exit(response.ok ? 0 : 1)
    } catch {
        fail(String(describing: error))
    }
#else
    FileHandle.standardError.write(Data("introspect is a Debug tool: build it without -c release.\n".utf8))
    exit(2)
#endif
