import AppKit

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + name)
    if !ok { failures += 1 }
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hub-services-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let a = dir.appendingPathComponent("a.png")
let b = dir.appendingPathComponent("b c.pdf")
FileManager.default.createFile(atPath: a.path, contents: Data([1]))
FileManager.default.createFile(atPath: b.path, contents: Data([2]))

var received: [([URL], FilesWheelMode)] = []
let services = FilesServices { urls, mode in received.append((urls, mode)) }
let board = NSPasteboard.withUniqueName()
board.clearContents()
board.writeObjects([a as NSURL, b as NSURL])

var error: NSString?
services.convertFiles(board, userData: nil, error: &error)
services.fileTools(board, userData: nil, error: &error)
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
check("convert service delivers both files in order", received.first?.0.map(\.lastPathComponent) == ["a.png", "b c.pdf"])
check("convert service opens the convert wheel", received.first?.1 == .convert)
check("tools service opens the tools wheel", received.last?.1 == .tools)
check("no error for a valid file pasteboard", error == nil)

let empty = NSPasteboard.withUniqueName()
empty.clearContents()
empty.setString("https://example.com", forType: .string)
received = []
services.convertFiles(empty, userData: nil, error: &error)
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
check("a pasteboard without files reports an error and invokes nothing", received.isEmpty && error != nil)

let remote = NSPasteboard.withUniqueName()
remote.clearContents()
remote.writeObjects([URL(string: "https://example.com/x.png")! as NSURL])
check("remote URLs are never treated as files", FilesServices.fileURLs(from: remote).isEmpty)

let plist = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let info = NSDictionary(contentsOfFile: plist) as? [String: Any] ?? [:]
let entries = info["NSServices"] as? [[String: Any]] ?? []
let messages = Set(entries.compactMap { $0["NSMessage"] as? String })
check("Info.plist declares both services", messages == ["convertFiles", "fileTools"])
check("every declared message exists on the provider", messages.allSatisfy { services.responds(to: NSSelectorFromString($0 + ":userData:error:")) })
check("services accept any file item", entries.allSatisfy { ($0["NSSendFileTypes"] as? [String]) == ["public.item"] })

try? FileManager.default.removeItem(at: dir)
print(failures == 0 ? "ALL GREEN" : "\(failures) falhas")
exit(failures == 0 ? 0 : 1)
