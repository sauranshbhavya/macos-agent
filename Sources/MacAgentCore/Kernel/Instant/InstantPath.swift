import Foundation

/// The zero-model instant path (V2 plan section 6): commands the Mac recognises from a fixed shape
/// run without the gateway, as local proposals through the same validator, gate and ledger.
public enum InstantPath {
    /// Operations only the instant path uses. The gateway's catalogue doesn't list them, so a model
    /// never proposes them.
    public static func localCapabilities(
        context: @escaping @MainActor @Sendable () -> CapabilityExecutionContext
    ) -> [any Capability] {
        func capability(_ name: String, _ adapter: any CapabilityAdapter, _ operation: AgentOperation) -> AdapterCapability {
            AdapterCapability(
                name: name,
                floor: .observe,
                adapter: adapter,
                previewOnly: false,
                context: context,
                steps: { args in
                    let values = OperationArgs(args)
                    let query = try values.optionalText("query")
                    let count = try values.optionalInt("count")
                    return [AdapterCapabilities.step(operation) { $0.searchQuery = query; $0.count = count }]
                }
            )
        }
        return [
            capability("calculate", CalculatorCapabilityAdapter(), .calculateUtility),
            capability("clipboard_history", ClipboardHistoryCapabilityAdapter(), .lookupClipboardHistory),
            capability("expand_snippet", SnippetExpansionCapabilityAdapter(), .expandSnippet),
            capability("recent_files", RecentArtifactsCapabilityAdapter(), .lookupRecentArtifacts),
        ]
    }

    /// The V2 actions for a plan the instant resolver made, or nil when any step has no V2 form, in
    /// which case the command goes to the gateway as an ordinary request.
    public static func actions(for plan: AgentPlan) -> [WireAction]? {
        var actions: [WireAction] = []
        for step in plan.steps {
            guard let call = operation(for: step) else { return nil }
            actions.append(WireAction(actionID: ActionID(), effect: call.effect, kind: .operation(call.call)))
        }
        return actions.isEmpty ? nil : actions
    }

    static func operation(for step: AgentStep) -> (call: OperationCall, effect: Effect)? {
        func call(_ name: String, _ args: [String: String?], _ effect: Effect) -> (OperationCall, Effect) {
            (OperationCall(name: name, version: 1, args: args.compactMapValues { $0.map(JSONValue.string) }), effect)
        }
        switch step.operation {
        case .openApp:
            guard let app = step.resolvedBundleIdentifier ?? step.appName else { return nil }
            return call("open_app", ["app": app], .navigate)
        case .switchRunningApp:
            guard let app = step.appName else { return nil }
            return call("switch_app", ["app": app], .navigate)
        case .openURL:
            guard let url = step.targetURL else { return nil }
            return call("open_url", ["url": url, "browser": step.browserName], .navigate)
        case .invokeShortcut:
            guard let name = step.shortcutName else { return nil }
            return call("run_shortcut", ["name": name, "input": step.shortcutInput], .unknown)
        case .calculateUtility:
            return call("calculate", ["query": step.searchQuery], .observe)
        case .lookupClipboardHistory:
            var result = call("clipboard_history", ["query": step.searchQuery], .observe)
            if let count = step.count { result.0.args["count"] = .number(Double(count)) }
            return result
        case .expandSnippet:
            return call("expand_snippet", ["query": step.searchQuery], .observe)
        case .lookupRecentArtifacts:
            var result = call("recent_files", ["query": step.searchQuery], .observe)
            if let count = step.count { result.0.args["count"] = .number(Double(count)) }
            return result
        default:
            return nil
        }
    }
}
