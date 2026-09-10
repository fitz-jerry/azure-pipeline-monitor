import Cocoa

// MARK: - Run reference

final class RunRef: NSObject {
    let project: String
    let definitionID: Int
    let pipelineName: String
    let lastBranch: String?
    init(project: String, definitionID: Int, pipelineName: String, lastBranch: String?) {
        self.project = project
        self.definitionID = definitionID
        self.pipelineName = pipelineName
        self.lastBranch = lastBranch
    }
}

/// Turns a branch name into the ref the Pipelines API expects.
func fullRefName(_ branch: String) -> String {
    branch.hasPrefix("refs/") ? branch : "refs/heads/\(branch)"
}

// MARK: - Pipeline parameters

/// One entry from a YAML pipeline's root `parameters:` block.
struct PipelineParameter {
    let name: String
    let displayName: String
    let type: String        // string | number | boolean | object | …
    let values: [String]    // non-empty ⇒ a pick list
    let defaultValue: Any?  // nil ⇒ the parameter is required

    var label: String { displayName.isEmpty ? name : displayName }
    var isRequired: Bool { defaultValue == nil }
}

struct PipelineParameterSet {
    var parameters: [PipelineParameter] = []
    /// Values from the most recent run; they win over declared defaults.
    var current: [String: Any] = [:]
    /// Set when the parameters are stale or could not be read at all.
    var note: String?
}

/// Just enough YAML to read the root `parameters:` block out of the expanded
/// YAML Azure DevOps returns. Not a general parser — it covers the block style
/// ADO emits: space indents, single-quoted scalars, block sequences and
/// mappings, and `[]` / `{}` empties.
enum MiniYAML {
    private struct Line {
        var indent: Int
        var text: String
    }

    static func parameters(fromExpandedYAML yaml: String) -> [PipelineParameter] {
        var lines: [Line] = []
        for raw in yaml.components(separatedBy: .newlines) {
            let body = raw.drop(while: { $0 == " " })
            if body.isEmpty || body.first == "#" { continue }
            lines.append(Line(indent: raw.count - body.count, text: String(body)))
        }
        guard let start = lines.firstIndex(where: { $0.indent == 0 && $0.text == "parameters:" })
        else { return [] }

        // The block ends at the next top-level key (`variables:`, `stages:`, …).
        var block: [Line] = []
        var scan = start + 1
        while scan < lines.count {
            let line = lines[scan]
            if line.indent == 0 && !line.text.hasPrefix("-") { break }
            block.append(line)
            scan += 1
        }

        var index = 0
        return parseSequence(&block, &index, indent: 0).compactMap { item in
            guard let map = item as? [String: Any], let name = map["name"] as? String else { return nil }
            return PipelineParameter(
                name: name,
                displayName: (map["displayName"] as? String) ?? "",
                type: (map["type"] as? String) ?? "string",
                values: (map["values"] as? [Any])?.map { displayText(for: $0) } ?? [],
                defaultValue: map["default"])
        }
    }

    private static func parseSequence(_ lines: inout [Line], _ i: inout Int, indent: Int) -> [Any] {
        var items: [Any] = []
        while i < lines.count, lines[i].indent == indent, lines[i].text.hasPrefix("-") {
            let after = lines[i].text.dropFirst().drop(while: { $0 == " " })
            if after.isEmpty {
                i += 1
                items.append(parseNode(&lines, &i, parentIndent: indent))
                continue
            }
            // Re-read the item's first key as if it sat on its own indented line.
            lines[i] = Line(indent: indent + 2, text: String(after))
            if keyColon(String(after)) != nil {
                items.append(parseMapping(&lines, &i, indent: indent + 2))
            } else {
                items.append(scalar(String(after)))
                i += 1
            }
        }
        return items
    }

    private static func parseMapping(_ lines: inout [Line], _ i: inout Int, indent: Int) -> [String: Any] {
        var map: [String: Any] = [:]
        while i < lines.count, lines[i].indent == indent, !lines[i].text.hasPrefix("-") {
            let text = lines[i].text
            guard let colon = keyColon(text) else { break }
            let key = String(text[..<colon])
            let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            i += 1
            map[key] = rest.isEmpty ? parseNode(&lines, &i, parentIndent: indent) : scalar(rest)
        }
        return map
    }

    private static func parseNode(_ lines: inout [Line], _ i: inout Int, parentIndent: Int) -> Any {
        guard i < lines.count else { return "" }
        let line = lines[i]
        // A block sequence may sit at the same indent as the key that owns it.
        if line.text.hasPrefix("-"), line.indent >= parentIndent {
            return parseSequence(&lines, &i, indent: line.indent)
        }
        if line.indent > parentIndent {
            return parseMapping(&lines, &i, indent: line.indent)
        }
        return ""
    }

