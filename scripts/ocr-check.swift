// Reads the text in PNG files with the macOS Vision framework and checks it for real data.
//
// Usage: swift scripts/ocr-check.swift [--expect TEXT]... [--deny REGEX]... [--allow-domain DOMAIN]... FILE.png...
//
// - Prints all text found in each file.
// - Fails when a line has an email whose domain is not example.com (or an --allow-domain).
// - Fails when a line matches a --deny pattern. Keep private words out of the repo: pass them here.
// - Fails when an --expect text is not found in any file (proves that OCR reads the images).
import Foundation
import Vision
import AppKit

var expects: [String] = [], denies: [String] = [], domains = ["example.com"], files: [String] = []
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--expect", "--deny", "--allow-domain":
        guard !args.isEmpty else { FileHandle.standardError.write("\(a) needs a value\n".data(using: .utf8)!); exit(2) }
        let v = args.removeFirst()
        if a == "--expect" { expects.append(v) } else if a == "--deny" { denies.append(v) } else { domains.append(v.lowercased()) }
    default: files.append(a)
    }
}
guard !files.isEmpty else { print("Usage: ocr-check [--expect TEXT] [--deny REGEX] [--allow-domain D] FILE.png..."); exit(2) }

func readText(_ path: String) -> [String] {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: cg).perform([req])
    return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

let emailRE = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+)")
func badEmails(_ line: String) -> [String] {
    emailRE.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { m in
        let domain = String(line[Range(m.range(at: 1), in: line)!]).lowercased()
        return domains.contains(domain) ? nil : String(line[Range(m.range, in: line)!])
    }
}
let denyREs = denies.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

var problems = 0
var allText = ""
for f in files {
    print("== \(f)")
    let lines = readText(f)
    if lines.isEmpty { print("ERROR: no text found"); problems += 1 }
    for line in lines {
        print("   \(line)")
        allText += line + "\n"
        for e in badEmails(line) { print("   ^ NOT A DEMO EMAIL: \(e)"); problems += 1 }
        if denyREs.contains(where: { $0.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }) {
            print("   ^ DENIED"); problems += 1
        }
    }
}
for e in expects where !allText.localizedCaseInsensitiveContains(e) {
    print("EXPECTED TEXT NOT FOUND: \(e)"); problems += 1
}
print(problems == 0 ? "OCR check passed: \(files.count) files, no real data." : "OCR check FAILED: \(problems) problems.")
exit(problems == 0 ? 0 : 1)
