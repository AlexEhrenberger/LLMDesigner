import Testing
import LLMDProtocol
@testable import LLMDesigner

/// The rule table of the safety concept (4.2), over every combination of channel, A, B and effect. The expectation is
/// written out independently of the implementation, line by line.
@Suite("Sicherheit: Rule of Two")
struct ActionPolicyTests {
    private enum Expect { case allow, ask, deny }

    private func expected(_ channel: ActionChannel, a: Bool, b: Bool, effect: ActionEffect, actionUntrusted: Bool, actionSensitive: Bool, kind: ActionKind) -> Expect {
        if channel == .ui { return .allow }
        if channel == .mcp, actionSensitive { return .deny }
        let hasA = a || channel == .mcp || actionUntrusted
        let hasB = b || actionSensitive
        let hasC = effect == .outbound || effect == .destructive
        if hasA && hasB && hasC { return .ask }
        if effect == .outbound && (hasA || hasB) { return .ask }
        if effect == .destructive && hasA { return .ask }
        if actionSensitive && hasA { return .ask }
        // The default levels.
        switch (channel, kind) {
        case (.chat, .write), (_, .destructive): return .ask
        default: return .allow
        }
    }

    @Test func everyCombination() {
        var checked = 0
        for channel in ActionChannel.allCases {
            for a in [false, true] {
                for b in [false, true] {
                    for effect in ActionEffect.allCases {
                        for actionUntrusted in [false, true] {
                            for actionSensitive in [false, true] {
                                // Only combinations a registered action can have.
                                let kind: ActionKind = switch effect {
                                case .none: actionSensitive ? .destructive : .read
                                case .local: actionSensitive ? .destructive : .write
                                case .destructive, .outbound: .destructive
                                }
                                let security = ActionSecurity(readsUntrusted: actionUntrusted, sensitive: actionSensitive, effect: effect)
                                let input = ActionPolicy.Input(channel: channel, runHasUntrusted: a, runHasSensitive: b, security: security, kind: kind)
                                let decision = ActionPolicy.decide(input, level: ActionPolicy.defaultLevel(channel: channel, kind: kind))
                                let wanted = expected(channel, a: a, b: b, effect: effect, actionUntrusted: actionUntrusted, actionSensitive: actionSensitive, kind: kind)
                                let matches = switch (decision, wanted) {
                                case (.allow, .allow), (.ask, .ask), (.deny, .deny): true
                                default: false
                                }
                                #expect(matches, "\(channel) A=\(a) B=\(b) \(effect) aU=\(actionUntrusted) aS=\(actionSensitive): \(decision)")
                                checked += 1
                            }
                        }
                    }
                }
            }
        }
        #expect(checked == 4 * 2 * 2 * 4 * 2 * 2)
    }

    @Test func theTriangleNeverPassesOutsideTheUI() {
        for channel in ActionChannel.allCases where channel != .ui {
            for level in ActionPolicy.Level.allCases {
                let input = ActionPolicy.Input(channel: channel, runHasUntrusted: true, runHasSensitive: true,
                                               security: ActionSecurity(readsUntrusted: false, sensitive: false, effect: .outbound), kind: .destructive)
                #expect(ActionPolicy.decide(input, level: level) != .allow)
            }
        }
    }

    @Test func allowLevelStillDoesNotOpenTheTriangle() {
        let input = ActionPolicy.Input(channel: .cli, runHasUntrusted: true, runHasSensitive: false,
                                       security: ActionSecurity(readsUntrusted: false, sensitive: false, effect: .destructive), kind: .destructive)
        #expect(ActionPolicy.decide(input, level: .allow) != .allow)
    }

    @Test func levelsWorkWhereNoRuleSpeaks() {
        let input = ActionPolicy.Input(channel: .cli, runHasUntrusted: false, runHasSensitive: false,
                                       security: ActionSecurity(readsUntrusted: false, sensitive: false, effect: .destructive), kind: .destructive)
        #expect(ActionPolicy.decide(input, level: .allow) == .allow)
        if case .ask = ActionPolicy.decide(input, level: .ask) {} else { Issue.record("sollte fragen") }
        if case .deny = ActionPolicy.decide(input, level: .deny) {} else { Issue.record("sollte verweigern") }
    }

    @MainActor @Test func mcpRunStartsWithForeign() {
        #expect(RunState(channel: .mcp).hasReadUntrusted)
        #expect(!RunState(channel: .cli).hasReadUntrusted)
    }
}