    /// Index of the ":" that ends a mapping key, or nil if the line isn't one.
    private static func keyColon(_ s: String) -> String.Index? {
        if s.first == "'" || s.first == "\"" { return nil }
        var idx = s.startIndex
        while idx < s.endIndex {
            if s[idx] == ":" {
                let next = s.index(after: idx)
                if next == s.endIndex || s[next] == " " { return idx }
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    private static func scalar(_ raw: String) -> Any {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            return String(s.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if s == "[]" { return [Any]() }
        if s == "{}" { return [String: Any]() }
        if s == "true" || s == "True" { return true }
        if s == "false" || s == "False" { return false }
        if let i = Int(s) { return i }
        if let d = Double(s) { return d }
        return s
    }

    /// Renders a parsed value for a text field: JSON for containers, plain text otherwise.
    static func displayText(for value: Any?) -> String {
        switch value {
        case nil: return ""
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return n.stringValue
        default:
            guard let value, JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(
                      withJSONObject: value,
                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: data, encoding: .utf8)
            else { return String(describing: value ?? "") }
            return text
        }
    }

    static func boolValue(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["true", "yes", "1", "on"].contains(s.lowercased())
        default: return false
        }
    }
}

// MARK: - Loading parameters from Azure DevOps

/// Reads a YAML pipeline's parameters. Azure DevOps has no "list parameters"
/// endpoint, so this previews the pipeline (a dry run that queues nothing) and
/// reads the `parameters:` block out of the expanded YAML it returns. The
/// preview refuses to run unless every required parameter has a value, so it is
/// seeded with the values from the most recent run.
final class PipelineParameterLoader {
    private let organization: String
    private let project: String
    private let definitionID: Int
    private let pat: String

    init(organization: String, project: String, definitionID: Int, pat: String) {
        self.organization = organization
        self.project = project
        self.definitionID = definitionID
        self.pat = pat
    }

    func load(branch: String?, completion: @escaping (PipelineParameterSet) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.loadSynchronously(branch: branch)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func loadSynchronously(branch: String?) -> PipelineParameterSet {
        var set = PipelineParameterSet()

        // Recent runs supply both the preview seed and a fallback copy of the
        // expanded YAML. Runs come back newest first.
        var seed: [String: Any] = [:]
        var expandedYamlURL: URL?
        if let listed = json(fetch(api("pipelines/\(definitionID)/runs"))),
           let runs = listed["value"] as? [[String: Any]] {
            for run in runs.prefix(3) {
                guard let id = run["id"] as? Int,
                      let detail = json(fetch(api("pipelines/\(definitionID)/runs/\(id)")))
                else { continue }
                if seed.isEmpty, let used = detail["templateParameters"] as? [String: Any], !used.isEmpty {
                    seed = used
                }
                if expandedYamlURL == nil,
                   let yaml = detail["yamlDetails"] as? [String: Any],
                   let link = yaml["expandedYamlUrl"] as? String,
                   let url = URL(string: link) {
                    expandedYamlURL = url
                }
                if !seed.isEmpty && expandedYamlURL != nil { break }
            }
        }
        set.current = seed

        var body: [String: Any] = ["previewRun": true]
        if !seed.isEmpty { body["templateParameters"] = seed }
        if let branch, !branch.isEmpty {
            body["resources"] = ["repositories": ["self": ["refName": fullRefName(branch)]]]
        }
        let preview = fetch(api("pipelines/\(definitionID)/preview"), method: "POST", body: body)
        if preview.status == 200,
           let object = json(preview),
           let yaml = object["finalYaml"] as? String {
            set.parameters = MiniYAML.parameters(fromExpandedYAML: yaml)
            return set
        }

        let reason = (json(preview)?["message"] as? String) ?? "HTTP \(preview.status)"

        // The preview can fail for reasons unrelated to parameters (an
        // unauthorized environment, say). The last run's expanded YAML still
        // describes the parameters, just as of whenever that run happened.
        if let url = expandedYamlURL {
            let expanded = fetch(url)
            if expanded.status == 200, let data = expanded.data,
               let yaml = String(data: data, encoding: .utf8) {
                let parsed = MiniYAML.parameters(fromExpandedYAML: yaml)
                if !parsed.isEmpty {
                    set.parameters = parsed
                    set.note = "Showing the parameters from the last run — this branch could not be "
                        + "previewed: \(reason)"
                    return set
                }
            }
        }

        if !seed.isEmpty {
            set.parameters = seed.keys.sorted().map {
                PipelineParameter(name: $0, displayName: "", type: "string",
                                  values: [], defaultValue: seed[$0])
            }
            set.note = "Showing the values the last run used — this pipeline could not be "
                + "previewed, so parameter types and descriptions are unavailable: \(reason)"
            return set
        }

        set.note = "Could not load parameters: \(reason)"
        return set
    }

    // MARK: Requests

    private func api(_ path: String) -> URL? {
        guard let project = project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "https://dev.azure.com/\(organization)/\(project)/_apis/\(path)?api-version=7.1")
    }

    private func fetch(_ url: URL?, method: String = "GET",
                       body: [String: Any]? = nil) -> (status: Int, data: Data?) {
        guard let url else { return (0, nil) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Basic " + Data(":\(pat)".utf8).base64EncodedString(),
                         forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        var result: (Int, Data?) = (0, nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    private func json(_ response: (status: Int, data: Data?)) -> [String: Any]? {
        guard let data = response.data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - Run dialog

/// An NSClipView lays content out from the bottom up; flipping it keeps a short
/// form pinned to the top of the scroll area.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// The "Run Pipeline…" window: branch plus an editable field per declared
/// parameter, pre-filled with the values the pipeline would otherwise use.
final class RunPipelineWindowController: NSObject, NSWindowDelegate {
    private let ref: RunRef
    private let loader: PipelineParameterLoader
    private let onSubmit: (RunRef, String?, [String: Any]) -> Void
    private let onClose: () -> Void

    private var window: NSWindow!
    private var branchField: NSTextField!
    private var reloadButton: NSButton!
    private var runButton: NSButton!
    private var noteLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var formStack: NSStackView!
    private var controls: [(parameter: PipelineParameter, view: NSView)] = []

    init(ref: RunRef, organization: String, pat: String,
         onSubmit: @escaping (RunRef, String?, [String: Any]) -> Void,
         onClose: @escaping () -> Void) {
        self.ref = ref
        self.loader = PipelineParameterLoader(organization: organization, project: ref.project,
                                              definitionID: ref.definitionID, pat: pat)
        self.onSubmit = onSubmit
        self.onClose = onClose
        super.init()
    }

    func show() {
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        loadParameters()
    }

    // MARK: Layout

    /// Makes an arranged subview span its stack. NSStackView's `.width`
    /// alignment does not do this reliably, so every row is pinned by hand.
    private func stretch(_ view: NSView, to stack: NSStackView, inset: CGFloat = 0) {
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset).isActive = true
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 660),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Run “\(ref.pipelineName)”"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 320)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: "Queues a new run in \(ref.project).")
        subtitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(subtitle)
        stretch(subtitle, to: root)

        branchField = NSTextField(string: "")
        branchField.placeholderString = "Branch (empty = pipeline default)"
        // Pre-fill with the last run's branch — but not PR merge refs
        // (refs/pull/…), which can't be queued directly.
        if let last = ref.lastBranch, !last.hasPrefix("refs/") { branchField.stringValue = last }
        reloadButton = NSButton(title: "Reload", target: self, action: #selector(reload))
        reloadButton.bezelStyle = .rounded
        reloadButton.toolTip = "Re-read the parameters for the branch above"

        let branchRow = NSStackView(views: [NSTextField(labelWithString: "Branch"),
                                            branchField, reloadButton])
        branchRow.orientation = .horizontal
        branchRow.alignment = .firstBaseline
        branchRow.spacing = 8
        branchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(branchRow)
        stretch(branchRow, to: root)

        noteLabel = NSTextField(wrappingLabelWithString: "")
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .systemOrange
        noteLabel.isHidden = true
        root.addArrangedSubview(noteLabel)
        stretch(noteLabel, to: root)

        formStack = NSStackView()
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 18
        formStack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        formStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView = FlippedClipView()
        scroll.documentView = formStack
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(scroll)
        stretch(scroll, to: root)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        runButton = NSButton(title: "Run", target: self, action: #selector(run))
        runButton.bezelStyle = .rounded
        runButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spinner, statusLabel, spacer, cancelButton, runButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        root.addArrangedSubview(footer)
        stretch(footer, to: root)

        let content = NSView()
        content.addSubview(root)
        window.contentView = content
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            // A vertically scrolling stack: pinned on three sides, never on the bottom.
            formStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            formStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            formStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            formStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    // MARK: Parameters

    private func loadParameters() {
        spinner.startAnimation(nil)
        statusLabel.stringValue = "Loading parameters…"
        runButton.isEnabled = false
        reloadButton.isEnabled = false
        let branch = branchField.stringValue.trimmingCharacters(in: .whitespaces)
        loader.load(branch: branch.isEmpty ? nil : branch) { [weak self] set in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            self.runButton.isEnabled = true
            self.reloadButton.isEnabled = true
            let count = set.parameters.count
            self.statusLabel.stringValue = count == 0
                ? "No parameters" : "\(count) parameter\(count == 1 ? "" : "s")"
            self.rebuildForm(with: set)
        }
    }

    private func rebuildForm(with set: PipelineParameterSet) {
        controls.removeAll()
        for view in formStack.arrangedSubviews { view.removeFromSuperview() }

        noteLabel.stringValue = set.note ?? ""
        noteLabel.isHidden = set.note == nil

        guard !set.parameters.isEmpty else {
            let message = NSTextField(wrappingLabelWithString: set.note == nil
                ? "This pipeline declares no runtime parameters."
                : "No parameters could be loaded — the run will use the pipeline's own defaults.")
            message.textColor = .secondaryLabelColor
            formStack.addArrangedSubview(message)
            stretch(message, to: formStack, inset: 28)
            return
        }
        for parameter in set.parameters {
            let view = row(for: parameter,
                           value: set.current[parameter.name] ?? parameter.defaultValue)
            formStack.addArrangedSubview(view)
            stretch(view, to: formStack, inset: 28)
        }
    }

    private func row(for parameter: PipelineParameter, value: Any?) -> NSView {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 5

        let title = NSTextField(wrappingLabelWithString: parameter.label)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        row.addArrangedSubview(title)
        stretch(title, to: row)

        var caption = "\(parameter.name) · \(parameter.type)"
        if parameter.isRequired { caption += " · required" }
        let subtitle = NSTextField(labelWithString: caption)
        subtitle.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        subtitle.textColor = parameter.isRequired ? .systemOrange : .tertiaryLabelColor
        row.addArrangedSubview(subtitle)
        stretch(subtitle, to: row)

        let control: NSView
        if !parameter.values.isEmpty {
            let popup = NSPopUpButton()
            popup.addItems(withTitles: parameter.values)
            let current = MiniYAML.displayText(for: value)
            if parameter.values.contains(current) { popup.selectItem(withTitle: current) }
            row.addArrangedSubview(popup)
        stretch(popup, to: row)
            stretch(popup, to: row)
            control = popup
        } else if parameter.type == "boolean" {
            let check = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
            check.state = MiniYAML.boolValue(value) ? .on : .off
            row.addArrangedSubview(check)
        stretch(check, to: row)
            stretch(check, to: row)
            control = check
        } else if parameter.type == "object" {
            let (scroll, textView) = objectEditor(text: MiniYAML.displayText(for: value))
            row.addArrangedSubview(scroll)
        stretch(scroll, to: row)
            stretch(scroll, to: row)
            control = textView
        } else {
            let field = NSTextField(string: MiniYAML.displayText(for: value))
            field.font = .systemFont(ofSize: 12)
            row.addArrangedSubview(field)
        stretch(field, to: row)
            stretch(field, to: row)
            control = field
        }
        controls.append((parameter, control))
        return row
    }

    private func objectEditor(text: String) -> (NSScrollView, NSTextView) {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 110))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = text
        scroll.documentView = textView
        return (scroll, textView)
    }

    // MARK: Actions

    @objc private func reload() { loadParameters() }

    /// Closes the dialog if it is open (also used when a second one is opened).
    func close() { window?.close() }

    @objc private func cancel() { close() }

    @objc private func run() {
        var parameters: [String: Any] = [:]
        for (parameter, view) in controls {
            // NSPopUpButton is an NSButton subclass, so it has to be checked first.
            if let popup = view as? NSPopUpButton {
                if let title = popup.titleOfSelectedItem { parameters[parameter.name] = title }
            } else if let check = view as? NSButton {
                parameters[parameter.name] = check.state == .on
            } else if let textView = view as? NSTextView {
                let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                guard let data = text.data(using: .utf8),
                      let value = try? JSONSerialization.jsonObject(with: data,
                                                                    options: [.fragmentsAllowed])
                else { return complain("“\(parameter.label)” is not valid JSON.") }
                parameters[parameter.name] = value
            } else if let field = view as? NSTextField {
                // Sent verbatim: some defaults are meaningfully a single space.
                let text = field.stringValue
                if text.isEmpty {
                    if parameter.isRequired {
                        return complain("“\(parameter.name)” is required — it has no default.")
                    }
                    continue
                }
                if parameter.type != "number" {
                    parameters[parameter.name] = text
                } else if let whole = Int(text) {
                    parameters[parameter.name] = whole
                } else if let fractional = Double(text) {
                    parameters[parameter.name] = fractional
                } else {
                    parameters[parameter.name] = text
                }
            }
        }
        let branch = branchField.stringValue.trimmingCharacters(in: .whitespaces)
        onSubmit(ref, branch.isEmpty ? nil : branch, parameters)
        window.close()
    }

    private func complain(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Can't queue this run"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}
