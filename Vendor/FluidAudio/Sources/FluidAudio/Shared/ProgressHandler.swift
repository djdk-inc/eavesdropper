// Eavesdropper: stands in for upstream's download-progress callback type (the download code is removed).
public typealias ProgressHandler = @Sendable (Double) -> Void
