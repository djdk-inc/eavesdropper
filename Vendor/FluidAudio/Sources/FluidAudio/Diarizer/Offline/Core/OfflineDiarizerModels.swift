#if Diarizer
@preconcurrency import CoreML
import Foundation
import OSLog

@available(macOS 14.0, iOS 17.0, *)
public struct OfflineDiarizerModels: Sendable {
    public let segmentationModel: MLModel
    public let fbankModel: MLModel
    public let embeddingModel: MLModel
    public let pldaRhoModel: MLModel
    public let pldaPsi: [Double]

    public let compilationDuration: TimeInterval

    private static let logger = AppLogger(category: "OfflineDiarizerModels")

    private static func loadPLDAPsi(from directory: URL) throws -> [Double] {
        let candidatePaths = [
            directory.appendingPathComponent("plda-parameters.json", isDirectory: false),
            directory.appendingPathComponent("speaker-diarization/plda-parameters.json", isDirectory: false),
            directory.appendingPathComponent("speaker-diarization-coreml/plda-parameters.json", isDirectory: false),
            directory.appendingPathComponent("speaker-diarization-offline/plda-parameters.json", isDirectory: false),
        ]
        guard let parametersURL = candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            throw OfflineDiarizationError.processingFailed("PLDA parameters file not found in \(directory.path)")
        }

        let data = try Data(contentsOf: parametersURL)
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        guard
            let root = jsonObject as? [String: Any],
            let tensors = root["tensors"] as? [String: Any],
            let psiInfo = tensors["psi"] as? [String: Any],
            let base64 = psiInfo["data_base64"] as? String,
            let decoded = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters])
        else {
            throw OfflineDiarizationError.processingFailed("Failed to decode PLDA psi parameters")
        }

        let floatCount = decoded.count / MemoryLayout<Float>.size
        guard floatCount > 0 else {
            throw OfflineDiarizationError.processingFailed("PLDA psi tensor is empty")
        }

        var floats = [Float](repeating: 0, count: floatCount)
        _ = floats.withUnsafeMutableBytes { destination in
            decoded.copyBytes(to: destination)
        }

        return floats.map { Double($0) }
    }

    public init(
        segmentationModel: MLModel,
        fbankModel: MLModel,
        embeddingModel: MLModel,
        pldaRhoModel: MLModel,
        pldaPsi: [Double],
        compilationDuration: TimeInterval
    ) {
        self.segmentationModel = segmentationModel
        self.fbankModel = fbankModel
        self.embeddingModel = embeddingModel
        self.pldaRhoModel = pldaRhoModel
        self.pldaPsi = pldaPsi
        self.compilationDuration = compilationDuration
    }

    /// Eavesdropper: models load only from a local folder (bundled in the app); nothing is downloaded.
    /// Accepts the folder itself or one holding a `speaker-diarization` subfolder.
    private static func loadLocalModels(
        _ names: [String], from directory: URL, computeUnits: MLComputeUnits
    ) throws -> [String: MLModel] {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        var models: [String: MLModel] = [:]
        for name in names {
            let candidates = [directory, directory.appendingPathComponent("speaker-diarization", isDirectory: true)]
                .map { $0.appendingPathComponent(name, isDirectory: true) }
            guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw OfflineDiarizationError.modelNotLoaded(name)
            }
            models[name] = try MLModel(contentsOf: url, configuration: configuration)
        }
        return models
    }

    public static func defaultModelsDirectory() -> URL {
        MLModelConfigurationUtils.defaultModelsDirectory()
    }

    public static func load(
        from directory: URL? = nil,
        configuration: MLModelConfiguration? = nil,
        progressHandler: ProgressHandler? = nil
    ) async throws -> OfflineDiarizerModels {
        let modelsDirectory = directory ?? defaultModelsDirectory()
        let logger = Self.logger
        logger.info("Loading offline diarization models from \(modelsDirectory.path)")

        let loadStart = Date()
        // Honor the caller's requested compute units for the segmentation/embedding/PLDA
        // models; default to `.all` when no configuration is supplied. The fbank model
        // stays `.cpuOnly` regardless (below) since it runs faster on CPU.
        let inferenceComputeUnits: MLComputeUnits = configuration?.computeUnits ?? .all

        let segmentationAndEmbeddingNames: [String] = [
            ModelNames.OfflineDiarizer.segmentationPath,
            ModelNames.OfflineDiarizer.embeddingPath,
            ModelNames.OfflineDiarizer.pldaRhoPath,
        ]

        let segmentationEmbeddingModels = try loadLocalModels(
            segmentationAndEmbeddingNames, from: modelsDirectory, computeUnits: inferenceComputeUnits)

        guard let segmentation = segmentationEmbeddingModels[ModelNames.OfflineDiarizer.segmentationPath] else {
            throw OfflineDiarizationError.modelNotLoaded(ModelNames.OfflineDiarizer.segmentation)
        }
        guard let embedding = segmentationEmbeddingModels[ModelNames.OfflineDiarizer.embeddingPath] else {
            throw OfflineDiarizationError.modelNotLoaded(ModelNames.OfflineDiarizer.embedding)
        }
        guard let plda = segmentationEmbeddingModels[ModelNames.OfflineDiarizer.pldaRhoPath] else {
            throw OfflineDiarizationError.modelNotLoaded(ModelNames.OfflineDiarizer.pldaRho)
        }

        // CPU is fastest for FBank. On macOS 14 this is the crash-prone BNNS
        // path (#878); whether FBank is the faulting prediction is unconfirmed —
        // the #878 harness reports no crash under GPU-enabled routing even though
        // FBank stays pinned here.
        let fbankComputeUnits: MLComputeUnits = .cpuOnly
        let fbankModels = try loadLocalModels(
            [ModelNames.OfflineDiarizer.fbankPath], from: modelsDirectory, computeUnits: fbankComputeUnits)
        guard let fbank = fbankModels[ModelNames.OfflineDiarizer.fbankPath] else {
            throw OfflineDiarizationError.modelNotLoaded(ModelNames.OfflineDiarizer.fbank)
        }

        let pldaPsi = try loadPLDAPsi(from: modelsDirectory)
        let compilationDuration = Date().timeIntervalSince(loadStart)
        let compileString = String(format: "%.3f", compilationDuration)
        logger.info(
            "Offline diarization models ready (compile: \(compileString)s, computeUnits: segmentation/embedding/plda=\(inferenceComputeUnits.label), fbank=\(fbankComputeUnits.label))"
        )

        return OfflineDiarizerModels(
            segmentationModel: segmentation,
            fbankModel: fbank,
            embeddingModel: embedding,
            pldaRhoModel: plda,
            pldaPsi: pldaPsi,
            compilationDuration: compilationDuration
        )
    }
}

extension MLComputeUnits {
    fileprivate var label: String {
        switch self {
        case .cpuOnly:
            return ".cpuOnly"
        case .cpuAndGPU:
            return ".cpuAndGPU"
        case .cpuAndNeuralEngine:
            return ".cpuAndNeuralEngine"
        case .all:
            return ".all"
        @unknown default:
            return ".unknown"
        }
    }
}
#endif
