import Foundation
import DoxiCore
let path = CommandLine.arguments[1]
let text = try! String(contentsOfFile: path)
for f in DeterministicExtractor().extract(DocumentText(plainText: text)) {
    print(f.kind.rawValue, "|", f.displayValue, "|", f.ruleStrength?.rawValue ?? "", "|", f.source?.pageLabel ?? "", "|", (f.source?.quote ?? "").prefix(90).replacingOccurrences(of: "\n", with: "⏎"))
}
