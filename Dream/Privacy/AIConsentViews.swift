import SwiftUI

extension View {
    /// Asks whether Dream may send what the user asks to xAI, when a page first needs it
    /// (AIConsent.swift). The page waits underneath until they answer.
    func askingAIConsent() -> some View {
        modifier(AIConsentAsking())
    }
}

private struct AIConsentAsking: ViewModifier {
    func body(content: Content) -> some View {
        let consent = AIConsent.shared
        content
            .sheet(isPresented: Binding(get: { consent.isAsking }, set: { if !$0, consent.isAsking { consent.answer(false) } })) {
                AIConsentQuestion()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
    }
}

/// The question itself: who gets what, in plain words, and a clear yes or no.
struct AIConsentQuestion: View {
    private let palette = Palette.now

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Make pages with Grok?")
                    .font(.display(.title2, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text("Grok, an AI from xAI, writes Dream's pages. To make and change yours, Dream's server sends xAI:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    point("What you ask, and the changes you ask for", symbol: "text.bubble")
                    point("Photos you add", symbol: "photo")
                    point("What Dream remembers about you, when it helps", symbol: "person.text.rectangle")
                    point("Entries in your lists, when you talk to them", symbol: "checklist")
                }
                .font(.subheadline)
                Text("Never your name, email or Apple ID. Web searches for a page go to Parallel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Allow") { AIConsent.shared.answer(true) }
                        .buttonStyle(AnswerStyle(palette: palette, isMain: true))
                    Button("Not now") { AIConsent.shared.answer(false) }
                        .buttonStyle(AnswerStyle(palette: palette, isMain: false))
                    Spacer(minLength: 0)
                }
                LegalLinks()
            }
            .padding(24)
            .padding(.top, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(alignment: .top) {
            Aura(palette: palette, energy: 0)
                .frame(height: 320)
                .opacity(0.6)
                .ignoresSafeArea()
        }
    }

    private func point(_ text: String, symbol: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(palette.gradient)
        }
    }
}

/// The same permission in Account, where it can be taken back.
struct AIConsentSection: View {
    @AppStorage(AIConsent.key) private var agreed = 0

    var body: some View {
        Section {
            Toggle("Make pages with Grok", isOn: Binding(get: { agreed >= AIConsent.version }, set: { AIConsent.set($0) }))
        } footer: {
            Text("What you ask, photos you add, your list entries and what Dream remembers when it helps go to xAI through Dream's server to make your pages. Off, Dream asks again next time.")
        }
    }
}
