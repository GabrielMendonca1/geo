import SwiftUI

private struct SetInput: Identifiable {
    let id = UUID()
    var reps: String = ""
    var kg: Double = 0
}

struct ExerciseLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let exercise: VitalsExercise
    let logged: VitalsLogExercise?
    let lastWeight: Double?
    let onSave: ([VitalsLogSet]) async throws -> Void

    @State private var rows: [SetInput] = []
    @State private var isSaving = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(VitalsFormat.sets(exercise.sets))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.slateTextDim)

                    VStack(spacing: 10) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, _ in
                            setRow(index: index, target: exercise.sets[safe: index] ?? [])
                        }
                    }
                    .padding(16)
                    .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))

                    if let failure {
                        Text(failure)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.slateTextDim)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(exercise.name.lowercased())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancelar") { dismiss() }
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("salvar") { save() }
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .disabled(isSaving)
                }
            }
        }
        .glassSheet(detents: [.medium, .large])
        .tint(Color.slateText)
        .onAppear(perform: prepare)
    }

    private func setRow(index: Int, target: [Int]) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.slateTextFaint)
                .frame(width: 14, alignment: .leading)

            TextField(
                "",
                text: repsBinding(index: index),
                prompt: Text(target.isEmpty ? "reps" : "\(target.last ?? 0)").foregroundStyle(.tertiary)
            )
            .keyboardType(.numberPad)
            .font(.system(size: 14, design: .monospaced))
            .frame(width: 56)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .overlay(
                RoundedRectangle(cornerRadius: AirRadius.button, style: .continuous)
                    .stroke(Color.slateStroke, lineWidth: 0.5)
            )

            Spacer(minLength: 4)

            Button {
                step(index: index, delta: -2.5)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.slateTextDim)

            Text(VitalsFormat.kg(rows[safe: index]?.kg ?? 0))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.slateText)
                .frame(width: 80)

            Button {
                step(index: index, delta: 2.5)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.slateTextDim)
        }
    }

    private func step(index: Int, delta: Double) {
        guard rows.indices.contains(index) else { return }
        rows[index].kg = max(0, rows[index].kg + delta)
    }

    private func repsBinding(index: Int) -> Binding<String> {
        Binding(
            get: { rows[safe: index]?.reps ?? "" },
            set: { value in
                guard rows.indices.contains(index) else { return }
                rows[index].reps = value.filter(\.isNumber)
            }
        )
    }

    private func prepare() {
        guard rows.isEmpty else { return }
        let fallback = lastWeight ?? 0
        let count = max(exercise.sets.count, logged?.sets.count ?? 0)
        rows = (0..<max(count, 1)).map { index in
            guard let set = logged?.sets[safe: index] else {
                return SetInput(reps: "", kg: fallback)
            }
            return SetInput(reps: "\(set.reps)", kg: set.kg)
        }
    }

    private func save() {
        let sets = rows.compactMap { row -> VitalsLogSet? in
            guard let reps = Int(row.reps), reps > 0 else { return nil }
            return VitalsLogSet(reps: reps, kg: row.kg)
        }

        isSaving = true
        Task {
            do {
                try await onSave(sets)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            isSaving = false
        }
    }
}
