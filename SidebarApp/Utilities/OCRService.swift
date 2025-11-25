//
//  OCRService.swift
//  SidebarApp
//
//  Created by Biel on 21/11/25.
//
import Vision
import AppKit

class OCRService {
    static let shared = OCRService()
    
    // O Request fica vivo na memória para não perdermos tempo recriando
    private var request: VNRecognizeTextRequest?
    
    private init() {
        setupEngine()
    }
    
    private func setupEngine() {
        request = VNRecognizeTextRequest { _, _ in }
        
        // CONFIGURAÇÃO DE ALTA PRECISÃO OTIMIZADA
        request?.recognitionLevel = .accurate
        request?.usesLanguageCorrection = true // Ajuda a corrigir erros, vale o custo de processamento
        request?.revision = VNRecognizeTextRequestRevision3 // Usa a versão mais recente (mais rápida e precisa no macOS Sonoma/Sequoia)
        request?.preferBackgroundProcessing = false // CRÍTICO: Força o uso imediato da CPU/GPU, não espera o sistema ficar ocioso
    }
    
    func process(_ image: NSImage, completion: @escaping (String) -> Void) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let request = request else { return }
        
        // Executa na fila de prioridade MÁXIMA (User Interactive)
        DispatchQueue.global(qos: .userInteractive).async {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            
            do {
                try handler.perform([request])
                
                guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
                
                // Concatenação eficiente
                let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                
                DispatchQueue.main.async {
                    completion(text)
                }
            } catch {
                print("Erro no OCR: \(error)")
            }
        }
    }
}
