import SwiftUI

/// The questions, where the page is forming. Answers Dream remembered show as tags already;
/// each one the user picks folds up beside them, and once every question has one, building starts.
struct AskingView: View {
    let asking: Asking
    let palette: Palette
    /// Answers picked so far, by open question, before they all go to the model together.
    @State private var picks: [Int: String] = [:]
    @Namespace private var fold

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !tags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(tags) { tag in
                        AnswerTag(answer: tag.answer, palette: palette)
                            .matchedGeometryEffect(id: tag.question.map { "\($0)-\(tag.answer.choice)" } ?? "tag-\(tag.id)", in: fold)
                            .onTapGesture { if let question = tag.question { reopen(question) } }
                    }
                }
            }
            if let questions = asking.questions {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    if picks[index] == nil {
                        QuestionCard(question: question, palette: palette, fold: fold, id: index) { pick(index, $0) }
                            .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: picks)
        .onChange(of: asking.questions) { picks = [:] }
    }

    private struct Tag: Identifiable {
        /// Its place among all the answers, which it keeps once they're sent.
        let id: Int
        let answer: Answer
        /// The open question it was picked for, while it can still be reopened.
        var question: Int?
    }

    /// The answers so far (remembered ones), then while waiting, the user's picks.
    private var tags: [Tag] {
        let known = asking.answers.enumerated().map { Tag(id: $0.offset, answer: $0.element) }
        guard let questions = asking.questions else { return known }
        return known + picks.keys.sorted().map { index in
            Tag(id: known.count + index, answer: Answer(question: questions[index], choice: picks[index] ?? ""), question: index)
        }
    }

    private func pick(_ index: Int, _ choice: String) {
        withAnimation(.smooth(duration: 0.45)) { picks[index] = choice }
        guard let questions = asking.questions, picks.count == questions.count else { return }
        let answers = questions.indices.map { Answer(question: questions[$0], choice: picks[$0] ?? "") }
        Task {
            // A beat to see the last answer land before the page starts forming.
            try? await Task.sleep(for: .milliseconds(350))
            asking.answer(answers)
        }
    }

    /// A tag tapped before everything's answered opens its question again.
    private func reopen(_ index: Int) {
        guard asking.isWaiting, let questions = asking.questions, picks.count < questions.count else { return }
        withAnimation(.smooth(duration: 0.45)) { picks[index] = nil }
    }
}

/// One question: its answers to tap, "You choose", and a field when it takes a typed answer.
private struct QuestionCard: View {
    let question: Question
    let palette: Palette
    let fold: Namespace.ID
    let id: Int
    let onPick: (String) -> Void
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(question.text)
                .font(.display(.title3))
                .accessibilityAddTraits(.isHeader)
            FlowLayout(spacing: 8) {
                ForEach(question.options, id: \.self) { option in
                    Button(option) { onPick(option) }
                        .buttonStyle(ChoiceStyle(palette: palette))
                        .matchedGeometryEffect(id: "\(id)-\(option)", in: fold)
                }
                Button { onPick("") } label: {
                    Label("You choose", systemImage: "sparkles")
                }
                .buttonStyle(ChoiceStyle(palette: palette, isQuiet: true))
                .matchedGeometryEffect(id: "\(id)-", in: fold)
            }
            if question.allowsTyping {
                HStack(spacing: 8) {
                    TextField(question.options.isEmpty ? question.topic : "Or type one", text: $typed)
                        .submitLabel(.done)
                        .onSubmit(submitTyped)
                    if !trimmed.isEmpty {
                        Button("Use this", systemImage: "arrow.up", action: submitTyped)
                            .labelStyle(.iconOnly)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(palette.onAccent)
                            .frame(width: 30, height: 30)
                            .background(palette.accent, in: .circle)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 5)
                .frame(minHeight: 40)
                .background(Color(.systemBackground).opacity(0.7), in: .capsule)
                .overlay(Capsule().strokeBorder(palette.edge, lineWidth: 0.5))
                .animation(.smooth, value: trimmed.isEmpty)
            }
            if question.isPersonal {
                Label("Dream will remember this", systemImage: "person.crop.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .panel(palette)
    }

    private var trimmed: String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func submitTyped() {
        guard !trimmed.isEmpty else { return }
        onPick(trimmed)
    }
}

/// An answer to tap: tinted like the surface. "You choose" stays quieter, outlined only.
private struct ChoiceStyle: ButtonStyle {
    let palette: Palette
    var isQuiet = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isQuiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(isQuiet ? Color.clear : palette.accent.opacity(configuration.isPressed ? 0.24 : 0.12), in: .capsule)
            .overlay(Capsule().strokeBorder(palette.edge, lineWidth: isQuiet ? 1 : 0.5))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// One answer, small: what the user picked, or the question's topic when they left it to Dream.
struct AnswerTag: View {
    let answer: Answer
    let palette: Palette
    var isChangeable = false

    var body: some View {
        HStack(spacing: 5) {
            if answer.isLeftToDream {
                Image(systemName: "sparkles")
                    .foregroundStyle(palette.accent)
                Text(answer.question.topic)
            } else {
                if answer.isRemembered {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(palette.accent)
                }
                Text(answer.choice)
            }
            if isChangeable {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.footnote.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(palette.wash, in: .capsule)
        .overlay(Capsule().strokeBorder(palette.edge, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(answer.question.topic): \(answer.isLeftToDream ? "Dream chose" : answer.choice)\(answer.isRemembered ? ", remembered" : "")")
    }
}

/// The answers a surface was built from, in its header. Tapping one offers the other answers,
/// and picking one rebuilds the surface for it.
struct AnswerTags: View {
    let answers: [Answer]
    let palette: Palette
    /// Nil while the surface is being built or changed.
    var onChange: ((Answer, String) -> Void)?
    @State private var typing: Answer?
    @State private var typed = ""

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(answers, id: \.self) { answer in
                Menu {
                    Section(answer.question.text) {
                        ForEach(choices(for: answer), id: \.self) { option in
                            Button { change(answer, to: option) } label: {
                                if option == answer.choice { Label(option, systemImage: "checkmark") } else { Text(option) }
                            }
                        }
                        Button { change(answer, to: "") } label: {
                            Label("You choose", systemImage: answer.isLeftToDream ? "checkmark" : "sparkles")
                        }
                        if answer.question.allowsTyping {
                            Button("Something else…", systemImage: "character.cursor.ibeam") {
                                typed = ""
                                typing = answer
                            }
                        }
                    }
                } label: {
                    AnswerTag(answer: answer, palette: palette, isChangeable: onChange != nil)
                }
                .buttonStyle(.plain)
                .disabled(onChange == nil)
                .accessibilityHint("Changes the answer and rebuilds the page")
            }
        }
        .alert(typing?.question.text ?? "", isPresented: Binding(get: { typing != nil }, set: { if !$0 { typing = nil } })) {
            TextField(typing?.question.topic ?? "", text: $typed)
            Button("Rebuild") {
                let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                if let answer = typing, !text.isEmpty { change(answer, to: text) }
                typing = nil
            }
            Button("Cancel", role: .cancel) { typing = nil }
        }
    }

    /// The question's options, plus a typed answer that wasn't one of them.
    private func choices(for answer: Answer) -> [String] {
        let options = answer.question.options
        return answer.isLeftToDream || options.contains(answer.choice) ? options : options + [answer.choice]
    }

    private func change(_ answer: Answer, to choice: String) {
        guard choice != answer.choice else { return }
        onChange?(answer, choice)
    }
}
