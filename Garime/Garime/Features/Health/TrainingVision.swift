import Foundation

/// O que o agente leu na foto da máquina. É palpite: nada vai para o log
/// sem o usuário confirmar.
struct TrainingVisionReading: Equatable {
    var machine: String
    var weightKg: Double?
    var confidence: Double
    var note: String

    var isUsable: Bool { weightKg != nil || !machine.isEmpty }
}

enum TrainingVisionPrompt {
    /// Marca a resposta desta pergunta, para não confundir com mensagem antiga
    /// que já estava no transcript.
    static func nonce(_ uuid: UUID = UUID()) -> String {
        "GV" + uuid.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
    }

    static func text(imagePath: String, exercise: String, nonce: String) -> String {
        """
        olhe a imagem em \(imagePath). É o aparelho/carga de um exercício de \
        academia (\(exercise)). Identifique a máquina e o peso selecionado \
        (kg). Responda em UMA linha, só JSON, sem markdown, começando por \
        \(nonce): \(nonce) {"machine":"nome curto","weightKg":40,\
        "confidence":0.0-1.0,"note":"o que te fez concluir"}. \
        Se não der para ler o peso, use weightKg:null e explique em note.
        """
    }
}

enum TrainingVisionReply {
    /// Procura a resposta do agente marcada com o nonce, da mais nova para a
    /// mais antiga, e extrai o JSON dela.
    static func parse(messages: [AgentChatMessage], nonce: String) -> TrainingVisionReading? {
        for message in messages.reversed() {
            guard message.role == .assistant, message.text.contains(nonce) else { continue }
            if let reading = parse(text: message.text, nonce: nonce) { return reading }
        }
        return nil
    }

    static func parse(text: String, nonce: String) -> TrainingVisionReading? {
        guard let marker = text.range(of: nonce) else { return nil }
        let tail = String(text[marker.upperBound...])
        guard let json = firstJSONObject(in: tail),
              let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let machine = (raw["machine"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (raw["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let confidence = number(raw["confidence"]) ?? 0
        var weight = number(raw["weightKg"])
        if let value = weight, value <= 0 || value > 1000 { weight = nil }

        let reading = TrainingVisionReading(
            machine: machine,
            weightKg: weight,
            confidence: min(max(confidence, 0), 1),
            note: note
        )
        return reading.isUsable ? reading : nil
    }

    /// Recorta o primeiro objeto JSON balanceado, ignorando cercas de markdown.
    static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String {
            let normalized = string.replacingOccurrences(of: ",", with: ".")
            return Double(normalized.filter { $0.isNumber || $0 == "." || $0 == "-" })
        }
        return nil
    }
}

enum VisionBannerText {
    static func summary(_ reading: TrainingVisionReading) -> String {
        var parts: [String] = []
        if !reading.machine.isEmpty { parts.append(reading.machine.lowercased()) }
        if let weight = reading.weightKg {
            parts.append(VitalsFormat.kg(weight))
        } else {
            parts.append("peso ilegível")
        }
        parts.append("confiança \(Int((reading.confidence * 100).rounded()))%")
        return parts.joined(separator: " · ")
    }
}
