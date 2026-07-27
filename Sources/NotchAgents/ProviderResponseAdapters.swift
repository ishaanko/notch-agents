import Foundation

protocol ProviderResponseAdapter {
    var agent: AgentKind { get }
    func encodePermission(
        _ decision: PermissionDecision,
        instruction: String?,
        request: AgentInteraction
    ) -> [String: Any]
    func encodeAnswers(_ answers: [String: QuestionAnswer], request: AgentInteraction) -> [String: Any]
}

extension ProviderResponseAdapter {
    func encodePermission(_ decision: PermissionDecision, request: AgentInteraction) -> [String: Any] {
        encodePermission(decision, instruction: nil, request: request)
    }
}

struct ProviderResponseAdapterRegistry {
    static let shared = ProviderResponseAdapterRegistry()

    private let adapters: [AgentKind: any ProviderResponseAdapter]
    private let fallback: any ProviderResponseAdapter

    init() {
        var values: [AgentKind: any ProviderResponseAdapter] = [:]
        for agent in AgentKind.allCases where agent != .unknown {
            if [.claude, .codex, .droid, .qoder, .qwen, .codebuddy].contains(agent) {
                values[agent] = ClaudeResponseAdapter(agent: agent)
            } else if agent == .cursor {
                values[agent] = CursorResponseAdapter()
            } else {
                values[agent] = CommonResponseAdapter(agent: agent)
            }
        }
        adapters = values
        fallback = CommonResponseAdapter(agent: .unknown)
    }

    func adapter(for agent: AgentKind) -> any ProviderResponseAdapter {
        adapters[agent] ?? fallback
    }
}

private struct ClaudeResponseAdapter: ProviderResponseAdapter {
    let agent: AgentKind

    func encodePermission(
        _ decision: PermissionDecision,
        instruction: String?,
        request: AgentInteraction
    ) -> [String: Any] {
        var encodedDecision: [String: Any] = ["behavior": decision.rawValue]
        if decision == .deny,
           let instruction = instruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instruction.isEmpty {
            encodedDecision["message"] = instruction
        }
        var hookOutput: [String: Any] = [
            "continue": true,
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": encodedDecision,
            ],
        ]
        if agent != .codex {
            hookOutput["suppressOutput"] = true
        }
        return [
            "ok": true,
            "request_id": request.requestID,
            "decision": decision.rawValue,
            "output": hookOutput,
        ]
    }

    func encodeAnswers(_ answers: [String: QuestionAnswer], request: AgentInteraction) -> [String: Any] {
        let encoded = encodeAnswerMap(answers)
        let promptAnswers = request.questions.reduce(into: [String: Any]()) { result, question in
            guard let answer = answers[question.id] else { return }
            let selected = answer.selectedValues.joined(separator: ", ")
            let value = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            result[question.prompt] = (value?.isEmpty == false ? value : selected) ?? selected
        }
        var updatedInput = request.responseContext
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? [:]
        updatedInput["answers"] = promptAnswers
        var hookOutput: [String: Any] = [
            "continue": true,
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "allow",
                    "updatedInput": updatedInput,
                ],
            ],
        ]
        if agent != .codex {
            hookOutput["suppressOutput"] = true
        }
        return [
            "ok": true,
            "request_id": request.requestID,
            "answers": encoded,
            "output": hookOutput,
        ]
    }
}

private struct CursorResponseAdapter: ProviderResponseAdapter {
    let agent = AgentKind.cursor

    func encodePermission(
        _ decision: PermissionDecision,
        instruction: String?,
        request: AgentInteraction
    ) -> [String: Any] {
        var output: [String: Any] = [
            "continue": true,
            "permission": decision.rawValue,
        ]
        if decision == .deny,
           let instruction = instruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instruction.isEmpty {
            output["agentMessage"] = instruction
        }
        return [
            "ok": true,
            "request_id": request.requestID,
            "decision": decision.rawValue,
            "output": output,
        ]
    }

    func encodeAnswers(_ answers: [String: QuestionAnswer], request: AgentInteraction) -> [String: Any] {
        CommonResponseAdapter(agent: agent).encodeAnswers(answers, request: request)
    }
}

private struct CommonResponseAdapter: ProviderResponseAdapter {
    let agent: AgentKind

    func encodePermission(
        _ decision: PermissionDecision,
        instruction: String?,
        request: AgentInteraction
    ) -> [String: Any] {
        var output: [String: Any] = ["decision": decision.rawValue]
        if let instruction = instruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instruction.isEmpty {
            output["instruction"] = instruction
        }
        return [
            "ok": true,
            "request_id": request.requestID,
            "provider": agent.rawValue,
            "decision": decision.rawValue,
            "output": output,
        ]
    }

    func encodeAnswers(_ answers: [String: QuestionAnswer], request: AgentInteraction) -> [String: Any] {
        let encoded = encodeAnswerMap(answers)
        return [
            "ok": true,
            "request_id": request.requestID,
            "provider": agent.rawValue,
            "answers": encoded,
            "output": ["answers": encoded],
        ]
    }
}

private func encodeAnswerMap(_ answers: [String: QuestionAnswer]) -> [String: Any] {
    answers.reduce(into: [String: Any]()) { result, item in
        var value: [String: Any] = ["selected": item.value.selectedValues]
        if let text = item.value.text, !text.isEmpty { value["text"] = text }
        result[item.key] = value
    }
}
